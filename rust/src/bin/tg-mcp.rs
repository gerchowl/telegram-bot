//! tg-mcp — a Model Context Protocol server for the telegram-bot, plus the
//! reply-routing daemon it talks to. Two modes in one binary:
//!
//!   * `tg-mcp daemon` — owns the Telegram `getUpdates` long-poll AND a
//!     Unix-socket IPC server. When an agent's `ask` comes in it sends the
//!     message (capturing the `message_id`), registers a waiter, and blocks;
//!     when the user taps an inline button or **cites** (reply-to) the message,
//!     the poll loop routes the answer back to exactly that waiter. One daemon
//!     per host owns the single-consumer poll — per-agent MCP servers are thin
//!     clients (see below).
//!
//!   * `tg-mcp` (default) — an MCP stdio server (newline-delimited JSON-RPC 2.0
//!     on stdin/stdout) exposing two tools, `notify` and `ask`, each of which
//!     just forwards to the daemon over the socket. Claude Code spawns one of
//!     these per agent; they never poll, so they never fight over the update
//!     stream.
//!
//! Config: reuses telegram_bot::Config / resolve_token for the bot token; the
//! target chat is `$TG_CHAT_ID` or config `TELEGRAM_CHAT_ID`. Socket path is
//! `$TG_MCP_SOCK` or `${XDG_RUNTIME_DIR:-~/.config/telegram-bot}/tg-mcp.sock`.

use anyhow::{anyhow, Context, Result};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use telegram_bot::{resolve_token, Config, Tg};

/// An IPC connection — a local Unix socket (agents on the same host) or a TCP
/// stream (remote agents reaching the central daemon over the tailnet). One
/// enum so the request handler and client are transport-agnostic.
enum Ipc {
    Unix(UnixStream),
    Tcp(TcpStream),
}
impl Ipc {
    fn try_clone(&self) -> std::io::Result<Ipc> {
        Ok(match self {
            Ipc::Unix(s) => Ipc::Unix(s.try_clone()?),
            Ipc::Tcp(s) => Ipc::Tcp(s.try_clone()?),
        })
    }
}
impl Read for Ipc {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        match self {
            Ipc::Unix(s) => s.read(buf),
            Ipc::Tcp(s) => s.read(buf),
        }
    }
}
impl Write for Ipc {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        match self {
            Ipc::Unix(s) => s.write(buf),
            Ipc::Tcp(s) => s.write(buf),
        }
    }
    fn flush(&mut self) -> std::io::Result<()> {
        match self {
            Ipc::Unix(s) => s.flush(),
            Ipc::Tcp(s) => s.flush(),
        }
    }
}

/// Correlation token for a pending `ask` — encoded into button `callback_data`
/// and mapped from the sent `message_id` for cited replies.
static NEXT_TOKEN: AtomicU64 = AtomicU64::new(1);
fn next_token() -> u64 {
    NEXT_TOKEN.fetch_add(1, Ordering::Relaxed)
}

fn socket_path() -> String {
    if let Ok(s) = std::env::var("TG_MCP_SOCK") {
        return s;
    }
    let base = std::env::var("XDG_RUNTIME_DIR").ok().unwrap_or_else(|| {
        std::env::var("HOME")
            .map(|h| format!("{h}/.config/telegram-bot"))
            .unwrap_or_else(|_| "/tmp".into())
    });
    format!("{base}/tg-mcp.sock")
}

fn hostname() -> String {
    std::process::Command::new("hostname")
        .arg("-s")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "host".into())
}

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

fn main() {
    let mode = std::env::args().nth(1).unwrap_or_default();
    let r = if mode == "daemon" {
        run_daemon()
    } else {
        run_mcp()
    };
    if let Err(e) = r {
        eprintln!("tg-mcp: {e:#}");
        std::process::exit(1);
    }
}

// ---------------------------------------------------------------------------
// Daemon: poll loop + IPC server + routing registry
// ---------------------------------------------------------------------------

type Waiters = Arc<Mutex<HashMap<u64, mpsc::Sender<String>>>>;
type Msg2Tok = Arc<Mutex<HashMap<i64, u64>>>;
type Opts = Arc<Mutex<HashMap<u64, Vec<String>>>>;
/// tok → (sent message_id, its composed text) — for latching the message once
/// answered (edit in the chosen answer + strip the buttons).
type Meta = Arc<Mutex<HashMap<u64, (i64, String)>>>;

struct Router {
    tg: Arc<Tg>,
    chat: String,
    waiters: Waiters,
    msg2tok: Msg2Tok,
    opts: Opts,
    meta: Meta,
}

