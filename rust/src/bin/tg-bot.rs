// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Lars Gerchow
//! tg-bot — long-polling daemon. Receives messages and (optionally) runs
//! commands under a safe rights model:
//!   * post-only by default (TELEGRAM_POST_ONLY=1) — built-ins only;
//!   * command mode needs an allowlist AND a commands dir;
//!   * command names are restricted to [A-Za-z0-9_-] (no traversal);
//!   * args go straight to argv via std::process::Command — there is no shell,
//!     so glob/word-split/eval cannot happen by construction.

use std::collections::HashSet;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use telegram_bot::{redact, resolve_token, Config, Tg};
use wait_timeout::ChildExt;

const TG_LIMIT: usize = 3900; // headroom under Telegram's 4096-char cap

// Telegram's caption cap is 1024, counted in UTF-16 code units while we count
// Unicode scalars — an emoji-heavy caption counts double there. Same headroom
// approach as TG_LIMIT, so we split to a follow-up message before Telegram
// rejects the upload outright.
const CAPTION_LIMIT: usize = 900;

const MAX_UPLOAD: u64 = 50_000_000; // Telegram's bot-API upload cap

fn main() {
    if let Err(e) = run() {
        eprintln!("tg-bot: {}", redact(&format!("{e:#}")));
        std::process::exit(1);
    }
}

fn run() -> anyhow::Result<()> {
    let cfg = Config::load(None);
    let token = resolve_token(&cfg)?;
    let tg = Tg::new(token);

    let post_only = cfg.get("TELEGRAM_POST_ONLY").as_deref() != Some("0");
    let commands_dir = cfg.get("TELEGRAM_COMMANDS_DIR");
    let allow: HashSet<String> = cfg
        .get("TELEGRAM_ALLOWED_CHAT_IDS")
        .unwrap_or_default()
        .split([',', ' '])
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect();
    let cmd_timeout: u64 = cfg
        .get("TELEGRAM_COMMAND_TIMEOUT")
        .and_then(|s| s.parse().ok())
        .unwrap_or(60);

    let state_dir = cfg.get("TELEGRAM_BOT_STATE_DIR").unwrap_or_else(|| {
        let base = std::env::var("XDG_STATE_HOME")
            .ok()
            .or_else(|| {
                std::env::var("HOME")
                    .ok()
                    .map(|h| format!("{h}/.local/state"))
            })
            .unwrap_or_else(|| ".".into());
        format!("{base}/telegram-bot")
    });
    let _ = std::fs::create_dir_all(&state_dir);
    let offset_file = format!("{state_dir}/offset");
    let mut offset: i64 = std::fs::read_to_string(&offset_file)
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0);

    eprintln!(
        "tg-bot: starting (post_only={}, commands_dir={}, allow={})",
        post_only as u8,
        commands_dir.as_deref().unwrap_or("none"),
        if allow.is_empty() {
            "none".to_string()
        } else {
            allow.iter().cloned().collect::<Vec<_>>().join(",")
        }
    );
    tg.delete_webhook();
    register_commands(&tg, &cfg, post_only, commands_dir.as_deref());

    loop {
        let resp = match tg.get_updates(offset, 50) {
            Ok(r) => r,
            Err(e) => {
                // 401/404 mean the token is invalid, empty or revoked — a config
                // error no amount of retrying fixes. Die so the supervisor
                // reports it, rather than logging the same rejection forever in
                // a system whose failure symptom is silence. Everything else
                // (409 conflicts, 5xx, transport resets) is a blip: retry.
                if let Some(api) = e.downcast_ref::<telegram_bot::ApiError>() {
                    if api.is_auth_failure() {
                        return Err(anyhow::anyhow!(
                            "FATAL getUpdates {}: {} — the bot token is invalid or empty; \
                             refusing to retry. Check token resolution (sops/age).",
                            api.code,
                            api.description
                        ));
                    }
                }
                eprintln!("tg-bot: getUpdates error: {}", redact(&format!("{e:#}")));
                std::thread::sleep(Duration::from_secs(3));
                continue;
            }
        };
        let results = resp
            .get("result")
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        for upd in &results {
            if upd.get("poll_answer").is_some() {
                handle_poll_answer(&tg, upd, commands_dir.as_deref(), cmd_timeout);
            } else {
                handle_update(
                    &tg,
                    upd,
                    post_only,
                    &allow,
                    commands_dir.as_deref(),
                    cmd_timeout,
                );
            }
            if let Some(uid) = upd.get("update_id").and_then(serde_json::Value::as_i64) {
                offset = uid + 1;
                let _ = std::fs::write(&offset_file, offset.to_string());
            }
        }
    }
}

