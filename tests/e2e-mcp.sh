#!/usr/bin/env bash
# Hermetic end-to-end test for tg-mcp's send_file tool, run as a nix flake check.
# tg-mcp and python3 come from PATH (provided by the check derivation).
#
# Runs the real thing: a tg-mcp daemon over a Unix socket against the mock
# Telegram API, driven by a tg-mcp stdio client speaking JSON-RPC — the same
# two-process split an agent uses.
set -uo pipefail

T="$(mktemp -d)"
export MOCK_LOG="$T/log.jsonl"
export MOCK_PORT_FILE="$T/port"
export HOME="$T"
export TG_MCP_SOCK="$T/tg-mcp.sock"
MOCK_PY="${TGB_MOCK:?set TGB_MOCK to mock.py}"
MOCK_PID=""
DAEMON_PID=""

cleanup() {
  [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
}
trap cleanup EXIT

pass=0
fail=0
ok() {
  echo "  PASS: $1"
  pass=$((pass + 1))
}
no() {
  echo "  FAIL: $1"
  fail=$((fail + 1))
}
want() { if grep -qF "$2" "$3"; then ok "$1"; else
  no "$1 (want '$2')"
  cat "$3"
fi; }
absent() { if grep -qF "$2" "$3"; then no "$1 ('$2' present)"; else ok "$1"; fi; }

# One JSON-RPC call through a fresh stdio client; prints the response.
rpc() { # $1 = json request
  printf '%s\n' "$1" | tg-mcp 2>/dev/null
}

python3 "$MOCK_PY" &
MOCK_PID=$!
for _ in $(seq 1 50); do
  [ -s "$MOCK_PORT_FILE" ] && break
  sleep 0.1
done
export TELEGRAM_API_BASE="http://127.0.0.1:$(cat "$MOCK_PORT_FILE")"

mkdir -p "$T/media" "$T/media-secret"
printf 'CHART-BYTES\n' >"$T/media/chart.png"
printf 'LOGDATA\n' >"$T/media/run.log"
printf 'OUTSIDE-SECRET\n' >"$T/secret.txt"
printf 'PREFIX-SIBLING-SECRET\n' >"$T/media-secret/x.txt"

env TELEGRAM_BOT_TOKEN=T TELEGRAM_CHAT_ID=42 tg-mcp daemon >"$T/daemon.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 50); do
  [ -S "$TG_MCP_SOCK" ] && break
  sleep 0.1
done
[ -S "$TG_MCP_SOCK" ] || {
  no "daemon did not create its socket"
  cat "$T/daemon.log"
  echo "RESULT: $pass passed, $((fail + 1)) failed"
  exit 1
}

echo "== tg-mcp: send_file is advertised =="
rpc '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' >"$T/list.json"
want "tools/list includes send_file" '"name":"send_file"' "$T/list.json"
want "path is a required argument" '"path"' "$T/list.json"

echo "== tg-mcp: send_file uploads =="
: >"$MOCK_LOG"
export TG_MCP_MEDIA_ROOT="$T/media"
rpc "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"send_file\",\"arguments\":{\"path\":\"$T/media/run.log\",\"caption\":\"nightly run\"}}}" >"$T/send.json"
want "document uploaded" '"method": "sendDocument"' "$MOCK_LOG"
want "caption carried through" 'nightly run' "$MOCK_LOG"
absent "not an error result" '"isError":true' "$T/send.json"

echo "== tg-mcp: inline sends a photo =="
: >"$MOCK_LOG"
rpc "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"send_file\",\"arguments\":{\"path\":\"$T/media/chart.png\",\"inline\":true}}}" >/dev/null
want "inline uses sendPhoto" '"method": "sendPhoto"' "$MOCK_LOG"
: >"$MOCK_LOG"
rpc "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"send_file\",\"arguments\":{\"path\":\"$T/media/chart.png\"}}}" >/dev/null
want "document is the default even for an image" '"method": "sendDocument"' "$MOCK_LOG"

echo "== tg-mcp: TG_MCP_MEDIA_ROOT confines the path =="
: >"$MOCK_LOG"
rpc "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"send_file\",\"arguments\":{\"path\":\"$T/secret.txt\"}}}" >"$T/esc.json"
want "outside the root is an error" 'outside TG_MCP_MEDIA_ROOT' "$T/esc.json"
absent "nothing uploaded" '"method": "send' "$MOCK_LOG"
absent "contents did not leak to the chat" 'OUTSIDE-SECRET' "$MOCK_LOG"
# A sibling whose name merely starts with the root's must not pass.
: >"$MOCK_LOG"
rpc "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"send_file\",\"arguments\":{\"path\":\"$T/media-secret/x.txt\"}}}" >"$T/pfx.json"
want "prefix-sibling dir is outside the root" 'outside TG_MCP_MEDIA_ROOT' "$T/pfx.json"
absent "prefix-sibling contents did not leak" 'PREFIX-SIBLING-SECRET' "$MOCK_LOG"
# A symlink inside the root pointing out of it must not defeat the check.
ln -sf "$T/secret.txt" "$T/media/link.txt"
: >"$MOCK_LOG"
rpc "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"send_file\",\"arguments\":{\"path\":\"$T/media/link.txt\"}}}" >"$T/lnk.json"
want "symlink out of the root is refused" 'outside TG_MCP_MEDIA_ROOT' "$T/lnk.json"
absent "symlink contents did not leak" 'OUTSIDE-SECRET' "$MOCK_LOG"

echo "== tg-mcp: errors are reported, not silent =="
: >"$MOCK_LOG"
rpc "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"send_file\",\"arguments\":{\"path\":\"$T/media/nope\"}}}" >"$T/miss.json"
want "missing file is an error result" '"isError":true' "$T/miss.json"
want "missing file says so" 'no such file' "$T/miss.json"
rpc '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"send_file","arguments":{}}}' >"$T/nopath.json"
want "missing path is an error" 'path is required' "$T/nopath.json"

echo "== tg-mcp: the daemon bounds an oversized IPC request =="
# The TCP listener is unauthenticated, so an unbounded read_line would let any
# reachable peer stream newline-free bytes until the daemon is OOM-killed.
# Push >80MB with no newline straight at the socket and require the daemon to
# refuse it and stay up.
python3 - "$TG_MCP_SOCK" <<'PY' >"$T/flood.out" 2>&1 || true
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(30)
s.connect(sys.argv[1])
chunk = b"A" * (1 << 20)
sent = 0
try:
    while sent < 90 * (1 << 20):
        s.send(chunk)
        sent += len(chunk)
except Exception as e:
    print("send stopped:", type(e).__name__)
print("sent", sent)
PY
# The daemon must still answer afterwards — that is the real assertion.
: >"$MOCK_LOG"
rpc "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/call\",\"params\":{\"name\":\"send_file\",\"arguments\":{\"path\":\"$T/media/run.log\"}}}" >/dev/null
want "daemon survives an oversized request" '"method": "sendDocument"' "$MOCK_LOG"

echo "== tg-mcp: with no root set, any readable path is allowed =="
: >"$MOCK_LOG"
unset TG_MCP_MEDIA_ROOT
rpc "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"send_file\",\"arguments\":{\"path\":\"$T/secret.txt\"}}}" >/dev/null
want "unrestricted by default" '"method": "sendDocument"' "$MOCK_LOG"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
