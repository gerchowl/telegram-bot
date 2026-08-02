// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Lars Gerchow
//! tg-onboard — interactive first-run setup for a Telegram bot.
//!   1. walks you through registering a bot with @BotFather
//!   2. validates the token you paste and encrypts it with sops/age
//!   3. polls for your chat id (you just message the bot once)
//!   4. writes a non-secret config.env and sends a test message
//!
//! Everything is written into the *current* project directory (override with --dir).
//!
//! `sops` and `age-keygen` are invoked as external programs — they are the
//! user's own tooling, not part of this implementation.

use std::fs;
use std::io::{IsTerminal, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{exit, Command, Stdio};
use telegram_bot::Tg;

const USAGE: &str = "usage: tg-onboard [--dir PROJECT_DIR]";

fn bold(s: &str) {
    println!("\x1b[1m{s}\x1b[0m");
}
fn dim(s: &str) {
    println!("\x1b[2m{s}\x1b[0m");
}
fn ok(s: &str) {
    println!("\x1b[32m✓\x1b[0m {s}");
}
/// Warnings carry formatted errors, so they go through redact for the same
/// reason the die paths do — a Telegram API error can embed the token URL.
fn warn(s: &str) {
    println!("\x1b[33m!\x1b[0m {}", telegram_bot::redact(s));
}
fn rule() {
    dim("────────────────────────────────────────────────────────");
}
fn die(s: &str) -> ! {
    die_code(s, 1)
}

/// Usage errors exit 2 (matching the other CLIs); runtime failures exit 1.
fn die_code(s: &str, code: i32) -> ! {
    eprintln!("\x1b[31m✗\x1b[0m {}", telegram_bot::redact(s));
    exit(code);
}

/// Read a line from stdin after printing `prompt` (no trailing newline).
fn ask(prompt: &str) -> String {
    print!("{prompt}");
    let _ = std::io::stdout().flush();
    let mut s = String::new();
    if std::io::stdin().read_line(&mut s).is_err() {
        die("could not read from stdin");
    }
    s.trim().to_string()
}

fn home() -> String {
    std::env::var("HOME").unwrap_or_default()
}

fn config_home() -> String {
    std::env::var("XDG_CONFIG_HOME").unwrap_or_else(|_| format!("{}/.config", home()))
}

/// Expand a leading `~` the way the shell would.
fn expand_tilde(p: &str) -> String {
    match p.strip_prefix('~') {
        Some(rest) => format!("{}{rest}", home()),
        None => p.to_string(),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut dir = std::env::current_dir()
        .unwrap_or_else(|e| die(&format!("cannot determine current directory: {e}")));

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-d" | "--dir" => {
                i += 1;
                match args.get(i) {
                    Some(v) => dir = PathBuf::from(v),
                    None => die_code("missing value for --dir", 2),
                }
            }
            "-h" | "--help" => {
                println!("{USAGE}");
                return;
            }
            s => die_code(&format!("unknown argument: {s}"), 2),
        }
        i += 1;
    }

    if let Err(e) = fs::create_dir_all(&dir) {
        die(&format!("cannot create {}: {e}", dir.display()));
    }
    if let Err(e) = std::env::set_current_dir(&dir) {
        die(&format!("cannot enter {}: {e}", dir.display()));
    }

    rule();
    bold("  Telegram bot onboarding");
    dim(&format!("  setting up in: {}", dir.display()));
    rule();
    println!();

    step_botfather();
    let token = step_token();
    let username = step_validate(&token);
    step_sops(&token);
    let chat_id = step_chat_id(&token, &username);
    step_config(&username, &chat_id);
    step_test(&token, &chat_id);
    step_next_steps(&username);
}