fn handle_update(
    tg: &Tg,
    upd: &serde_json::Value,
    post_only: bool,
    allow: &HashSet<String>,
    commands_dir: Option<&str>,
    cmd_timeout: u64,
) {
    let chat = match upd.pointer("/message/chat/id") {
        Some(v) => v
            .as_i64()
            .map(|n| n.to_string())
            .or_else(|| v.as_str().map(str::to_string)),
        None => None,
    };
    let chat = match chat {
        Some(c) => c,
        None => return,
    };
    let text = match upd.pointer("/message/text").and_then(|v| v.as_str()) {
        Some(t) => t,
        None => return,
    };
    if !text.starts_with('/') {
        return; // only react to /commands
    }

    let after = &text[1..];
    let (cmd_raw, rest) = match after.find(char::is_whitespace) {
        Some(i) => (&after[..i], after[i..].trim_start()),
        None => (after, ""),
    };
    let cmd = cmd_raw.split('@').next().unwrap_or(cmd_raw); // strip @botname suffix

    match cmd {
        "start" => {
            let _ = tg.send_message(
                &chat,
                &format!("👋 Online. /help for commands. This chat id is {chat}."),
                None,
                false,
            );
            return;
        }
        "id" => {
            let _ = tg.send_message(&chat, &format!("chat id: {chat}"), None, false);
            return;
        }
        "help" => {
            let _ = tg.send_message(&chat, &help_text(post_only, commands_dir), None, false);
            return;
        }
        _ => {}
    }

    if post_only {
        let _ = tg.send_message(
            &chat,
            "🔒 This bot is post-only; commands are disabled.",
            None,
            false,
        );
        return;
    }
    if !allow.contains(&chat) {
        eprintln!("tg-bot: rejected /{cmd} from unauthorized chat {chat}");
        let _ = tg.send_message(&chat, "⛔ Not authorized.", None, false);
        return;
    }
    run_command(tg, &chat, cmd, rest, commands_dir, cmd_timeout);
}

/// Auto-register the `/` menu (Bot API setMyCommands) from each command's first
/// `# desc:` line. No-op in post-only mode, without a
/// commands dir, or when `TELEGRAM_SET_COMMANDS=0`. Telegram command names must be
/// 1–32 chars of `[a-z0-9_]`; others (and `_`-prefixed hooks) are skipped.
fn register_commands(tg: &Tg, cfg: &Config, post_only: bool, commands_dir: Option<&str>) {
    if cfg.get("TELEGRAM_SET_COMMANDS").as_deref() == Some("0") || post_only {
        return;
    }
    let dir = match commands_dir {
        Some(d) => d,
        None => return,
    };
    // The menu is a subset of what /help shows: Telegram requires a description
    // per entry and rejects names outside [a-z0-9_]. A `/Deploy-Prod` command
    // stays invokable and listed in /help, it just can't be in the menu.
    let cmds: Vec<serde_json::Value> = list_commands(dir)
        .into_iter()
        .filter(|(name, _)| menu_eligible(name))
        .filter_map(|(name, desc)| {
            desc.map(|d| serde_json::json!({"command": name, "description": d}))
        })
        .collect();
    if cmds.is_empty() {
        return;
    }
    let json = serde_json::Value::Array(cmds.clone()).to_string();
    match tg.set_my_commands(&json) {
        Ok(()) => eprintln!(
            "tg-bot: registered {} command(s) via setMyCommands",
            cmds.len()
        ),
        Err(e) => eprintln!(
            "tg-bot: setMyCommands failed: {}",
            redact(&format!("{e:#}"))
        ),
    }
}

