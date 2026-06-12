// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Lars Gerchow
//! tg-bot — long-polling daemon. Receives messages and (optionally) runs
//! commands under the same safe rights model as the bash version:
//!   * post-only by default (TELEGRAM_POST_ONLY=1) — built-ins only;
//!   * command mode needs an allowlist AND a commands dir;
//!   * command names are restricted to [A-Za-z0-9_-] (no traversal);
//!   * args go straight to argv via std::process::Command — there is no shell,
//!     so glob/word-split/eval cannot happen by construction.

use std::collections::HashSet;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;
use telegram_bot::{resolve_token, Config, Tg};
use wait_timeout::ChildExt;

const TG_LIMIT: usize = 3900; // headroom under Telegram's 4096-char cap

fn main() {
    if let Err(e) = run() {
        eprintln!("tg-bot: {e:#}");
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
                eprintln!("tg-bot: getUpdates error: {e:#}");
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
            handle_update(
                &tg,
                upd,
                post_only,
                &allow,
                commands_dir.as_deref(),
                cmd_timeout,
            );
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
/// `# desc:` line — same as the bash daemon. No-op in post-only mode, without a
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
    let rd = match std::fs::read_dir(dir) {
        Ok(r) => r,
        Err(_) => return,
    };
    let mut entries: Vec<_> = rd.filter_map(Result::ok).collect();
    entries.sort_by_key(std::fs::DirEntry::file_name);
    let mut cmds: Vec<serde_json::Value> = Vec::new();
    for e in entries {
        let path = e.path();
        if !is_executable_file(&path) {
            continue;
        }
        let name = match e.file_name().into_string() {
            Ok(n) => n,
            Err(_) => continue,
        };
        if name.starts_with('_')
            || name.is_empty()
            || name.len() > 32
            || !name
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
        {
            continue;
        }
        if let Some(desc) = read_desc(&path) {
            cmds.push(serde_json::json!({"command": name, "description": desc}));
        }
    }
    if cmds.is_empty() {
        return;
    }
    let json = serde_json::Value::Array(cmds.clone()).to_string();
    match tg.set_my_commands(&json) {
        Ok(()) => eprintln!(
            "tg-bot: registered {} command(s) via setMyCommands",
            cmds.len()
        ),
        Err(e) => eprintln!("tg-bot: setMyCommands failed: {e:#}"),
    }
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
    if msg.chars().count() > TG_LIMIT {
        msg = msg.chars().take(TG_LIMIT).collect();
    }
    let _ = tg.send_message(chat, &msg, None, false);
}

fn run_with_timeout(path: &Path, argv: &[&str], chat: &str, cmd: &str, secs: u64) -> (String, i32) {
    let dir = path.parent().unwrap_or_else(|| Path::new("."));
    let mut child = match Command::new(path)
        .args(argv)
        .current_dir(dir)
        .env("TG_CHAT_ID", chat)
        .env("TG_COMMAND", cmd)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => return (format!("failed to run /{cmd}: {e}"), 127),
    };

    // Drain both pipes in threads so a chatty command can't deadlock on a full
    // pipe buffer while we wait.
    let mut so = child.stdout.take().expect("stdout piped");
    let mut se = child.stderr.take().expect("stderr piped");
    let th_o = std::thread::spawn(move || {
        let mut b = Vec::new();
        let _ = std::io::Read::read_to_end(&mut so, &mut b);
        b
    });
    let th_e = std::thread::spawn(move || {
        let mut b = Vec::new();
        let _ = std::io::Read::read_to_end(&mut se, &mut b);
        b
    });

    let timed_out = match child.wait_timeout(Duration::from_secs(secs)) {
        Ok(Some(_)) => false,
        Ok(None) => {
            let _ = child.kill();
            let _ = child.wait();
            true
        }
        Err(_) => {
            let _ = child.kill();
            true
        }
    };
    let rc = child.wait().ok().and_then(|s| s.code()).unwrap_or(-1);
    let o = th_o.join().unwrap_or_default();
    let e = th_e.join().unwrap_or_default();
    let mut s = String::from_utf8_lossy(&o).into_owned();
    s.push_str(&String::from_utf8_lossy(&e));
    let mut s = s.trim_end().to_string();
    if timed_out {
        s.push_str(&format!("\n(/{cmd} timed out after {secs}s)"));
        return (s, 124);
    }
    (s, rc)
}

fn help_text(post_only: bool, commands_dir: Option<&str>) -> String {
    let mut t = String::from(
        "Available commands:\n  /start — check the bot is alive\n  /id    — show this chat id\n  /help  — this message",
    );
    match (post_only, commands_dir) {
        (false, Some(d)) => {
            if let Ok(rd) = std::fs::read_dir(d) {
                let mut names: Vec<String> = rd
                    .filter_map(Result::ok)
                    .filter(|e| is_executable_file(&e.path()))
                    .filter_map(|e| e.file_name().into_string().ok())
                    .collect();
                names.sort();
                if !names.is_empty() {
                    t.push_str("\nCustom commands:");
                    for n in names {
                        t.push_str(&format!("\n  /{n}"));
                    }
                }
            }
        }
        _ => t.push_str("\n(this bot is post-only; custom commands are disabled)"),
    }
    t
}