fn step_botfather() {
    bold("1. Register a bot with BotFather");
    println!(
        r#"
   Telegram has no API to create a bot — you do it once, by hand, in any
   Telegram client. There is no way around this step.

     a. Open Telegram and start a chat with  @BotFather
        ( https://t.me/BotFather )
     b. Send:  /newbot
     c. Give it a display name      (e.g. "Acme Deploy Bot")
     d. Give it a username ending in 'bot'  (e.g. "acme_deploy_bot")
     e. BotFather replies with a token that looks like:
            123456789:AAH...your-secret...xyz
     f. Copy that token — you'll paste it next.

   Optional, also via BotFather:  /setdescription, /setcommands, /setprivacy."#
    );
    println!();
    ask("   Press Enter once you have a token… ");
    println!();
}

fn step_token() -> String {
    loop {
        // On a real terminal, read silently so the token never lands in
        // scrollback / shell history. rpassword talks to /dev/tty and errors
        // out when there isn't one, so fall back to a plain stdin read when
        // input is piped (CI, the e2e suite) — there is no echo to suppress.
        let t = if std::io::stdin().is_terminal() {
            rpassword::prompt_password("\x1b[1m2. Paste the bot token\x1b[0m (input hidden): ")
                .unwrap_or_else(|e| die(&format!("could not read the token: {e}")))
        } else {
            ask("\x1b[1m2. Paste the bot token\x1b[0m: ")
        };
        let t: String = t.chars().filter(|c| !c.is_whitespace()).collect();
        if !t.is_empty() {
            return t;
        }
        eprintln!("\x1b[31m✗\x1b[0m empty — try again");
    }
}

/// Validate the pasted token against getMe and return the bot's username.
fn step_validate(token: &str) -> String {
    let tg = Tg::new(token.to_string());
    let resp = match tg.get_me() {
        Ok(r) => r,
        Err(e) => die(&format!("token rejected by Telegram: {e}")),
    };
    let username = resp
        .pointer("/result/username")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let first = resp
        .pointer("/result/first_name")
        .and_then(|v| v.as_str())
        .unwrap_or("?");
    ok(&format!("token valid — bot is @{username} ({first})"));
    println!();
    username
}

/// Derive the public age recipient from a private key file, or None if the
/// file is not a usable age identity.
fn age_recipient(path: &Path) -> Option<String> {
    let text = fs::read_to_string(path).ok()?;
    if !text.contains("AGE-SECRET-KEY-") {
        return None;
    }
    let out = Command::new("age-keygen")
        .arg("-y")
        .arg(path)
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout);
    s.lines()
        .next()
        .map(str::to_string)
        .filter(|l| !l.is_empty())
}

/// Validated age private keys in standard + repo-local locations, de-duplicated
/// by canonical path.
fn discover_age_keys() -> Vec<PathBuf> {
    let mut candidates: Vec<String> = Vec::new();
    if let Ok(v) = std::env::var("SOPS_AGE_KEY_FILE") {
        if !v.is_empty() {
            candidates.push(v);
        }
    }
    candidates.push(format!("{}/sops/age/keys.txt", config_home()));
    candidates.push(format!("{}/.config/sops/age/keys.txt", home()));
    for p in [
        "./keys.txt",
        "./age.key",
        "./.age/keys.txt",
        "./.sops/age/keys.txt",
    ] {
        candidates.push(p.to_string());
    }

    let mut seen: Vec<PathBuf> = Vec::new();
    let mut out: Vec<PathBuf> = Vec::new();
    for c in candidates {
        let p = PathBuf::from(&c);
        if !p.is_file() || age_recipient(&p).is_none() {
            continue;
        }
        let real = fs::canonicalize(&p).unwrap_or_else(|_| p.clone());
        if seen.contains(&real) {
            continue;
        }
        seen.push(real);
        out.push(p);
    }
    out
}

/// Generate a new age key, asking where it should live. Repo-local keys are
/// gitignored — a committed private key decrypts the token.
fn gen_age_key() -> PathBuf {
    let def = format!("{}/sops/age/keys.txt", config_home());
    println!("   Where should the new age key live?");
    println!("     1) {def}   (shared across your projects — recommended)");
    println!("     2) ./keys.txt   (repo-local; auto-gitignored)");
    let ans = ask("   Choice [1], or type a path: ");
    let loc = match ans.as_str() {
        "" | "1" => def,
        "2" => "./keys.txt".to_string(),
        other => expand_tilde(other),
    };
    let loc = PathBuf::from(loc);
    if loc.exists() {
        die(&format!(
            "refusing to overwrite existing file: {}",
            loc.display()
        ));
    }
    if let Some(parent) = loc.parent() {
        if !parent.as_os_str().is_empty() {
            let _ = fs::create_dir_all(parent);
        }
    }
    let status = Command::new("age-keygen")
        .arg("-o")
        .arg(&loc)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    match status {
        Ok(s) if s.success() => {}
        _ => die("age-keygen failed"),
    }
    // age-keygen already creates with O_EXCL|0600, but this is a private key
    // that decrypts the token — don't rely on that implicitly, and don't
    // continue if the permissions can't be confirmed.
    if fs::set_permissions(&loc, fs::Permissions::from_mode(0o600)).is_err() {
        die(&format!(
            "could not restrict permissions on {} — refusing to leave a private key readable",
            loc.display()
        ));
    }
    ok(&format!("created age key: {}", loc.display()));

    // Gitignore repo-local keys (relative path, or under $PWD).
    let cwd = std::env::current_dir().unwrap_or_default();
    let is_local = !loc.is_absolute() || loc.starts_with(&cwd);
    if is_local {
        if let Some(base) = loc.file_name().and_then(|s| s.to_str()) {
            let current = fs::read_to_string(".gitignore").unwrap_or_default();
            if !current.lines().any(|l| l == base) {
                let mut f = fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(".gitignore");
                if let Ok(ref mut f) = f {
                    let _ = writeln!(f, "{base}");
                    dim(&format!(
                        "   added {base} to .gitignore (never commit a private key)"
                    ));
                }
            }
        }
    }
    loc
}