/// Telegram only accepts 1–32 chars of `[a-z0-9_]` for a `setMyCommands` entry.
/// `valid_cmd` is deliberately wider (it also allows uppercase and `-`), so a
/// command can be invokable without being menu-eligible — `/help` lists those,
/// the `/` menu can't.
fn menu_eligible(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 32
        && name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
}

/// Every command a user can actually invoke, sorted, each paired with its
/// `# desc:` line where the script has one. Single source of truth for both the
/// `/` menu and `/help`, so the two can't disagree about what exists.
///
/// Skips non-executables and `_`-prefixed hooks (`_poll_answer` is invoked by
/// the daemon, never typed). The filter is `valid_cmd` — the same rule the
/// dispatcher uses — so anything listed here is genuinely runnable.
fn list_commands(dir: &str) -> Vec<(String, Option<String>)> {
    let rd = match std::fs::read_dir(dir) {
        Ok(r) => r,
        Err(_) => return Vec::new(),
    };
    let mut entries: Vec<_> = rd.filter_map(Result::ok).collect();
    entries.sort_by_key(std::fs::DirEntry::file_name);
    let mut out = Vec::new();
    for e in entries {
        let path = e.path();
        if !is_executable_file(&path) {
            continue;
        }
        let name = match e.file_name().into_string() {
            Ok(n) => n,
            Err(_) => continue,
        };
        if name.starts_with('_') || !valid_cmd(&name) {
            continue;
        }
        let desc = read_desc(&path);
        out.push((name, desc));
    }
    out
}

/// First `# desc: <text>` line of a command script (≤256 chars), if any.
fn read_desc(path: &Path) -> Option<String> {
    let text = std::fs::read_to_string(path).ok()?;
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix('#') {
            if let Some(d) = rest.trim_start().strip_prefix("desc:") {
                let d = d.trim();
                if !d.is_empty() {
                    return Some(d.chars().take(256).collect());
                }
            }
        }
    }
    None
}