fn run_daemon() -> Result<()> {
    let cfg = Config::load(None);
    let token = resolve_token(&cfg)?;
    let chat = std::env::var("TG_CHAT_ID")
        .ok()
        .filter(|s| !s.is_empty())
        .or_else(|| cfg.get("TELEGRAM_CHAT_ID"))
        .context("no chat id — set TG_CHAT_ID or config TELEGRAM_CHAT_ID")?;

    let tg = Arc::new(Tg::new(token));
    tg.delete_webhook(); // long-poll needs the webhook cleared

    let router = Arc::new(Router {
        tg: tg.clone(),
        chat,
        waiters: Arc::new(Mutex::new(HashMap::new())),
        msg2tok: Arc::new(Mutex::new(HashMap::new())),
        opts: Arc::new(Mutex::new(HashMap::new())),
        meta: Arc::new(Mutex::new(HashMap::new())),
    });

    // Local Unix socket — agents on THIS host.
    let sock = socket_path();
    if let Some(dir) = std::path::Path::new(&sock).parent() {
        std::fs::create_dir_all(dir).ok();
    }
    let _ = std::fs::remove_file(&sock);
    let listener = UnixListener::bind(&sock).with_context(|| format!("bind socket {sock}"))?;
    eprintln!("tg-mcp daemon: listening on {sock}");
    {
        let router = router.clone();
        thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let router = router.clone();
                thread::spawn(move || {
                    if let Err(e) = handle_ipc(Ipc::Unix(stream), &router) {
                        eprintln!("tg-mcp daemon: ipc error: {e:#}");
                    }
                });
            }
        });
    }

    // Optional TCP listener — remote agents over the tailnet (central mode).
    // TG_MCP_LISTEN=<addr:port>, e.g. the host's tailnet IP so only the tailnet
    // can reach it. The wire protocol is identical to the Unix socket.
    if let Ok(addr) = std::env::var("TG_MCP_LISTEN") {
        match TcpListener::bind(&addr) {
            Ok(tl) => {
                eprintln!("tg-mcp daemon: TCP listening on {addr}");
                let router = router.clone();
                thread::spawn(move || {
                    for stream in tl.incoming().flatten() {
                        let router = router.clone();
                        thread::spawn(move || {
                            if let Err(e) = handle_ipc(Ipc::Tcp(stream), &router) {
                                eprintln!("tg-mcp daemon: tcp ipc error: {e:#}");
                            }
                        });
                    }
                });
            }
            Err(e) => eprintln!("tg-mcp daemon: TCP bind {addr} failed: {e}"),
        }
    }

    // Poll loop (main thread) — the single Telegram update consumer.
    let mut offset: i64 = 0;
    loop {
        let resp = match tg.get_updates_allowed(offset, 50, r#"["message","callback_query"]"#) {
            Ok(r) => r,
            Err(e) => {
                eprintln!("tg-mcp daemon: poll error: {e}");
                thread::sleep(Duration::from_secs(3));
                continue;
            }
        };
        if let Some(arr) = resp.get("result").and_then(|v| v.as_array()) {
            for upd in arr {
                if let Some(uid) = upd.get("update_id").and_then(Value::as_i64) {
                    offset = uid + 1;
                }
                route_update(upd, &router);
            }
        }
    }
}

/// Deliver an answer to the waiter for `tok` (and drop it from the map).
fn deliver(waiters: &Waiters, tok: u64, val: String) {
    if let Some(tx) = waiters.lock().unwrap().remove(&tok) {
        let _ = tx.send(val);
    }
}

/// Resolve a pending ask: unblock the waiting agent, then "latch" the Telegram
/// message so the choice reads as made (inline buttons have no native pressed
/// state). For a button tap we keep the buttons and check-mark the chosen one;
/// for a free-text (buttonless) ask we append a "✅ <answer>" footer. `meta`
/// and `opts` are read before delivering so this can't race the handler's
/// `cleanup`.
fn resolve(r: &Router, tok: u64, choice: String, chosen_idx: Option<usize>) {
    let m = r.meta.lock().unwrap().get(&tok).cloned();
    let opts = r.opts.lock().unwrap().get(&tok).cloned();
    deliver(&r.waiters, tok, choice.clone());
    match (m, opts, chosen_idx) {
        // Button tap → keep the keyboard, check-mark the chosen option.
        (Some((mid, _)), Some(options), Some(idx)) if !options.is_empty() => {
            let markup = build_keyboard_marked(tok, &options, idx);
            let _ = r.tg.edit_message_reply_markup(&r.chat, mid, &markup);
        }
        // Free-text / no buttons → append a resolved footer.
        (Some((mid, text)), _, _) => {
            let latched = format!("{text}\n\n✅ <b>{}</b>", html_escape(&choice));
            let _ = r.tg.edit_message_text(&r.chat, mid, &latched, Some("HTML"));
        }
        _ => {}
    }
}