fn step_sops(token: &str) {
    bold("3. Encrypting the token with sops");
    println!("   An age key is needed to encrypt the token. Looking for one…");

    let keys = discover_age_keys();
    let key_file: PathBuf = if !keys.is_empty() {
        println!("   Found age key(s):");
        for (i, k) in keys.iter().enumerate() {
            let rcpt = age_recipient(k).unwrap_or_default();
            println!("     {}) {}  →  {rcpt}", i + 1, k.display());
        }
        let ans = ask(&format!(
            "   Use which? [1-{}], (p)ath, (n)ew  [1]: ",
            keys.len()
        ));
        let ans = if ans.is_empty() { "1".to_string() } else { ans };
        match ans.chars().next().unwrap_or('1') {
            'p' | 'P' => PathBuf::from(expand_tilde(&ask("   Path to existing age key file: "))),
            'n' | 'N' => gen_age_key(),
            _ => match ans.parse::<usize>() {
                Ok(n) if n >= 1 && n <= keys.len() => keys[n - 1].clone(),
                _ => die(&format!("invalid choice: {ans}")),
            },
        }
    } else {
        warn("no age key found (looked in $SOPS_AGE_KEY_FILE, ~/.config/sops/age/, ./keys.txt, ./.sops/age/…)");
        let ans = ask("   (g)enerate a new key, or (p)rovide an existing path?  [g]: ");
        match ans.chars().next().unwrap_or('g') {
            'p' | 'P' => PathBuf::from(expand_tilde(&ask("   Path to existing age key file: "))),
            _ => gen_age_key(),
        }
    };

    if !key_file.is_file() {
        die(&format!("no usable age key file: {}", key_file.display()));
    }
    let recipient = age_recipient(&key_file).unwrap_or_else(|| {
        die(&format!(
            "{} is not a usable age private key",
            key_file.display()
        ))
    });

    // sops finds the identity through this env var; it must be set for the
    // encrypt call below and is inherited by the child process.
    std::env::set_var("SOPS_AGE_KEY_FILE", &key_file);
    ok(&format!("using age key: {}", key_file.display()));
    dim(&format!("   public recipient: {recipient}"));
    println!();

    // Ensure a .sops.yaml creation rule covers secrets/*.yaml.
    if !Path::new(".sops.yaml").exists() {
        let rule = format!(
            "# Managed by tg-onboard. Adds your age key as a recipient for secrets/*.yaml.\n\
             creation_rules:\n  \
             - path_regex: secrets/[^/]+\\.ya?ml$\n    \
             age: {recipient}\n"
        );
        if fs::write(".sops.yaml", rule).is_err() {
            die("could not write .sops.yaml");
        }
        ok(&format!("wrote .sops.yaml (recipient {recipient})"));
    } else {
        warn(".sops.yaml already exists — leaving it untouched");
        dim(&format!(
            "   ensure it has a rule for secrets/*.yaml including age key {recipient}"
        ));
    }

    // sops matches creation_rules against the *file path* it is given, so write
    // to the final secrets/ path and encrypt in place — otherwise the
    // secrets/*.yaml rule never matches ("no matching creation rules found").
    if fs::create_dir_all("secrets").is_err() {
        die("could not create secrets/");
    }
    // The token is plaintext on disk between this write and the sops call, so
    // narrow that window: drop any existing entry first (a pre-planted symlink
    // would otherwise redirect the write, and the cleanup below would unlink
    // only the link, stranding the plaintext at the target), then create the
    // file exclusively at 0600 rather than inheriting the umask.
    let secret = Path::new("secrets/telegram.yaml");
    if secret.symlink_metadata().is_ok() && fs::remove_file(secret).is_err() {
        die("could not replace secrets/telegram.yaml");
    }
    let plain = format!("telegram_bot_token: {token}\n");
    let written = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(secret)
        .and_then(|mut f| f.write_all(plain.as_bytes()));
    if written.is_err() {
        die("could not write secrets/telegram.yaml");
    }
    let status = Command::new("sops")
        .args(["--encrypt", "--in-place", "secrets/telegram.yaml"])
        .stderr(Stdio::null())
        .status();
    match status {
        Ok(s) if s.success() => {
            ok("encrypted token → secrets/telegram.yaml (safe to commit)");
        }
        _ => {
            // Never leave the plaintext token on disk.
            let _ = fs::remove_file("secrets/telegram.yaml");
            die("sops encryption failed (does .sops.yaml have a rule for secrets/*.yaml with your key?)");
        }
    }
    println!();
}

