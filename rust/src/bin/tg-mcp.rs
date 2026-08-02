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
//!     on stdin/stdout) exposing `notify`, `send_file` and `ask`, each of which
//!     just forwards to the daemon over the socket. Claude Code spawns one of
//!     these per agent; they never poll, so they never fight over the update
//!     stream.
//!
//! Config: reuses telegram_bot::Config / resolve_token for the bot token; the
//! target chat is `$TG_CHAT_ID` or config `TELEGRAM_CHAT_ID`. Socket path is
//! `$TG_MCP_SOCK` or `${XDG_RUNTIME_DIR:-~/.config/telegram-bot}/tg-mcp.sock`.

use anyhow::{anyhow, bail, Context, Result};
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

    fn is_tcp(&self) -> bool {
        matches!(self, Ipc::Tcp(_))
    }

    /// Where this request came from, as the DAEMON sees it. Derived from the
    /// socket, never from the request body, so an agent cannot claim to be
    /// somewhere it isn't — which is the whole point of showing it to a human.
    fn peer_label(&self) -> String {
        match self {
            Ipc::Unix(_) => "local".to_string(),
            Ipc::Tcp(s) => s
                .peer_addr()
                .map(|a| a.ip().to_string())
                .unwrap_or_else(|_| "remote".to_string()),
        }
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

/// The shared secret required on every TCP request, if configured.
fn tcp_token() -> Option<String> {
    std::env::var("TG_MCP_TOKEN").ok().filter(|s| !s.is_empty())
}

/// Compare two secrets without leaking their contents through timing. Length
/// is not secret here (it's a config value), but the bytes are.
fn secret_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for i in 0..a.len() {
        diff |= a[i] ^ b[i];
    }
    // black_box so the optimiser can't reason about the accumulator and turn
    // this back into an early-exit compare.
    std::hint::black_box(diff) == 0
}

/// Resolve once and return the address to bind, having checked EVERY candidate.
///
/// Validating one address and then handing the original string to
/// `TcpListener::bind` would let bind re-resolve and land somewhere else: DNS
/// order isn't stable, and bind walks the list on failure. So a name resolving
/// to both a tailnet and a LAN address could validate on the former and bind
/// the latter. Every candidate must pass, and the caller binds the concrete
/// SocketAddr this returns.
fn resolve_bind_addr(addr: &str) -> Result<std::net::SocketAddr, String> {
    use std::net::ToSocketAddrs;
    let addrs: Vec<_> = addr
        .to_socket_addrs()
        .map_err(|e| format!("cannot parse as <addr:port>: {e}"))?
        .collect();
    let first = *addrs
        .first()
        .ok_or_else(|| "resolved to no address".to_string())?;
    for sa in &addrs {
        check_bind_addr(*sa)?;
    }
    Ok(first)
}

/// Reject a listen address that isn't a Tailscale address or loopback.
///
/// A BIND sanity check, not authorization — being in the CGNAT range proves the
/// peer is on some tailnet, not that it is yours; the shared secret does the
/// authorizing. What this stops is the one catastrophic misconfig: `0.0.0.0`,
/// `::` or a LAN address puts a daemon that can message you as you on an
/// interface anyone can reach.
fn check_bind_addr(sa: std::net::SocketAddr) -> Result<(), String> {
    use std::net::IpAddr;
    match sa.ip() {
        IpAddr::V4(v4) if v4.is_loopback() => Ok(()),
        // Tailscale hands out 100.64.0.0/10 (CGNAT, RFC 6598).
        IpAddr::V4(v4) if v4.octets()[0] == 100 && (64..128).contains(&v4.octets()[1]) => Ok(()),
        IpAddr::V4(v4) if v4.is_unspecified() => Err(format!(
            "{v4} is a wildcard — this would accept connections on every interface"
        )),
        IpAddr::V6(v6) if v6.is_loopback() => Ok(()),
        IpAddr::V6(v6) if v6.is_unspecified() => Err(format!(
            "{v6} is a wildcard — this would accept connections on every interface"
        )),
        // Tailscale's IPv6 range is fd7a:115c:a1e0::/48.
        IpAddr::V6(v6) if v6.segments()[..3] == [0xfd7a, 0x115c, 0xa1e0] => Ok(()),
        ip => Err(format!(
            "{ip} is neither a Tailscale address (100.64.0.0/10, fd7a:115c:a1e0::/48) nor loopback"
        )),
    }
}