fn route_update(upd: &Value, r: &Router) {
    // Inline-button tap: callback_data = "a:{tok}:{idx}".
    if let Some(cq) = upd.get("callback_query") {
        let cqid = cq.get("id").and_then(|v| v.as_str()).unwrap_or("");
        if let Some(rest) = cq
            .get("data")
            .and_then(|v| v.as_str())
            .and_then(|d| d.strip_prefix("a:"))
        {
            if let Some((tok_s, idx_s)) = rest.split_once(':') {
                if let (Ok(tok), Ok(idx)) = (tok_s.parse::<u64>(), idx_s.parse::<usize>()) {
                    let val = r
                        .opts
                        .lock()
                        .unwrap()
                        .get(&tok)
                        .and_then(|o| o.get(idx))
                        .cloned();
                    if let Some(v) = val {
                        let _ = r.tg.answer_callback_query(cqid, Some(&format!("✅ {v}")));
                        resolve(r, tok, v, Some(idx));
                        return;
                    }
                }
            }
        }
        let _ = r.tg.answer_callback_query(cqid, None);
        return;
    }
    // Cited (reply-to) free-text answer: match reply_to_message.message_id.
    if let Some(msg) = upd.get("message") {
        if let Some(rid) = msg
            .pointer("/reply_to_message/message_id")
            .and_then(Value::as_i64)
        {
            let tok = r.msg2tok.lock().unwrap().get(&rid).copied();
            if let Some(tok) = tok {
                let text = msg
                    .get("text")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                resolve(r, tok, text, None);
            }
        }
    }
}

/// One IPC request per connection: a single JSON object line in, one out.
fn handle_ipc(stream: Ipc, r: &Router) -> Result<()> {
    let mut writer = stream.try_clone()?;
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    let req: Value = serde_json::from_str(line.trim()).context("parsing ipc request")?;
    let op = req.get("op").and_then(|v| v.as_str()).unwrap_or("");

    match op {
        "notify" => {
            let text = req.get("text").and_then(|v| v.as_str()).unwrap_or("");
            // "warn" rings; anything else is silent.
            let silent = req.get("level").and_then(|v| v.as_str()) != Some("warn");
            let body = format!("<b>[{}]</b>\n{}", hostname(), html_escape(text));
            match r
                .tg
                .send_message_id(&r.chat, &body, Some("HTML"), silent, None)
            {
                Ok(_) => writeln!(writer, "{}", json!({"ok": true}))?,
                Err(e) => writeln!(writer, "{}", json!({"error": e.to_string()}))?,
            }
        }
        "ask" => {
            let options: Vec<String> = req
                .get("options")
                .and_then(|v| v.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|x| x.as_str().map(String::from))
                        .collect()
                })
                .unwrap_or_default();
            let timeout = req.get("timeout_s").and_then(|v| v.as_u64()).unwrap_or(600);
            let default = req
                .get("default")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();

            let tok = next_token();
            let (tx, rx) = mpsc::channel::<String>();
            let text = compose_ask_text(&req, &options, timeout, &default);
            let markup = if options.is_empty() {
                None
            } else {
                Some(build_keyboard(tok, &options))
            };

            // Register BEFORE send. (Human reply latency >> this, so no race —
            // but keeping the window tiny is cheap.)
            r.waiters.lock().unwrap().insert(tok, tx);
            if !options.is_empty() {
                r.opts.lock().unwrap().insert(tok, options.clone());
            }

            let mid =
                match r
                    .tg
                    .send_message_id(&r.chat, &text, Some("HTML"), false, markup.as_deref())
                {
                    Ok(m) => m,
                    Err(e) => {
                        cleanup(r, tok);
                        writeln!(writer, "{}", json!({"error": e.to_string()}))?;
                        return Ok(());
                    }
                };
            r.msg2tok.lock().unwrap().insert(mid, tok);
            r.meta.lock().unwrap().insert(tok, (mid, text.clone()));

            match rx.recv_timeout(Duration::from_secs(timeout)) {
                Ok(ans) => {
                    cleanup(r, tok);
                    writeln!(writer, "{}", json!({"answer": ans, "via": "user"}))?;
                }
                Err(RecvTimeoutError::Timeout) => {
                    cleanup(r, tok);
                    let mins = timeout / 60;
                    let note = format!(
                        "⏳ no reply in {mins}m → proceeded with <b>{}</b>",
                        html_escape(&default)
                    );
                    let _ =
                        r.tg.send_message_id(&r.chat, &note, Some("HTML"), true, None);
                    writeln!(writer, "{}", json!({"answer": default, "via": "timeout"}))?;
                }
                Err(RecvTimeoutError::Disconnected) => {
                    cleanup(r, tok);
                    writeln!(writer, "{}", json!({"answer": default, "via": "error"}))?;
                }
            }
        }
        other => writeln!(
            writer,
            "{}",
            json!({"error": format!("unknown op {other}")})
        )?,
    }
    Ok(())
}