fn step_chat_id(token: &str, username: &str) -> String {
    bold("4. Finding your chat id");
    println!(
        r#"
   The bot can only message a chat that has messaged it first.

     → Open Telegram, find  @{username}, and send it any message
       (just tap Start, or type /start).
     → For a group: add the bot to the group, then send a message there.
"#
    );

    let tg = Tg::new(token.to_string());
    tg.delete_webhook(); // webhooks block getUpdates polling

    let mut offset: i64 = 0;
    let mut waited = 0;
    let mut found: Option<(String, String)> = None;
    print!("   waiting for a message");
    let _ = std::io::stdout().flush();
    while waited < 180 {
        // my_chat_member covers "added the bot to a group" (no message sent).
        if let Ok(resp) = tg.get_updates_allowed(offset, 30, r#"["message","my_chat_member"]"#) {
            let ups = resp
                .pointer("/result")
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default();
            if let Some(last) = ups.last() {
                if let Some(id) = last.pointer("/update_id").and_then(|v| v.as_i64()) {
                    offset = id + 1;
                }
                let chat = last
                    .pointer("/message/chat")
                    .or_else(|| last.pointer("/my_chat_member/chat"));
                if let Some(chat) = chat {
                    if let Some(id) = chat.get("id") {
                        let id = id.as_i64().map(|n| n.to_string()).unwrap_or_default();
                        let label = ["title", "username", "first_name"]
                            .iter()
                            .find_map(|k| chat.get(*k).and_then(|v| v.as_str()))
                            .unwrap_or("?");
                        let kind = chat.get("type").and_then(|v| v.as_str()).unwrap_or("?");
                        if !id.is_empty() {
                            found = Some((id, format!("{label} ({kind})")));
                            break;
                        }
                    }
                }
            }
        }
        print!(".");
        let _ = std::io::stdout().flush();
        waited += 30;
    }
    println!();

    match found {
        Some((id, label)) => {
            ok(&format!("found chat: {label}  →  id {id}"));
            println!();
            id
        }
        None => {
            eprintln!("\x1b[31m✗\x1b[0m timed out waiting for a message.");
            let id = ask("   Enter the chat id manually (or leave blank to skip): ");
            println!();
            id
        }
    }
}

fn step_config(username: &str, chat_id: &str) {
    bold("5. Writing config.env");
    let cwd = std::env::current_dir().unwrap_or_default();
    let abs_sops = cwd.join("secrets/telegram.yaml");
    // `${VAR:-...}` form ⇒ explicit environment variables override the config file.
    let body = format!(
        "# Non-secret telegram-bot config — written by tg-onboard. Safe to commit.\n\
         # The token itself stays encrypted in secrets/telegram.yaml.\n\
         export TELEGRAM_BOT_SOPS_FILE=\"${{TELEGRAM_BOT_SOPS_FILE:-{}}}\"\n\
         export TELEGRAM_BOT_SOPS_KEY=\"${{TELEGRAM_BOT_SOPS_KEY:-telegram_bot_token}}\"\n\
         export TELEGRAM_BOT_USERNAME=\"${{TELEGRAM_BOT_USERNAME:-{username}}}\"\n\
         export TELEGRAM_CHAT_ID=\"${{TELEGRAM_CHAT_ID:-{chat_id}}}\"\n",
        abs_sops.display()
    );
    if fs::write("config.env", body).is_err() {
        die("could not write config.env");
    }
    ok("wrote config.env");
    dim(&format!(
        "   source it (or set TELEGRAM_BOT_CONFIG={}/config.env) before using tg-send.",
        cwd.display()
    ));
    println!();
}

fn step_test(token: &str, chat_id: &str) {
    if chat_id.is_empty() {
        warn("no chat id — skipping test message");
        println!();
        return;
    }
    bold("6. Sending a test message");
    let tg = Tg::new(token.to_string());
    match tg.send_message(
        chat_id,
        "✅ telegram-bot onboarding complete. You'll receive messages here.",
        None,
        false,
    ) {
        Ok(()) => ok("test message sent — check Telegram"),
        Err(e) => warn(&format!("test message failed: {e}")),
    }
    println!();
}

fn step_next_steps(username: &str) {
    let _ = username;
    rule();
    bold("  Done. Next steps");
    println!(
        r#"
  Send from anything:
     source ./config.env
     tg-send "hello from $(hostname)"
     journalctl -u myservice -n 50 | tg-send --file -

  Receive / run commands (optional) — see README.md "Commands & rights":
     • post-only (default): the bot only sends; inbound is ignored.
     • command mode: drop executables in a commands dir + set an allowlist,
       then run the tg-bot daemon (or the NixOS 'services.telegram-bot' module).

  NixOS service: point services.telegram-bot.tokenFile at a sops-nix secret
  decrypted from secrets/telegram.yaml. Full example in README.md."#
    );
    rule();
}