/// Asks that must not be answerable with one distracted tap. An agent that
/// ingested a poisoned README can phrase a plausible `ask`; the authenticated
/// client IS the attacker in that case, so no amount of transport auth helps.
/// For this phrasing class we drop the buttons and require a typed reply.
///
/// Scans EVERY string the human will see, not just the question. The button
/// label is what people actually read, so checking only the question missed the
/// obvious evasion: `question: "Proceed?"` with `options: ["Force push to
/// main", "Cancel"]`.
///
/// Be clear about what this is: a speed bump for phrasings that read as
/// destructive, not a boundary. It is a denylist, so a determined injection can
/// word its way around it ("purge the customer records"). It is here to catch
/// the careless and the obvious, and it deliberately errs toward friction — a
/// benign question mentioning production loses its buttons, which costs one
/// typed reply. The real control is that irreversible actions should not be
/// reachable by a single tap at all.
fn is_destructive(parts: &[&str]) -> bool {
    let q = parts.join(" \u{1}").to_lowercase();
    [
        "--force",
        "-f ",
        "force push",
        "force-push",
        "rm -rf",
        "drop table",
        "drop database",
        "truncate",
        "delete from",
        "delete all",
        "overwrite",
        "purge",
        "deploy to prod",
        "deploy prod",
        "to prod",
        "production",
        "reset --hard",
        "push to main",
        "push to master",
        "revoke",
        "rotate the",
        "wipe",
        "destroy",
        "format /",
        "shutdown",
    ]
    .iter()
    .any(|needle| q.contains(needle))
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
    // TG_MCP_LISTEN=<addr:port>, bound to the host's tailnet IP.
    if let Ok(addr) = std::env::var("TG_MCP_LISTEN") {
        // Two gates before this port opens, both fail-closed. A daemon that can
        // send Telegram messages as you must never end up on a LAN or public
        // interface, and it must never accept an unidentified peer.
        let bind_to = match resolve_bind_addr(&addr) {
            Ok(sa) => sa,
            Err(why) => {
                eprintln!(
                    "tg-mcp daemon: REFUSING to listen on {addr}: {why}\n  \
                     Bind to this host's Tailscale address. Unix socket still served."
                );
                return run_poll_loop(&router);
            }
        };
        if tcp_token().is_none() {
            eprintln!(
                "tg-mcp daemon: REFUSING to listen on {addr}: TG_MCP_LISTEN is set but \
                 TG_MCP_TOKEN is not.\n  \
                 The TCP transport has no other authentication — set a shared secret on \
                 the daemon and every remote client. Unix socket still served."
            );
            return run_poll_loop(&router);
        }
        match TcpListener::bind(bind_to) {
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

    run_poll_loop(&router)
}

/// The single Telegram update consumer. Runs on the main thread and never
/// returns; factored out so the daemon can still serve the Unix socket after
/// refusing to open an unsafe TCP listener.
fn run_poll_loop(router: &Arc<Router>) -> Result<()> {
    let tg = &router.tg;
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
                route_update(upd, router);
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

/// Largest IPC request the daemon will buffer. A 50 MB file is ~67 MB of
/// base64 plus JSON overhead, so this leaves headroom while staying bounded.
const MAX_IPC: u64 = 80_000_000;

/// One IPC request per connection: a single JSON object line in, one out.
fn handle_ipc(stream: Ipc, r: &Router) -> Result<()> {
    let mut writer = stream.try_clone()?;
    let is_tcp = stream.is_tcp();
    let peer = stream.peer_label();
    // Bound the read. read_line grows until a newline or EOF, and the TCP
    // listener is unauthenticated — any tailnet peer could otherwise stream
    // newline-free bytes until the daemon is OOM-killed. Pre-existing, but
    // send_file's base64 payloads make bulk traffic the expected shape here.
    let mut reader = BufReader::new(Read::take(stream, MAX_IPC));
    let mut line = String::new();
    let n = reader.read_line(&mut line)?;
    if n as u64 >= MAX_IPC && !line.ends_with('\n') {
        let _ = writeln!(writer, "{}", json!({"error": "request too large"}));
        bail!("ipc request exceeded {MAX_IPC} bytes");
    }
    let req: Value = serde_json::from_str(line.trim()).context("parsing ipc request")?;

    // Remote requests must carry the shared secret. The Unix socket is exempt:
    // filesystem permissions already bound it to the local user, and adding a
    // secret there would only put one more copy of it on disk.
    //
    // Honest about what this is: the token and tailnet membership share a
    // compromise domain, so this does NOT defend against a compromised fleet
    // node. It closes the narrower case of a node admitted to the tailnet later,
    // or an ACL that is wrong — Tailscale falls back to allow-all on an empty
    // policy file. Defence in depth, not a trust boundary.
    if is_tcp {
        let want = match tcp_token() {
            Some(t) => t,
            // Unreachable: the listener refuses to open without a token.
            None => {
                let _ = writeln!(
                    writer,
                    "{}",
                    json!({"error": "server has no token configured"})
                );
                bail!("tcp request with no server token configured");
            }
        };
        let got = req.get("token").and_then(|v| v.as_str()).unwrap_or("");
        if !secret_eq(got, &want) {
            eprintln!("tg-mcp daemon: REJECTED unauthenticated request from {peer}");
            // Reply and return cleanly rather than bailing: erroring out drops
            // the stream immediately, and the client can lose the response to
            // an abortive close before it reads it. The peer should learn it
            // was rejected, not just see the connection vanish.
            writeln!(writer, "{}", json!({"error": "unauthorized"}))?;
            writer.flush()?;
            return Ok(());
        }
    }

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
        // The client reads and encodes the file: in central mode the daemon is
        // on another host across the tailnet, where a client-side path means
        // nothing. So bytes travel, not paths.
        "send_file" => {
            let name = req.get("name").and_then(|v| v.as_str()).unwrap_or("file");
            let caption = req.get("caption").and_then(|v| v.as_str()).unwrap_or("");
            let silent = req.get("silent").and_then(|v| v.as_bool()).unwrap_or(false);
            let inline = req.get("inline").and_then(|v| v.as_bool()).unwrap_or(false);
            let body = format!("<b>[{}]</b>{}", hostname(), {
                if caption.is_empty() {
                    String::new()
                } else {
                    format!("\n{}", html_escape(caption))
                }
            });
            let decoded = req
                .get("data_b64")
                .and_then(|v| v.as_str())
                .ok_or_else(|| anyhow!("send_file: missing data_b64"))
                .and_then(|d| {
                    base64::Engine::decode(&base64::engine::general_purpose::STANDARD, d)
                        .context("decoding data_b64")
                });
            match decoded {
                Ok(bytes) => {
                    let res = if inline {
                        r.tg.send_photo(&r.chat, name, &bytes, Some(&body), Some("HTML"), silent)
                    } else {
                        r.tg.send_document(&r.chat, name, &bytes, Some(&body), Some("HTML"), silent)
                    };
                    match res {
                        Ok(()) => writeln!(writer, "{}", json!({"ok": true}))?,
                        Err(e) => writeln!(writer, "{}", json!({"error": e.to_string()}))?,
                    }
                }
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

            // A question phrased around an irreversible action must not be
            // answerable by one distracted tap on a lockscreen: the button
            // label is what people actually read, and a prompt-injected agent
            // on an authorised host can choose both. Strip the buttons and make
            // the human type — the friction IS the mitigation.
            let question = req.get("question").and_then(|v| v.as_str()).unwrap_or("");
            let recommendation = req
                .get("recommendation")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let mut scan: Vec<&str> = vec![question, recommendation, default.as_str()];
            scan.extend(options.iter().map(String::as_str));
            let destructive = is_destructive(&scan);
            let options: Vec<String> = if destructive { Vec::new() } else { options };

            let tok = next_token();
            let (tx, rx) = mpsc::channel::<String>();
            let mut text = compose_ask_text(&req, &options, timeout, &default, &peer);
            if destructive {
                text.push_str(
                    "\n\n\u{26a0}\u{fe0f} <b>irreversible-sounding</b> — buttons withheld.                      Reply to this message with your answer to confirm.",
                );
            }
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
    // Flush before the stream drops. Over TCP an abortive close can discard a
    // response the peer never got to read — the request has already had its
    // effect by then, so the client would report a failure that did happen.
    writer.flush()?;
    Ok(())
}

fn cleanup(r: &Router, tok: u64) {
    r.waiters.lock().unwrap().remove(&tok);
    r.opts.lock().unwrap().remove(&tok);
    r.meta.lock().unwrap().remove(&tok);
    r.msg2tok.lock().unwrap().retain(|_, v| *v != tok);
}

fn compose_ask_text(
    req: &Value,
    options: &[String],
    timeout: u64,
    default: &str,
    peer: &str,
) -> String {
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
    // `label` above is agent-supplied and can claim anything. This line is the
    // daemon's own view of the connection, so it is the only part of the
    // message that cannot lie about where the request came from.
    s.push_str(&format!("\n<i>via</i> <code>{}</code>", html_escape(peer)));
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

fn ipc_call(mut req: Value) -> Result<Value> {
    // TG_MCP_REMOTE=<host:port> → talk to the central daemon over the tailnet;
    // otherwise the local Unix socket.
    let stream = if let Ok(remote) = std::env::var("TG_MCP_REMOTE") {
        // Remote requests carry the shared secret; the daemon rejects them
        // without it. Local ones don't — the socket's permissions are the
        // control there, and a second copy of the secret would only be one
        // more thing to leak.
        match tcp_token() {
            Some(t) => req["token"] = json!(t),
            None => {
                bail!("TG_MCP_REMOTE is set but TG_MCP_TOKEN is not — the daemon will reject this")
            }
        }
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
        "send_file" => {
            let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
            read_for_upload(path).and_then(|(bytes, name)| {
                let mut req = json!({
                    "op": "send_file",
                    "name": name,
                    "data_b64": base64::Engine::encode(
                        &base64::engine::general_purpose::STANDARD, &bytes),
                });
                for k in ["caption", "silent", "inline"] {
                    if let Some(v) = args.get(k) {
                        req[k] = v.clone();
                    }
                }
                ipc_call(req).map(|_| format!("sent {name} ({} bytes)", bytes.len()))
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

/// Telegram's bot-API upload cap. Enforced client-side, before base64 inflates
/// the payload by a third on its way through the IPC socket.
const MAX_UPLOAD: u64 = 50_000_000;

/// Read a file the agent asked to send, confined to `TG_MCP_MEDIA_ROOT`.
///
/// Unset means unrestricted, which is the right default here: unlike the bot's
/// command runner, this daemon acts for an agent that already reads the
/// filesystem and could paste a file's contents into `notify`. The root is for
/// operators who want the daemon's reach bounded anyway — set it and a stray
/// or manipulated path can't turn one Telegram chat into a file-exfiltration
/// channel. Resolution goes through canonicalize, so symlinks out are rejected.
fn read_for_upload(path: &str) -> Result<(Vec<u8>, String)> {
    if path.is_empty() {
        bail!("send_file: path is required");
    }
    let real = std::fs::canonicalize(path).with_context(|| format!("no such file: {path}"))?;
    if let Ok(root) = std::env::var("TG_MCP_MEDIA_ROOT") {
        if !root.is_empty() {
            let root = std::fs::canonicalize(&root)
                .with_context(|| format!("TG_MCP_MEDIA_ROOT '{root}' does not exist"))?;
            if !real.starts_with(&root) {
                bail!("path is outside TG_MCP_MEDIA_ROOT");
            }
        }
    }
    // Reject a non-regular file before opening: opening a FIFO blocks until a
    // writer appears, which would hang the agent's tool call.
    if !std::fs::symlink_metadata(&real).context("stat")?.is_file() {
        bail!("not a regular file");
    }
    // Then check size against the OPEN handle, so a swap between the check and
    // the read can't slip a different (larger) file through.
    let f = std::fs::File::open(&real).context("open")?;
    let meta = f.metadata().context("stat")?;
    if !meta.is_file() {
        bail!("not a regular file");
    }
    if meta.len() > MAX_UPLOAD {
        bail!(
            "file is {} MB, over Telegram's {} MB bot limit",
            meta.len() / 1_000_000,
            MAX_UPLOAD / 1_000_000
        );
    }
    let mut bytes = Vec::with_capacity(meta.len() as usize);
    Read::take(f, MAX_UPLOAD)
        .read_to_end(&mut bytes)
        .context("read")?;
    let name = real
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("file")
        .to_string();
    Ok((bytes, name))
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
            "name": "send_file",
            "description": "Send the user a FILE via Telegram — a chart, screenshot, log, PDF, diff. One-way like `notify`; does not block and returns no answer. Use it when the artefact IS the message: something the user needs to look at rather than read as text. Do NOT use it to dump output that would read fine as a `notify` line, and do NOT send anything you have not been asked for — every file is a phone notification. Prefer one file with a clear caption over several. The caption is the message body; keep it to one line.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "Absolute path to the file to send. Read on the machine running this tool, so it must be local to the agent. Max 50 MB. If TG_MCP_MEDIA_ROOT is set the path must resolve inside it, otherwise the call is refused."},
                    "caption": {"type": "string", "description": "One-line description of what the file is. Shown with the file."},
                    "inline": {"type": "boolean", "description": "Render as a photo instead of a file attachment. Only for images, and only when a quick look matters more than fidelity — Telegram re-encodes and downscales. Default false, which preserves the bytes exactly.", "default": false},
                    "silent": {"type": "boolean", "description": "Send without a notification sound.", "default": false}
                },
                "required": ["path"]
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