fn cleanup(r: &Router, tok: u64) {
    r.waiters.lock().unwrap().remove(&tok);
    r.opts.lock().unwrap().remove(&tok);
    r.meta.lock().unwrap().remove(&tok);
    r.msg2tok.lock().unwrap().retain(|_, v| *v != tok);
}

fn compose_ask_text(req: &Value, options: &[String], timeout: u64, default: &str) -> String {
    let label = req.get("label").and_then(|v| v.as_str()).unwrap_or("");
    let question = req.get("question").and_then(|v| v.as_str()).unwrap_or("");
    let ident = if label.is_empty() {
        hostname()
    } else {
        format!("{label} · {}", hostname())
    };
    let mut s = format!(
        "<b>[{}]</b>\n{}",
        html_escape(&ident),
        html_escape(question)
    );
    if let Some(rec) = req.get("recommendation").and_then(|v| v.as_str()) {
        if !rec.is_empty() {
            s.push_str(&format!("\n\n<i>recommend:</i> {}", html_escape(rec)));
        }
    }
    if options.is_empty() {
        s.push_str("\n\n<i>reply to this message to answer.</i>");
    }
    if !default.is_empty() {
        let mins = timeout / 60;
        s.push_str(&format!(
            "\n<i>default in {mins}m:</i> {}",
            html_escape(default)
        ));
    }
    s
}

fn build_keyboard(tok: u64, options: &[String]) -> String {
    let rows: Vec<Value> = options
        .iter()
        .enumerate()
        .map(|(i, o)| json!([{"text": o, "callback_data": format!("a:{tok}:{i}")}]))
        .collect();
    json!({ "inline_keyboard": rows }).to_string()
}

/// Same keyboard, but the chosen option gets a trailing ✅ — the "latch".
fn build_keyboard_marked(tok: u64, options: &[String], chosen: usize) -> String {
    let rows: Vec<Value> = options
        .iter()
        .enumerate()
        .map(|(i, o)| {
            let label = if i == chosen {
                format!("{o} ✅")
            } else {
                o.clone()
            };
            json!([{"text": label, "callback_data": format!("a:{tok}:{i}")}])
        })
        .collect();
    json!({ "inline_keyboard": rows }).to_string()
}

// ---------------------------------------------------------------------------
// MCP stdio server (thin client to the daemon)
// ---------------------------------------------------------------------------

fn run_mcp() -> Result<()> {
    let stdin = std::io::stdin();
    let mut out = std::io::stdout();
    let mut reader = stdin.lock();
    let mut line = String::new();
    loop {
        line.clear();
        if reader.read_line(&mut line)? == 0 {
            break; // stdin closed
        }
        let t = line.trim();
        if t.is_empty() {
            continue;
        }
        let req: Value = match serde_json::from_str(t) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let id = req.get("id").cloned();
        let method = req.get("method").and_then(|v| v.as_str()).unwrap_or("");
        let resp: Option<Value> = match method {
            "initialize" => Some(json!({
                "jsonrpc": "2.0", "id": id,
                "result": {
                    "protocolVersion": req.pointer("/params/protocolVersion").cloned().unwrap_or(json!("2024-11-05")),
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "tg-mcp", "version": env!("CARGO_PKG_VERSION")}
                }
            })),
            "tools/list" => {
                Some(json!({"jsonrpc": "2.0", "id": id, "result": {"tools": tools_spec()}}))
            }
            "tools/call" => Some(handle_tool_call(id, req.get("params"))),
            "ping" => Some(json!({"jsonrpc": "2.0", "id": id, "result": {}})),
            // notifications (no id) — no response
            _ if id.is_none() => None,
            _ => Some(
                json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "method not found"}}),
            ),
        };
        if let Some(r) = resp {
            writeln!(out, "{r}")?;
            out.flush()?;
        }
    }
    Ok(())
}