/// Command names must be a simple identifier — this is the control that keeps
/// execution inside the commands dir (rejects "/", ".", traversal, whitespace).
fn valid_cmd(cmd: &str) -> bool {
    !cmd.is_empty()
        && cmd
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

fn is_executable_file(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    match std::fs::metadata(p) {
        Ok(m) => m.is_file() && (m.permissions().mode() & 0o111) != 0,
        Err(_) => false,
    }
}

fn run_command(
    tg: &Tg,
    chat: &str,
    cmd: &str,
    rest: &str,
    commands_dir: Option<&str>,
    timeout_secs: u64,
) {
    let unknown = |tg: &Tg| {
        let _ = tg.send_message(
            chat,
            &format!("❓ Unknown command: /{cmd}  (try /help)"),
            None,
            false,
        );
    };
    if !valid_cmd(cmd) {
        unknown(tg);
        return;
    }
    let dir = match commands_dir {
        Some(d) => d,
        None => {
            unknown(tg);
            return;
        }
    };
    let path = Path::new(dir).join(cmd);
    if !is_executable_file(&path) {
        unknown(tg);
        return;
    }

    // Whitespace-split into argv. No shell ⇒ no glob/word-split/eval.
    let argv: Vec<&str> = rest.split_whitespace().collect();
    let (out, rc) = run_with_timeout(&path, &argv, chat, cmd, timeout_secs);
    let mut msg = if out.is_empty() {
        format!("(/{cmd} exited {rc} with no output)")
    } else {
        out
    };
    let sentinels = take_sentinels(&mut msg);
    let parse_mode = sentinels
        .iter()
        .find(|(k, _)| k == "parse_mode")
        .map(|(_, v)| v.clone());

    // `\x01document=` / `\x01photo=` attach a file. Opt-in and confined to
    // TELEGRAM_MEDIA_ROOT — see resolve_media.
    let media = sentinels
        .iter()
        .find(|(k, _)| k == "document" || k == "photo");
    if let Some((kind, path)) = media {
        match resolve_media(path) {
            Ok((bytes, name)) => {
                // Telegram caps captions well below the message limit; longer
                // output would be rejected outright, so send it separately.
                let short = msg.chars().count() <= CAPTION_LIMIT;
                let (caption, leftover) = if short {
                    (msg.as_str(), "")
                } else {
                    ("", msg.as_str())
                };
                let cap = if caption.is_empty() {
                    None
                } else {
                    Some(caption)
                };
                let res = if kind == "photo" {
                    tg.send_photo(chat, &name, &bytes, cap, parse_mode.as_deref(), false)
                } else {
                    tg.send_document(chat, &name, &bytes, cap, parse_mode.as_deref(), false)
                };
                let leftover = leftover.to_string();
                match res {
                    Ok(()) => {
                        if !leftover.is_empty() {
                            send_text(tg, chat, leftover, parse_mode.as_deref());
                        }
                        return;
                    }
                    // Fall through to the text reply rather than swallowing the
                    // command's output because the upload failed.
                    Err(e) => eprintln!(
                        "tg-bot: /{cmd} {kind} upload failed: {}",
                        redact(&format!("{e:#}"))
                    ),
                }
            }
            Err(why) => {
                eprintln!("tg-bot: /{cmd} {kind} refused: {why}");
                if msg.is_empty() {
                    msg = format!("(/{cmd} attachment refused: {why})");
                } else {
                    msg.push_str(&format!("\n\n(attachment refused: {why})"));
                }
            }
        }
    }
    send_text(tg, chat, msg, parse_mode.as_deref());
}

fn send_text(tg: &Tg, chat: &str, mut msg: String, parse_mode: Option<&str>) {
    if msg.chars().count() > TG_LIMIT {
        msg = msg.chars().take(TG_LIMIT).collect();
    }
    let _ = tg.send_message(chat, &msg, parse_mode, false);
}

/// Strip leading `\x01key=value` sentinel lines from a command's output and
/// return them. Only a contiguous run at the very start counts, so a sentinel
/// can never be injected by data appearing later in the output.
fn take_sentinels(msg: &mut String) -> Vec<(String, String)> {
    let mut found = Vec::new();
    while let Some(rest) = msg.strip_prefix('\u{1}') {
        let (line, after) = match rest.split_once('\n') {
            // Tolerate CRLF: a command emitting \r\n would otherwise leave the
            // \r inside the value, so a path silently becomes "no such file".
            Some((l, a)) => (l.trim_end_matches('\r').to_string(), a.to_string()),
            None => (rest.trim_end_matches('\r').to_string(), String::new()),
        };
        let (k, v) = match line.split_once('=') {
            Some((k, v)) => (k.to_string(), v.to_string()),
            None => break, // not a sentinel; leave the text alone
        };
        found.push((k, v));
        *msg = after;
    }
    found
}

/// Read a file a command asked to attach.
///
/// Disabled unless `TELEGRAM_MEDIA_ROOT` is set, and the path must resolve
/// inside it. A command already runs arbitrary code as the bot user, so this
/// is not a trust boundary against a hostile command — it bounds the blast
/// radius of a BUGGY one, e.g. a script that interpolates a Telegram-supplied
/// argument into a path and turns `/report ../../etc/shadow` into an
/// arbitrary-file read. Resolution is via canonicalize, so symlinks out of the
/// root are rejected too.
fn resolve_media(path: &str) -> Result<(Vec<u8>, String), String> {
    let root = match std::env::var("TELEGRAM_MEDIA_ROOT") {
        Ok(r) if !r.is_empty() => r,
        _ => return Err("TELEGRAM_MEDIA_ROOT is not set".into()),
    };
    let root =
        std::fs::canonicalize(&root).map_err(|_| format!("media root '{root}' does not exist"))?;
    let real = std::fs::canonicalize(path).map_err(|_| "no such file".to_string())?;
    if !real.starts_with(&root) {
        return Err("path is outside TELEGRAM_MEDIA_ROOT".into());
    }
    // Reject a non-regular file (FIFO, device) BEFORE opening it — opening a
    // FIFO for reading blocks until a writer appears, which would wedge the
    // daemon. symlink_metadata doesn't re-resolve, so this describes exactly
    // the leaf canonicalize landed on.
    let pre = std::fs::symlink_metadata(&real).map_err(|_| "cannot stat file".to_string())?;
    if !pre.is_file() {
        return Err("not a regular file".into());
    }
    // Size and type are then checked against the OPEN handle, not the path, so
    // a swap between the check and the read can't redirect us.
    let f = std::fs::File::open(&real).map_err(|_| "cannot read file".to_string())?;
    let meta = f.metadata().map_err(|_| "cannot stat file".to_string())?;
    if !meta.is_file() {
        return Err("not a regular file".into());
    }
    if meta.len() > MAX_UPLOAD {
        return Err(format!(
            "file is {} MB, over Telegram's {} MB bot limit",
            meta.len() / 1_000_000,
            MAX_UPLOAD / 1_000_000
        ));
    }
    let mut bytes = Vec::with_capacity(meta.len() as usize);
    let mut capped = std::io::Read::take(f, MAX_UPLOAD);
    std::io::Read::read_to_end(&mut capped, &mut bytes)
        .map_err(|_| "cannot read file".to_string())?;
    let name = real
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("file")
        .to_string();
    Ok((bytes, name))
}

/// Run `path` with `argv` + `envs`, capturing combined stdout+stderr under a timeout.
/// Returns (trimmed output, timed_out, exit code). No shell ⇒ no glob/word-split/eval.
fn spawn_capture(
    path: &Path,
    argv: &[&str],
    envs: &[(&str, &str)],
    secs: u64,
) -> (String, bool, i32) {
    let dir = path.parent().unwrap_or_else(|| Path::new("."));
    let mut builder = Command::new(path);
    builder
        .args(argv)
        .current_dir(dir)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        // Own process group, so a timeout can kill the command AND anything it
        // started. Killing just the child leaves grandchildren holding the
        // stdout pipe, and the reads below would then never see EOF.
        .process_group(0);
    for (k, v) in envs {
        builder.env(k, v);
    }
    let mut child = match builder.spawn() {
        Ok(c) => c,
        Err(e) => return (format!("failed to run {}: {e}", path.display()), false, 127),
    };
    let pgid = child.id() as i32;

    // Drain both pipes on threads so a chatty command can't deadlock on a full
    // pipe buffer, and hand the results back over channels rather than by
    // joining: a join is unbounded, and read_to_end only returns at EOF, which
    // never comes while ANY process holds the write end. That is what wedged
    // the daemon permanently (#47) — a command exiting instantly after leaving
    // a background process behind was enough.
    let so = child.stdout.take().expect("stdout piped");
    let se = child.stderr.take().expect("stderr piped");
    let (buf_o, rx_o) = drain(so);
    let (buf_e, rx_e) = drain(se);

    let timed_out = match child.wait_timeout(Duration::from_secs(secs)) {
        Ok(Some(_)) => false,
        Ok(None) | Err(_) => {
            kill_group(pgid);
            let _ = child.wait();
            true
        }
    };
    let rc = child.wait().ok().and_then(|s| s.code()).unwrap_or(-1);

    // The command has exited; its own output is already in flight. Wait only
    // briefly for EOF. If it doesn't come, something it spawned still holds the
    // pipe — take what arrived and kill the group so the fd is released rather
    // than leaked. A command that legitimately starts a daemon must detach it
    // (setsid/nohup with its own redirects), which closes the inherited pipe.
    let grace = Duration::from_secs(2);
    let eof_o = rx_o.recv_timeout(grace).is_ok();
    let eof_e = rx_e.recv_timeout(grace).is_ok();
    if !(eof_o && eof_e) {
        // Something the command spawned still holds a pipe. Reap the group so
        // the fd is released rather than leaked; cheap and harmless otherwise.
        kill_group(pgid);
    }
    let o = std::mem::take(&mut *buf_o.lock().unwrap());
    let e = std::mem::take(&mut *buf_e.lock().unwrap());

    let mut s = String::from_utf8_lossy(&o).into_owned();
    s.push_str(&String::from_utf8_lossy(&e));
    (s.trim_end().to_string(), timed_out, rc)
}

/// Read a pipe into a shared buffer, signalling on EOF.
///
/// Incremental rather than `read_to_end` so output the command already produced
/// survives even when EOF never arrives — a grandchild holding the write end
/// would otherwise cost us the whole reply, not just the wait.
fn drain<R: std::io::Read + Send + 'static>(
    mut r: R,
) -> (Arc<Mutex<Vec<u8>>>, std::sync::mpsc::Receiver<()>) {
    let buf = Arc::new(Mutex::new(Vec::new()));
    let sink = buf.clone();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut chunk = [0u8; 8192];
        loop {
            match r.read(&mut chunk) {
                Ok(0) | Err(_) => break,
                Ok(n) => sink.lock().unwrap().extend_from_slice(&chunk[..n]),
            }
        }
        let _ = tx.send(());
    });
    (buf, rx)
}

