// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Lars Gerchow
//! tg-send — push a message or document to Telegram. Drop-in compatible with
//! the bash tg-send: same flags, env contract and token/chat resolution.

use std::io::{IsTerminal, Read};
use std::process::exit;
use telegram_bot::{resolve_token, Config, Tg};

const USAGE: &str = "tg-send — send a Telegram message or document.

USAGE:
  tg-send [options] [message]
  echo \"message\" | tg-send [options]

OPTIONS:
  -c, --chat ID         Target chat id (default: $TELEGRAM_CHAT_ID)
  -p, --parse-mode M    MarkdownV2 | HTML  (default: plain text)
  -s, --silent          Send without a notification sound
  -f, --file PATH       Send PATH as a document ('-' for stdin); message = caption
      --config PATH     Use this config.env instead of the default
  -h, --help            Show this help

Token resolution: $TELEGRAM_BOT_TOKEN > $TELEGRAM_BOT_TOKEN_FILE > $TELEGRAM_BOT_SOPS_FILE
Chat resolution:  --chat > $TELEGRAM_CHAT_ID";

fn fail(msg: &str, code: i32) -> ! {
    eprintln!("tg-send: {msg}");
    exit(code);
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();

    let mut chat: Option<String> = None;
    let mut parse_mode: Option<String> = None;
    let mut silent = false;
    let mut file: Option<String> = None;
    let mut config: Option<String> = None;
    let mut message_parts: Vec<String> = Vec::new();

    let mut i = 0;
    let next = |i: &mut usize, flag: &str| -> String {
        *i += 1;
        match args.get(*i) {
            Some(v) => v.clone(),
            None => fail(&format!("missing value for {flag}"), 2),
        }
    };
    while i < args.len() {
        match args[i].as_str() {
            "-c" | "--chat" => chat = Some(next(&mut i, "--chat")),
            "-p" | "--parse-mode" => parse_mode = Some(next(&mut i, "--parse-mode")),
            "-s" | "--silent" => silent = true,
            "-f" | "--file" => file = Some(next(&mut i, "--file")),
            "--config" => config = Some(next(&mut i, "--config")),
            "-h" | "--help" => {
                println!("{USAGE}");
                return;
            }
            "--" => {
                message_parts.extend(args[i + 1..].iter().cloned());
                break;
            }
            // first positional: it and everything after form the message/caption
            s if !s.starts_with('-') || s == "-" => {
                message_parts.extend(args[i..].iter().cloned());
                break;
            }
            s => fail(&format!("unknown option: {s}"), 2),
        }
        i += 1;
    }

    let cfg = Config::load(config.as_deref());
    let chat = chat.or_else(|| cfg.get("TELEGRAM_CHAT_ID"));
    let chat = chat.unwrap_or_else(|| fail("no chat id (set TELEGRAM_CHAT_ID or pass --chat)", 2));
    let token = resolve_token(&cfg).unwrap_or_else(|e| fail(&format!("{e}"), 2));
    let tg = Tg::new(token);

    let message = message_parts.join(" ");

    let result = if let Some(f) = file {
        let (bytes, filename) = read_document(&f);
        let caption = if message.is_empty() {
            None
        } else {
            Some(message.as_str())
        };
        tg.send_document(
            &chat,
            &filename,
            &bytes,
            caption,
            parse_mode.as_deref(),
            silent,
        )
    } else {
        let msg = if !message.is_empty() {
            message
        } else if !std::io::stdin().is_terminal() {
            let mut s = String::new();
            if std::io::stdin().read_to_string(&mut s).is_err() {
                fail("failed to read stdin", 2);
            }
            s.trim_end().to_string()
        } else {
            fail(
                "nothing to send (pass a message argument or pipe via stdin)",
                2,
            );
        };
        if msg.is_empty() {
            fail("nothing to send", 2);
        }
        tg.send_message(&chat, &msg, parse_mode.as_deref(), silent)
    };

    if let Err(e) = result {
        fail(&format!("{e}"), 1);
    }
}

fn read_document(f: &str) -> (Vec<u8>, String) {
    if f == "-" {
        let mut b = Vec::new();
        if std::io::stdin().read_to_end(&mut b).is_err() {
            fail("failed to read stdin", 2);
        }
        (b, "stdin.txt".to_string())
    } else {
        let bytes = std::fs::read(f).unwrap_or_else(|_| fail(&format!("no such file: {f}"), 2));
        let name = std::path::Path::new(f)
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("file")
            .to_string();
        (bytes, name)
    }
}