fn ipc_call(req: Value) -> Result<Value> {
    // TG_MCP_REMOTE=<host:port> → talk to the central daemon over the tailnet;
    // otherwise the local Unix socket.
    let stream = if let Ok(remote) = std::env::var("TG_MCP_REMOTE") {
        Ipc::Tcp(
            TcpStream::connect(&remote)
                .with_context(|| format!("connect tg-mcp daemon at {remote}"))?,
        )
    } else {
        let sock = socket_path();
        Ipc::Unix(
            UnixStream::connect(&sock)
                .with_context(|| format!("connect {sock} — is the tg-mcp daemon running?"))?,
        )
    };
    let mut writer = stream.try_clone()?;
    writeln!(writer, "{req}")?;
    writer.flush()?;
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line)?; // blocks for the duration of an `ask`
    serde_json::from_str(line.trim()).context("parsing ipc response")
}

fn handle_tool_call(id: Option<Value>, params: Option<&Value>) -> Value {
    let name = params
        .and_then(|p| p.get("name"))
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let args = params
        .and_then(|p| p.get("arguments"))
        .cloned()
        .unwrap_or_else(|| json!({}));

    let result: Result<String> = match name {
        "notify" => ipc_call(json!({
            "op": "notify",
            "text": args.get("text").and_then(|v| v.as_str()).unwrap_or(""),
            "level": args.get("level").and_then(|v| v.as_str()).unwrap_or("info"),
        }))
        .map(|_| "sent".to_string()),
        "ask" => {
            let mut req = json!({"op": "ask"});
            for k in [
                "question",
                "options",
                "recommendation",
                "default",
                "timeout_s",
            ] {
                if let Some(v) = args.get(k) {
                    req[k] = v.clone();
                }
            }
            req["label"] = json!(std::env::var("TG_MCP_LABEL").unwrap_or_default());
            ipc_call(req).map(|v| {
                let ans = v
                    .get("answer")
                    .and_then(|a| a.as_str())
                    .unwrap_or("")
                    .to_string();
                match v.get("via").and_then(|x| x.as_str()) {
                    Some("timeout") => format!("{ans}  [no reply — used default]"),
                    _ => ans,
                }
            })
        }
        other => Err(anyhow!("unknown tool {other}")),
    };

    match result {
        Ok(text) => {
            json!({"jsonrpc": "2.0", "id": id, "result": {"content": [{"type": "text", "text": text}]}})
        }
        Err(e) => json!({"jsonrpc": "2.0", "id": id, "result": {
            "content": [{"type": "text", "text": format!("tg-mcp error: {e:#}")}], "isError": true
        }}),
    }
}

fn tools_spec() -> Value {
    json!([
        {
            "name": "notify",
            "description": "Send the user a one-way status update via Telegram. Use for milestones, completions, and non-blocking FYIs — NEVER for anything you need an answer to (use `ask`). Does not block. Keep it to one line; the user is often on a phone. Batch related updates instead of firing many.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "text": {"type": "string", "description": "One-line status update."},
                    "level": {"type": "string", "enum": ["info", "warn"], "description": "info = silent delivery (default); warn = rings."}
                },
                "required": ["text"]
            }
        },
        {
            "name": "ask",
            "description": "Ask the user a question via Telegram and BLOCK until they answer or `timeout_s` elapses. Interrupting a human is EXPENSIVE — call this ONLY for a genuine, stakes-bearing decision you should not make yourself (irreversible/destructive actions, real ambiguity with real cost, a fork where either choice has meaningful downside). For everything else, pick the sensible default, log why, and PROCEED — do not ask.\n\nEvery ask MUST be answerable from a phone in seconds: state the decision in ONE line; give discrete `options` when the choice is closed (they render as one-tap buttons); give a `recommendation` and why; and set `default` — the action taken if no reply before `timeout_s`, chosen so silence is ALWAYS safe (abort for irreversible/destructive actions; proceed-with-recommended for low-risk forks).\n\nReturns the user's choice (button value or free text); if it comes back with '[no reply — used default]', the user was silent. If a free-text reply is ambiguous, ask AGAIN with a tighter question rather than guessing.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "question": {"type": "string", "description": "The decision, in one line, with just enough context to answer blind."},
                    "options": {"type": "array", "items": {"type": "string"}, "description": "Closed set of choices → rendered as one-tap buttons. Omit for a free-text answer (user cites the message to reply)."},
                    "recommendation": {"type": "string", "description": "Your recommended choice and the one-line why."},
                    "default": {"type": "string", "description": "REQUIRED. The action taken on timeout; must be safe when the user stays silent."},
                    "timeout_s": {"type": "integer", "description": "Seconds to wait before taking `default` (default 600)."}
                },
                "required": ["question", "default"]
            }
        }
    ])
}