/// SIGKILL a whole process group. The command runs in its own group, so this
/// reaps anything it spawned; without it a grandchild survives and keeps the
/// command's stdout pipe open forever.
fn kill_group(pgid: i32) {
    if pgid > 0 {
        unsafe { libc::killpg(pgid, libc::SIGKILL) };
    }
}

fn run_with_timeout(path: &Path, argv: &[&str], chat: &str, cmd: &str, secs: u64) -> (String, i32) {
    let (mut s, timed_out, rc) = spawn_capture(
        path,
        argv,
        &[("TG_CHAT_ID", chat), ("TG_COMMAND", cmd)],
        secs,
    );
    if timed_out {
        s.push_str(&format!("\n(/{cmd} timed out after {secs}s)"));
        return (s, 124);
    }
    (s, rc)
}

/// A non-anonymous poll vote: run the optional `_poll_answer` hook in the commands dir with
/// POLL_ID / POLL_OPTIONS (JSON array of selected indexes) / POLL_VOTER; any output goes to the
/// configured chat as a confirmation.
fn handle_poll_answer(tg: &Tg, upd: &serde_json::Value, commands_dir: Option<&str>, secs: u64) {
    let dir = match commands_dir {
        Some(d) => d,
        None => return,
    };
    let path = Path::new(dir).join("_poll_answer");
    if !is_executable_file(&path) {
        return;
    }
    let poll_id = upd
        .pointer("/poll_answer/poll_id")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    if poll_id.is_empty() {
        return;
    }
    let voter = upd
        .pointer("/poll_answer/user/id")
        .and_then(serde_json::Value::as_i64)
        .map(|n| n.to_string())
        .unwrap_or_default();
    let opts = upd
        .pointer("/poll_answer/option_ids")
        .map(serde_json::Value::to_string)
        .unwrap_or_else(|| "[]".to_string());
    let (out, _timed_out, _rc) = spawn_capture(
        &path,
        &[],
        &[
            ("POLL_ID", poll_id),
            ("POLL_OPTIONS", &opts),
            ("POLL_VOTER", &voter),
        ],
        secs,
    );
    if out.is_empty() {
        return;
    }
    if let Ok(chat) = std::env::var("TELEGRAM_CHAT_ID") {
        if !chat.is_empty() {
            let msg: String = out.chars().take(TG_LIMIT).collect();
            let _ = tg.send_message(&chat, &msg, None, false);
        }
    }
}

fn help_text(post_only: bool, commands_dir: Option<&str>) -> String {
    let mut t = String::from(
        "Available commands:\n  /start — check the bot is alive\n  /id    — show this chat id\n  /help  — this message",
    );
    match (post_only, commands_dir) {
        (false, Some(d)) => {
            let cmds = list_commands(d);
            if !cmds.is_empty() {
                // Pad names into a column so the descriptions line up, the way
                // the built-ins above already do.
                let width = cmds
                    .iter()
                    .map(|(n, _)| n.chars().count())
                    .max()
                    .unwrap_or(0);
                t.push_str("\nCustom commands:");
                for (n, desc) in cmds {
                    match desc {
                        Some(d) => {
                            let pad = " ".repeat(width - n.chars().count());
                            t.push_str(&format!("\n  /{n}{pad} — {d}"));
                        }
                        None => t.push_str(&format!("\n  /{n}")),
                    }
                }
            }
        }
        _ => t.push_str("\n(this bot is post-only; custom commands are disabled)"),
    }
    t
}
