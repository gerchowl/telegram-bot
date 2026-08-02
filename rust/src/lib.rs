// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Lars Gerchow
//! Shared core for the `tg-send` and `tg-bot` binaries: config loading, bot
//! token resolution, and a minimal Telegram Bot API client. Kept dependency
//! -light on purpose — small binaries with a minimal runtime closure.

use anyhow::{bail, Context, Result};
use std::collections::HashMap;
use std::env;
use std::fs;
use std::time::Duration;

/// Base URL for the Bot API (override with `TELEGRAM_API_BASE`, e.g. tests).
pub fn api_base() -> String {
    env::var("TELEGRAM_API_BASE").unwrap_or_else(|_| "https://api.telegram.org".to_string())
}

/// Mask any `bot<id>:<token>` substring so the bot token never reaches a log or stderr.
/// Telegram puts the token in the request *path*, so a ureq/network error Displays the full URL
/// — scrub it before printing. Keeps the numeric bot id; replaces the secret with `<redacted>`.
pub fn redact(s: &str) -> String {
    let b = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i..].starts_with(b"bot") {
            let mut j = i + 3;
            while j < b.len() && b[j].is_ascii_digit() {
                j += 1;
            }
            if j > i + 3 && j < b.len() && b[j] == b':' {
                let mut k = j + 1;
                while k < b.len() && (b[k].is_ascii_alphanumeric() || b[k] == b'_' || b[k] == b'-')
                {
                    k += 1;
                }
                if k > j + 1 {
                    out.extend_from_slice(&b[i..j]); // "bot" + numeric id
                    out.extend_from_slice(b":<redacted>");
                    i = k;
                    continue;
                }
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::redact;

    #[test]
    fn redacts_token_in_url() {
        let s = "network error: https://api.telegram.org/bot123456:AbC-dEf_123/getUpdates: refused";
        let r = redact(s);
        assert!(!r.contains("AbC-dEf_123"), "token leaked: {r}");
        assert!(r.contains("bot123456:<redacted>"), "wrong shape: {r}");
        assert!(r.contains("/getUpdates: refused"), "over-redacted: {r}");
    }

    #[test]
    fn leaves_plain_text_and_utf8_intact() {
        assert_eq!(redact("robot online ✅"), "robot online ✅");
    }
}

/// Non-secret config (chat id, sops file path, …) as written by tg-onboard.
/// Reads `config.env`, including its `export K="${K:-default}"` convention where an
/// explicit environment variable always wins over the file's default.
pub struct Config {
    defaults: HashMap<String, String>,
}

impl Config {
    /// Load from the explicit path, else `$TELEGRAM_BOT_CONFIG`, else
    /// `${XDG_CONFIG_HOME:-~/.config}/telegram-bot/config.env`. Missing file is fine.
    pub fn load(explicit: Option<&str>) -> Self {
        let path = explicit
            .map(str::to_string)
            .or_else(|| env::var("TELEGRAM_BOT_CONFIG").ok());
        let path = path.or_else(|| {
            let base = env::var("XDG_CONFIG_HOME")
                .ok()
                .or_else(|| env::var("HOME").ok().map(|h| format!("{h}/.config")));
            base.map(|b| format!("{b}/telegram-bot/config.env"))
        });
        let mut defaults = HashMap::new();
        if let Some(p) = path {
            if let Ok(text) = fs::read_to_string(&p) {
                for line in text.lines() {
                    if let Some((k, v)) = parse_config_line(line) {
                        defaults.insert(k, v);
                    }
                }
            }
        }
        Config { defaults }
    }

    /// Resolve a key: a non-empty environment variable wins; otherwise the
    /// config-file default; otherwise `None`.
    pub fn get(&self, key: &str) -> Option<String> {
        if let Ok(v) = env::var(key) {
            if !v.is_empty() {
                return Some(v);
            }
        }
        self.defaults.get(key).cloned().filter(|s| !s.is_empty())
    }
}

/// Parse one `config.env` line into (key, default-value). Handles
/// `export K="${K:-DEFAULT}"`, `export K="VALUE"`, and `K=VALUE`.
fn parse_config_line(line: &str) -> Option<(String, String)> {
    let line = line.trim();
    if line.is_empty() || line.starts_with('#') {
        return None;
    }
    let line = line.strip_prefix("export ").unwrap_or(line);
    let (key, val) = line.split_once('=')?;
    let key = key.trim().to_string();
    let val = val.trim().trim_matches('"').trim_matches('\'');
    let resolved = match val.strip_prefix("${").and_then(|s| s.strip_suffix('}')) {
        // ${KEY:-DEFAULT} -> DEFAULT ; ${KEY} -> "" (env supplies it)
        Some(inner) => inner
            .split_once(":-")
            .map(|(_, d)| d.to_string())
            .unwrap_or_default(),
        None => val.to_string(),
    };
    Some((key, resolved))
}

/// Resolve the bot token: `$TELEGRAM_BOT_TOKEN` > token file > sops file
/// (decrypted by shelling out to `sops`).
pub fn resolve_token(cfg: &Config) -> Result<String> {
    if let Some(t) = cfg.get("TELEGRAM_BOT_TOKEN") {
        return Ok(t);
    }
    if let Some(f) = cfg.get("TELEGRAM_BOT_TOKEN_FILE") {
        if let Ok(s) = fs::read_to_string(&f) {
            return Ok(s.trim().to_string());
        }
    }
    if let Some(sf) = cfg.get("TELEGRAM_BOT_SOPS_FILE") {
        let key = cfg
            .get("TELEGRAM_BOT_SOPS_KEY")
            .unwrap_or_else(|| "telegram_bot_token".into());
        let out = std::process::Command::new("sops")
            .args(["-d", "--extract", &format!("[\"{key}\"]"), &sf])
            .output()
            .context("running sops to decrypt the token")?;
        // Both failure modes below are diagnosed rather than falling through to
        // the generic "no token" message: a silent empty token 404s on every
        // later API call, which is expensive to trace back to a bad sops key.
        if !out.status.success() {
            bail!(
                "sops failed to decrypt '{sf}' (key '{key}'). Is your age identity reachable? \
                 Set SOPS_AGE_KEY_FILE (e.g. ~/.config/sops/age/keys.txt)."
            );
        }
        let tok = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if tok.is_empty() {
            bail!("decrypted token is empty (key '{key}' in '{sf}').");
        }
        return Ok(tok);
    }
    bail!("no bot token found. Set TELEGRAM_BOT_TOKEN, TELEGRAM_BOT_TOKEN_FILE or TELEGRAM_BOT_SOPS_FILE (run 'tg-onboard' to set up).");
}

/// Minimal Telegram Bot API client.
pub struct Tg {
    token: String,
    base: String,
    agent: ureq::Agent,
}

impl Tg {
    pub fn new(token: String) -> Self {
        // read timeout > the 50s long-poll; connect timeout kept short.
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(15))
            .timeout_read(Duration::from_secs(70))
            .build();
        Tg {
            token,
            base: api_base(),
            agent,
        }
    }

    // NOTE: Telegram authenticates by putting the token in the URL path (no
    // header auth), so it can appear in proxy/strace traces — unavoidable.
    fn url(&self, method: &str) -> String {
        format!("{}/bot{}/{}", self.base, self.token, method)
    }

    fn check(json: serde_json::Value) -> Result<serde_json::Value> {
        if json.get("ok").and_then(serde_json::Value::as_bool) == Some(true) {
            Ok(json)
        } else {
            let desc = json
                .get("description")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown error");
            bail!("API error: {desc}");
        }
    }

    fn post_form(&self, method: &str, fields: &[(&str, &str)]) -> Result<serde_json::Value> {
        let url = self.url(method);
        let json = match self.agent.post(&url).send_form(fields) {
            Ok(r) => r
                .into_json::<serde_json::Value>()
                .context("parsing response")?,
            // Telegram returns 4xx + a JSON body on API errors; read it too.
            Err(ureq::Error::Status(_, r)) => r
                .into_json::<serde_json::Value>()
                .context("parsing error response")?,
            Err(e) => return Err(e).context("network error talking to Telegram"),
        };
        Self::check(json)
    }

    pub fn get_me(&self) -> Result<serde_json::Value> {
        self.post_form("getMe", &[])
    }

    pub fn delete_webhook(&self) {
        let _ = self.post_form("deleteWebhook", &[]);
    }

    pub fn get_updates(&self, offset: i64, timeout_secs: u32) -> Result<serde_json::Value> {
        let off = offset.to_string();
        let to = timeout_secs.to_string();
        self.post_form(
            "getUpdates",
            &[
                ("offset", off.as_str()),
                ("timeout", to.as_str()),
                // include poll_answer so the _poll_answer hook can record non-anonymous votes
                ("allowed_updates", r#"["message","poll_answer"]"#),
            ],
        )
    }

    pub fn send_message(
        &self,
        chat: &str,
        text: &str,
        parse_mode: Option<&str>,
        silent: bool,
    ) -> Result<()> {
        let mut f: Vec<(&str, &str)> = vec![("chat_id", chat), ("text", text)];
        if let Some(pm) = parse_mode {
            f.push(("parse_mode", pm));
        }
        if silent {
            f.push(("disable_notification", "true"));
        }
        self.post_form("sendMessage", &f)?;
        Ok(())
    }

    /// Like `send_message` but returns the sent message's `message_id`, and
    /// optionally attaches an inline keyboard (`reply_markup` = a JSON string,
    /// e.g. `{"inline_keyboard":[[{"text":"A","callback_data":"…"}]]}`). The
    /// `message_id` is the correlation key for reply-routing: a cited reply
    /// carries it back in `reply_to_message.message_id`.
    pub fn send_message_id(
        &self,
        chat: &str,
        text: &str,
        parse_mode: Option<&str>,
        silent: bool,
        reply_markup: Option<&str>,
    ) -> Result<i64> {
        let mut f: Vec<(&str, &str)> = vec![("chat_id", chat), ("text", text)];
        if let Some(pm) = parse_mode {
            f.push(("parse_mode", pm));
        }
        if silent {
            f.push(("disable_notification", "true"));
        }
        if let Some(rm) = reply_markup {
            f.push(("reply_markup", rm));
        }
        let resp = self.post_form("sendMessage", &f)?;
        resp.pointer("/result/message_id")
            .and_then(serde_json::Value::as_i64)
            .context("sendMessage response missing result.message_id")
    }

    /// Acknowledge an inline-keyboard button tap so Telegram clears the
    /// client-side spinner (otherwise the button shows a loading state).
    pub fn answer_callback_query(&self, id: &str, text: Option<&str>) -> Result<()> {
        let mut f: Vec<(&str, &str)> = vec![("callback_query_id", id)];
        if let Some(t) = text {
            f.push(("text", t));
        }
        self.post_form("answerCallbackQuery", &f)?;
        Ok(())
    }

    /// Replace a sent message's text (by `message_id`). Omitting `reply_markup`
    /// removes any inline keyboard — used to "latch" an answered `ask`: append
    /// the chosen answer and drop the buttons so it reads as resolved and can't
    /// be tapped again.
    pub fn edit_message_text(
        &self,
        chat: &str,
        message_id: i64,
        text: &str,
        parse_mode: Option<&str>,
    ) -> Result<()> {
        let mid = message_id.to_string();
        let mut f: Vec<(&str, &str)> =
            vec![("chat_id", chat), ("message_id", &mid), ("text", text)];
        if let Some(pm) = parse_mode {
            f.push(("parse_mode", pm));
        }
        self.post_form("editMessageText", &f)?;
        Ok(())
    }

    /// Replace only a message's inline keyboard (leave its text). Used to
    /// check-mark the chosen option (e.g. "ship it ✅") while keeping the
    /// buttons visible so the choice reads in context.
    pub fn edit_message_reply_markup(
        &self,
        chat: &str,
        message_id: i64,
        reply_markup: &str,
    ) -> Result<()> {
        let mid = message_id.to_string();
        self.post_form(
            "editMessageReplyMarkup",
            &[
                ("chat_id", chat),
                ("message_id", &mid),
                ("reply_markup", reply_markup),
            ],
        )?;
        Ok(())
    }

    /// `get_updates` with a caller-chosen `allowed_updates` JSON array. The
    /// default `get_updates` requests `["message","poll_answer"]`; the MCP
    /// router needs `callback_query` (inline-button taps) too.
    pub fn get_updates_allowed(
        &self,
        offset: i64,
        timeout_secs: u32,
        allowed_updates: &str,
    ) -> Result<serde_json::Value> {
        let off = offset.to_string();
        let to = timeout_secs.to_string();
        self.post_form(
            "getUpdates",
            &[
                ("offset", off.as_str()),
                ("timeout", to.as_str()),
                ("allowed_updates", allowed_updates),
            ],
        )
    }

    /// Register the `/` autocomplete menu. `commands_json` is a Bot API
    /// `setMyCommands` array: `[{"command":"ping","description":"…"}]`.
    pub fn set_my_commands(&self, commands_json: &str) -> Result<()> {
        self.post_form("setMyCommands", &[("commands", commands_json)])?;
        Ok(())
    }

    /// Send a poll and return its id (`result.poll.id`), so a project can map
    /// incoming `poll_answer` updates back to what was asked. Non-anonymous by
    /// default — Telegram only reports a voter for non-anonymous polls.
    pub fn send_poll(
        &self,
        chat: &str,
        question: &str,
        options: &[String],
        anonymous: bool,
        multi: bool,
    ) -> Result<String> {
        // Telegram wants `options` as a JSON array of strings; serde does the
        // quoting/escaping correctly for arbitrary option text.
        let options_json = serde_json::to_string(options).context("encoding poll options")?;
        let json = self.post_form(
            "sendPoll",
            &[
                ("chat_id", chat),
                ("question", question),
                ("options", options_json.as_str()),
                ("is_anonymous", if anonymous { "true" } else { "false" }),
                (
                    "allows_multiple_answers",
                    if multi { "true" } else { "false" },
                ),
            ],
        )?;
        json.pointer("/result/poll/id")
            .and_then(|v| v.as_str())
            .map(str::to_string)
            .context("sendPoll response had no result.poll.id")
    }

    /// Upload as a document: Telegram stores it byte-exact and shows a file
    /// attachment. The right default for anything where fidelity matters.
    pub fn send_document(
        &self,
        chat: &str,
        filename: &str,
        bytes: &[u8],
        caption: Option<&str>,
        parse_mode: Option<&str>,
        silent: bool,
    ) -> Result<()> {
        self.send_file(
            "sendDocument",
            "document",
            chat,
            filename,
            bytes,
            caption,
            parse_mode,
            silent,
        )
    }

    /// Upload as a photo: renders inline in the chat, but Telegram re-encodes
    /// and downscales it. Use `send_document` when the bytes must survive.
    pub fn send_photo(
        &self,
        chat: &str,
        filename: &str,
        bytes: &[u8],
        caption: Option<&str>,
        parse_mode: Option<&str>,
        silent: bool,
    ) -> Result<()> {
        self.send_file(
            "sendPhoto",
            "photo",
            chat,
            filename,
            bytes,
            caption,
            parse_mode,
            silent,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn send_file(
        &self,
        method: &str,
        field: &str,
        chat: &str,
        filename: &str,
        bytes: &[u8],
        caption: Option<&str>,
        parse_mode: Option<&str>,
        silent: bool,
    ) -> Result<()> {
        let boundary = "tgsendW3vK9qX1ZBOUNDARY";
        let mut body: Vec<u8> = Vec::new();
        push_field(&mut body, boundary, "chat_id", chat);
        if let Some(c) = caption {
            push_field(&mut body, boundary, "caption", c);
        }
        if let Some(pm) = parse_mode {
            push_field(&mut body, boundary, "parse_mode", pm);
        }
        if silent {
            push_field(&mut body, boundary, "disable_notification", "true");
        }
        // Sanitise the filename before it goes into the Content-Disposition
        // header: a basename may contain `"`, CR, LF or `\` (header injection /
        // multipart smuggling). Keep it to a safe set.
        let safe_name: String = filename
            .chars()
            .map(|c| {
                if c == '"' || c == '\\' || c.is_control() {
                    '_'
                } else {
                    c
                }
            })
            .collect();
        body.extend_from_slice(
            format!(
                "--{boundary}\r\nContent-Disposition: form-data; name=\"{field}\"; filename=\"{safe_name}\"\r\nContent-Type: application/octet-stream\r\n\r\n"
            )
            .as_bytes(),
        );
        body.extend_from_slice(bytes);
        body.extend_from_slice(b"\r\n");
        body.extend_from_slice(format!("--{boundary}--\r\n").as_bytes());

        let url = self.url(method);
        let ct = format!("multipart/form-data; boundary={boundary}");
        let json = match self
            .agent
            .post(&url)
            .set("Content-Type", &ct)
            .send_bytes(&body)
        {
            Ok(r) => r
                .into_json::<serde_json::Value>()
                .context("parsing response")?,
            Err(ureq::Error::Status(_, r)) => r
                .into_json::<serde_json::Value>()
                .context("parsing error response")?,
            Err(e) => return Err(e).context("network error talking to Telegram"),
        };
        Self::check(json)?;
        Ok(())
    }
}

fn push_field(body: &mut Vec<u8>, boundary: &str, name: &str, val: &str) {
    body.extend_from_slice(
        format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n")
            .as_bytes(),
    );
    body.extend_from_slice(val.as_bytes());
    body.extend_from_slice(b"\r\n");
}
