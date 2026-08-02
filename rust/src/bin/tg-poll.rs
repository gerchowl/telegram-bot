// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Lars Gerchow
//! tg-poll — send a Telegram poll and print its poll id, so a project can map
//! incoming poll_answer updates back to what was asked. Drop-in compatible with
//! the bash tg-poll: same flags, env contract and token/chat resolution.

use std::process::exit;
use telegram_bot::{resolve_token, Config, Tg};

const USAGE: &str = "tg-poll — send a Telegram poll; prints the poll id on stdout.

USAGE:
  tg-poll [options] \"Question\" \"Option 1\" \"Option 2\" [...]

OPTIONS:
  -c, --chat ID     Target chat id (default: $TELEGRAM_CHAT_ID)
  -m, --multi       Allow multiple answers
      --anonymous   Anonymous poll (no voter; can't be tracked)
      --config PATH Use this config.env instead of the default
  -h, --help        Show this help

Token/chat resolution matches tg-send. 2–10 options; non-anonymous by default.";

fn fail(msg: &str, code: i32) -> ! {
    eprintln!("tg-poll: {}", telegram_bot::redact(msg)); // never leak the token via an error URL
    exit(code);
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();

    let mut chat: Option<String> = None;
    let mut config: Option<String> = None;
    let mut multi = false;
    let mut anonymous = false;
    let mut positional: Vec<String> = Vec::new();

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
            "-m" | "--multi" => multi = true,
            "--anonymous" => anonymous = true,
            "--config" => config = Some(next(&mut i, "--config")),
            "-h" | "--help" => {
                println!("{USAGE}");
                return;
            }
            "--" => {
                positional.extend(args[i + 1..].iter().cloned());
                break;
            }
            // first positional: it and everything after are question + options
            s if !s.starts_with('-') => {
                positional.extend(args[i..].iter().cloned());
                break;
            }
            s => {
                eprintln!("tg-poll: unknown option: {s}");
                eprintln!("{USAGE}");
                exit(2);
            }
        }
        i += 1;
    }

    let mut positional = positional.into_iter();
    let question = match positional.next() {
        Some(q) if !q.is_empty() => q,
        _ => fail("a question is required", 2),
    };
    let options: Vec<String> = positional.collect();
    if options.len() < 2 {
        fail("at least two options are required", 2);
    }

    let cfg = Config::load(config.as_deref());
    let chat = chat
        .or_else(|| cfg.get("TELEGRAM_CHAT_ID"))
        .unwrap_or_else(|| fail("no chat id (set TELEGRAM_CHAT_ID or pass --chat)", 2));
    let token = resolve_token(&cfg).unwrap_or_else(|e| fail(&format!("{e}"), 2));

    match Tg::new(token).send_poll(&chat, &question, &options, anonymous, multi) {
        Ok(id) => println!("{id}"),
        Err(e) => fail(&format!("{e}"), 1),
    }
}
