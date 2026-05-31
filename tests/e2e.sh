#!/usr/bin/env bash
# Hermetic end-to-end test, run as a nix flake check. Tools (tg-send/tg-bot),
# python3, curl, jq, grep come from PATH (provided by the check derivation).
# Uses a localhost mock Telegram API (loopback is available in the nix sandbox).
set -uo pipefail

T="$(mktemp -d)"
export MOCK_LOG="$T/log.jsonl"
export MOCK_PORT_FILE="$T/port"
export MOCK_FAIL_FILE="$T/fail"
export HOME="$T"   # tg-bot state dir defaults under $HOME
COMMANDS="${TGB_COMMANDS:?set TGB_COMMANDS to the commands dir}"
MOCK_PY="${TGB_MOCK:?set TGB_MOCK to mock.py}"
MOCK_PID=""

# Copy commands to a writable dir and resolve their `#!/usr/bin/env bash`
# shebang to an absolute interpreter — the nix build sandbox has no /usr/bin/env
# (real hosts do). This keeps the test hermetic while exercising the real scripts.
mkdir -p "$T/cmds"; cp "$COMMANDS"/* "$T/cmds"/; chmod -R u+wx "$T/cmds"
bash_path="$(command -v bash)"
for f in "$T/cmds"/*; do sed -i "1s|^#!/usr/bin/env bash|#!$bash_path|" "$f"; done
COMMANDS="$T/cmds"

start_mock() { # $1 = updates file (optional)
  [ -n "$MOCK_PID" ] && { kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; }
  rm -f "$MOCK_PORT_FILE"
  MOCK_UPDATES="${1:-}" python3 "$MOCK_PY" & MOCK_PID=$!
  for _ in $(seq 1 50); do [ -s "$MOCK_PORT_FILE" ] && break; sleep 0.1; done
  export TELEGRAM_API_BASE="http://127.0.0.1:$(cat "$MOCK_PORT_FILE")"
}
trap 'kill $MOCK_PID 2>/dev/null' EXIT

pass=0; fail=0
want()  { if grep -qF "$2" "$3"; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (want '$2')"; cat "$3"; fail=$((fail+1)); fi; }
absent(){ if grep -qF "$2" "$3"; then echo "  FAIL: $1 ('$2' present)"; fail=$((fail+1)); else echo "  PASS: $1"; pass=$((pass+1)); fi; }

# Run the daemon until $2 appears in the log (or timeout), then stop it.
run_bot_until() { # $1=marker  rest=env...; daemon is last
  local marker="$1"; shift
  rm -rf "$T/.local/state/telegram-bot"
  ( "$@" tg-bot ) >/dev/null 2>&1 & local pid=$!
  for _ in $(seq 1 100); do grep -qF "$marker" "$MOCK_LOG" && break; sleep 0.1; done
  sleep 0.3; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
}

rm -f "$MOCK_FAIL_FILE"; : > "$MOCK_LOG"; start_mock

echo "== tg-send: plain / file-token / stdin / document =="
: > "$MOCK_LOG"; env TELEGRAM_BOT_TOKEN=T TELEGRAM_CHAT_ID=42 tg-send "hello world"
want "chat 42" '"chat_id": "42"' "$MOCK_LOG"; want "text" 'hello world' "$MOCK_LOG"
: > "$MOCK_LOG"; echo FILETOKEN > "$T/tok"
env TELEGRAM_BOT_TOKEN_FILE="$T/tok" tg-send --chat 7 "via file"
want "file token chat 7" '"chat_id": "7"' "$MOCK_LOG"
: > "$MOCK_LOG"; echo "piped" | env TELEGRAM_BOT_TOKEN=T tg-send --chat 9
want "stdin" 'piped' "$MOCK_LOG"
: > "$MOCK_LOG"; echo data | env TELEGRAM_BOT_TOKEN=T tg-send --chat 5 --file - cap
want "document" '"method": "sendDocument"' "$MOCK_LOG"

echo "== tg-send: config precedence + error path =="
: > "$MOCK_LOG"; printf 'export TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-100}"\n' > "$T/c.env"
env TELEGRAM_BOT_CONFIG="$T/c.env" TELEGRAM_BOT_TOKEN=T tg-send cfg
want "config default" '"chat_id": "100"' "$MOCK_LOG"
: > "$MOCK_LOG"; env TELEGRAM_BOT_CONFIG="$T/c.env" TELEGRAM_BOT_TOKEN=T TELEGRAM_CHAT_ID=200 tg-send ov
want "env overrides config" '"chat_id": "200"' "$MOCK_LOG"
touch "$MOCK_FAIL_FILE"
if env TELEGRAM_BOT_TOKEN=T TELEGRAM_CHAT_ID=1 tg-send x 2>/dev/null; then
  echo "  FAIL: error path should exit nonzero"; fail=$((fail+1))
else echo "  PASS: error path nonzero exit"; pass=$((pass+1)); fi
rm -f "$MOCK_FAIL_FILE"

echo "== tg-bot: authorized command =="
printf '[{"update_id":1,"message":{"message_id":1,"chat":{"id":42,"type":"private"},"text":"/ping hello"}}]\n' > "$T/u.json"
: > "$MOCK_LOG"; start_mock "$T/u.json"
run_bot_until 'pong hello' env TELEGRAM_BOT_TOKEN=T TELEGRAM_POST_ONLY=0 TELEGRAM_ALLOWED_CHAT_IDS=42 TELEGRAM_COMMANDS_DIR="$COMMANDS"
want "pong hello" 'pong hello' "$MOCK_LOG"

echo "== tg-bot: unauthorized chat =="
printf '[{"update_id":1,"message":{"message_id":1,"chat":{"id":999,"type":"private"},"text":"/ping hi"}}]\n' > "$T/u.json"
: > "$MOCK_LOG"; start_mock "$T/u.json"
run_bot_until 'Not authorized' env TELEGRAM_BOT_TOKEN=T TELEGRAM_POST_ONLY=0 TELEGRAM_ALLOWED_CHAT_IDS=42 TELEGRAM_COMMANDS_DIR="$COMMANDS"
want "rejected" 'Not authorized' "$MOCK_LOG"; absent "command not run" 'pong' "$MOCK_LOG"

echo "== tg-bot: post-only + builtin /id =="
printf '[{"update_id":1,"message":{"message_id":1,"chat":{"id":42,"type":"private"},"text":"/ping x"}}]\n' > "$T/u.json"
: > "$MOCK_LOG"; start_mock "$T/u.json"
run_bot_until 'post-only' env TELEGRAM_BOT_TOKEN=T TELEGRAM_POST_ONLY=1
want "post-only refusal" 'post-only' "$MOCK_LOG"
printf '[{"update_id":1,"message":{"message_id":1,"chat":{"id":42,"type":"private"},"text":"/id"}}]\n' > "$T/u.json"
: > "$MOCK_LOG"; start_mock "$T/u.json"
run_bot_until 'chat id: 42' env TELEGRAM_BOT_TOKEN=T TELEGRAM_POST_ONLY=1
want "/id reply" 'chat id: 42' "$MOCK_LOG"

echo; echo "RESULT: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
