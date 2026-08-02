#!/usr/bin/env bash
# Hermetic end-to-end test, run as a nix flake check. Tools (tg-send/tg-bot),
# python3, curl, jq, grep come from PATH (provided by the check derivation).
# Uses a localhost mock Telegram API (loopback is available in the nix sandbox).
set -uo pipefail

T="$(mktemp -d)"
export MOCK_LOG="$T/log.jsonl"
export MOCK_PORT_FILE="$T/port"
export MOCK_FAIL_FILE="$T/fail"
export HOME="$T" # tg-bot state dir defaults under $HOME
COMMANDS="${TGB_COMMANDS:?set TGB_COMMANDS to the commands dir}"
MOCK_PY="${TGB_MOCK:?set TGB_MOCK to mock.py}"
MOCK_PID=""

# Copy commands to a writable dir and resolve their `#!/usr/bin/env bash`
# shebang to an absolute interpreter — the nix build sandbox has no /usr/bin/env
# (real hosts do). This keeps the test hermetic while exercising the real scripts.
mkdir -p "$T/cmds"
cp "$COMMANDS"/* "$T/cmds"/
chmod -R u+wx "$T/cmds"
bash_path="$(command -v bash)"
for f in "$T/cmds"/*; do sed -i "1s|^#!/usr/bin/env bash|#!$bash_path|" "$f"; done
COMMANDS="$T/cmds"

start_mock() { # $1 = updates file (optional)
  [ -n "$MOCK_PID" ] && {
    kill "$MOCK_PID" 2>/dev/null
    wait "$MOCK_PID" 2>/dev/null
  }
  rm -f "$MOCK_PORT_FILE"
  MOCK_UPDATES="${1:-}" python3 "$MOCK_PY" &
  MOCK_PID=$!
  for _ in $(seq 1 50); do
    [ -s "$MOCK_PORT_FILE" ] && break
    sleep 0.1
  done
  export TELEGRAM_API_BASE="http://127.0.0.1:$(cat "$MOCK_PORT_FILE")"
}
trap 'kill $MOCK_PID 2>/dev/null' EXIT

pass=0
fail=0
want() { if grep -qF "$2" "$3"; then
  echo "  PASS: $1"
  pass=$((pass + 1))
else
  echo "  FAIL: $1 (want '$2')"
  cat "$3"
  fail=$((fail + 1))
fi; }
absent() { if grep -qF "$2" "$3"; then
  echo "  FAIL: $1 ('$2' present)"
  fail=$((fail + 1))
else
  echo "  PASS: $1"
  pass=$((pass + 1))
fi; }

# Run the daemon until $2 appears in the log (or timeout), then stop it.
run_bot_until() { # $1=marker  rest=env...; daemon is last
  local marker="$1"
  shift
  rm -rf "$T/.local/state/telegram-bot"
  ("$@" tg-bot) >/dev/null 2>&1 &
  local pid=$!
  for _ in $(seq 1 100); do
    grep -qF "$marker" "$MOCK_LOG" && break
    sleep 0.1
  done
  sleep 0.3
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
}

rm -f "$MOCK_FAIL_FILE"
: >"$MOCK_LOG"
start_mock

echo "== tg-send: plain / file-token / stdin / document =="
: >"$MOCK_LOG"
env TELEGRAM_BOT_TOKEN=T TELEGRAM_CHAT_ID=42 tg-send "hello world"
want "chat 42" '"chat_id": "42"' "$MOCK_LOG"
want "text" 'hello world' "$MOCK_LOG"
: >"$MOCK_LOG"
echo FILETOKEN >"$T/tok"
env TELEGRAM_BOT_TOKEN_FILE="$T/tok" tg-send --chat 7 "via file"
want "file token chat 7" '"chat_id": "7"' "$MOCK_LOG"
: >"$MOCK_LOG"
echo "piped" | env TELEGRAM_BOT_TOKEN=T tg-send --chat 9
want "stdin" 'piped' "$MOCK_LOG"

echo "== tg-send: a real TLS backend is wired (https://, not just the mock) =="
# Hit a closed local HTTPS port: the client must ATTEMPT the handshake (→ a connect/network
# error) and must NOT bail for lack of a TLS backend. curl/rustls/native-tls all attempt it; a
# binary with no TLS backend errors *before* connecting ("no TLS backend"/"Unknown Scheme").
# Loopback only, so it runs in the network-less nix sandbox. Regression guard for #26.
env TELEGRAM_BOT_TOKEN=T TELEGRAM_API_BASE=https://127.0.0.1:9 tg-send --chat 1 "probe" \
  >"$T/tls.out" 2>&1 || true
absent "TLS backend present (no missing-backend error)" 'no TLS backend' "$T/tls.out"
absent "https scheme is supported" 'Unknown Scheme' "$T/tls.out"
: >"$MOCK_LOG"
echo data | env TELEGRAM_BOT_TOKEN=T tg-send --chat 5 --file - cap
want "document" '"method": "sendDocument"' "$MOCK_LOG"

echo "== tg-send: config precedence + error path =="
: >"$MOCK_LOG"
printf 'export TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-100}"\n' >"$T/c.env"
env TELEGRAM_BOT_CONFIG="$T/c.env" TELEGRAM_BOT_TOKEN=T tg-send cfg
want "config default" '"chat_id": "100"' "$MOCK_LOG"
: >"$MOCK_LOG"
env TELEGRAM_BOT_CONFIG="$T/c.env" TELEGRAM_BOT_TOKEN=T TELEGRAM_CHAT_ID=200 tg-send ov
want "env overrides config" '"chat_id": "200"' "$MOCK_LOG"
touch "$MOCK_FAIL_FILE"
if env TELEGRAM_BOT_TOKEN=T TELEGRAM_CHAT_ID=1 tg-send x 2>/dev/null; then
  echo "  FAIL: error path should exit nonzero"
  fail=$((fail + 1))
else
  echo "  PASS: error path nonzero exit"
  pass=$((pass + 1))
fi
rm -f "$MOCK_FAIL_FILE"

echo "== tg-poll: poll id on stdout, options json, flag defaults =="
: >"$MOCK_LOG"
env TELEGRAM_BOT_TOKEN=T TELEGRAM_CHAT_ID=42 tg-poll "Deploy?" "yes" "no" >"$T/poll.out"
want "poll id printed on stdout" 'mockpoll123' "$T/poll.out"
want "poll chat" '"chat_id": "42"' "$MOCK_LOG"
want "poll question" '"question": "Deploy?"' "$MOCK_LOG"
want "options encoded as a json array" '[\"yes\",\"no\"]' "$MOCK_LOG"
want "non-anonymous by default" '"is_anonymous": "false"' "$MOCK_LOG"
want "single-answer by default" '"allows_multiple_answers": "false"' "$MOCK_LOG"
: >"$MOCK_LOG"
env TELEGRAM_BOT_TOKEN=T tg-poll --chat 7 --multi --anonymous "Q" "a" "b" >/dev/null
want "--anonymous" '"is_anonymous": "true"' "$MOCK_LOG"
want "--multi" '"allows_multiple_answers": "true"' "$MOCK_LOG"
# An option containing a quote must survive JSON encoding, not break the array.
: >"$MOCK_LOG"
env TELEGRAM_BOT_TOKEN=T TELEGRAM_CHAT_ID=42 tg-poll 'Q' 'say "hi"' 'no' >/dev/null
want "quotes in an option are escaped" '[\"say \\\"hi\\\"\",\"no\"]' "$MOCK_LOG"
# Fewer than two options is a usage error (exit 2), not a silent no-op.
if env TELEGRAM_BOT_TOKEN=T TELEGRAM_CHAT_ID=42 tg-poll "only" "one" 2>/dev/null; then
  echo "  FAIL: one option should exit nonzero"
  fail=$((fail + 1))
else
  echo "  PASS: one option exits nonzero"
  pass=$((pass + 1))
fi

echo "== tg-bot: authorized command =="
printf '[{"update_id":1,"message":{"message_id":1,"chat":{"id":42,"type":"private"},"text":"/ping hello"}}]\n' >"$T/u.json"
: >"$MOCK_LOG"
start_mock "$T/u.json"
run_bot_until 'pong hello' env TELEGRAM_BOT_TOKEN=T TELEGRAM_POST_ONLY=0 TELEGRAM_ALLOWED_CHAT_IDS=42 TELEGRAM_COMMANDS_DIR="$COMMANDS"
want "pong hello" 'pong hello' "$MOCK_LOG"

echo "== tg-bot: setMyCommands auto-registers the / menu from '# desc:' =="
: >"$MOCK_LOG"
start_mock # no updates needed — registration happens at startup
run_bot_until 'setMyCommands' env TELEGRAM_BOT_TOKEN=T TELEGRAM_POST_ONLY=0 TELEGRAM_ALLOWED_CHAT_IDS=42 TELEGRAM_COMMANDS_DIR="$COMMANDS"
want "menu registered" 'setMyCommands' "$MOCK_LOG"
want "ping desc from # desc:" 'liveness check' "$MOCK_LOG"

echo "== tg-bot: /help lists custom commands with their '# desc:' =="
# Same source of truth as the / menu: a command with a desc shows it, one
# without still lists, and `_`-prefixed hooks are not user commands at all.
printf '#!%s\necho nodesc\n' "$bash_path" >"$COMMANDS/plain"
chmod +x "$COMMANDS/plain"
printf '#!%s\necho hook\n' "$bash_path" >"$COMMANDS/_hidden"
chmod +x "$COMMANDS/_hidden"
# Invokable but not menu-eligible: valid_cmd allows uppercase and '-', Telegram
# does not. /help must still list it, or it becomes unfindable.
printf '#!%s\necho dashy\n' "$bash_path" >"$COMMANDS/deploy-prod"
chmod +x "$COMMANDS/deploy-prod"
printf '[{"update_id":1,"message":{"message_id":1,"chat":{"id":42,"type":"private"},"text":"/help"}}]\n' >"$T/u.json"
: >"$MOCK_LOG"
start_mock "$T/u.json"
run_bot_until 'Custom commands' env TELEGRAM_BOT_TOKEN=T TELEGRAM_POST_ONLY=0 TELEGRAM_ALLOWED_CHAT_IDS=42 TELEGRAM_COMMANDS_DIR="$COMMANDS"
# Scope these to the sendMessage payload: the descriptions also appear in the
# setMyCommands call made at startup, so matching the whole log would pass even
# if /help still printed bare names.
sent="$T/help-sent"
grep '"method": "sendMessage"' "$MOCK_LOG" >"$sent"
want "ping shows its description in /help" 'liveness check' "$sent"
want "status shows its description in /help" 'report host status' "$sent"
# /ping padded to the width of the longest name (/status) so the descriptions
# line up. The mock logs JSON, which escapes the em dash — match the padding.
want "names are padded into a column" '/ping   ' "$sent"
want "a command without a desc still lists" '/plain' "$sent"
absent "_-prefixed hooks are not listed as commands" '/_hidden' "$sent"
want "invokable-but-not-menu-eligible command still listed" '/deploy-prod' "$sent"
# ...and the / menu must still exclude it, since Telegram would reject the name.
: >"$MOCK_LOG"
start_mock
run_bot_until 'setMyCommands' env TELEGRAM_BOT_TOKEN=T TELEGRAM_POST_ONLY=0 TELEGRAM_ALLOWED_CHAT_IDS=42 TELEGRAM_COMMANDS_DIR="$COMMANDS"
absent "menu excludes a name Telegram would reject" 'deploy-prod' "$MOCK_LOG"
rm -f "$COMMANDS/plain" "$COMMANDS/_hidden" "$COMMANDS/deploy-prod"

echo "== tg-bot: setMyCommands opt-out (TELEGRAM_SET_COMMANDS=0) =="
: >"$MOCK_LOG"
printf '[{"update_id":1,"message":{"message_id":1,"chat":{"id":42,"type":"private"},"text":"/ping hi"}}]\n' >"$T/u.json"
start_mock "$T/u.json"
run_bot_until 'pong hi' env TELEGRAM_BOT_TOKEN=T TELEGRAM_SET_COMMANDS=0 TELEGRAM_POST_ONLY=0 TELEGRAM_ALLOWED_CHAT_IDS=42 TELEGRAM_COMMANDS_DIR="$COMMANDS"
absent "no menu registered when opted out" 'setMyCommands' "$MOCK_LOG"

echo "== tg-bot: path traversal is rejected (no RCE escape) =="
# Plant an executable OUTSIDE the commands dir. A traversal command name must
# be refused and must NOT run it.
mkdir -p "$T/outside"
printf '#!%s\necho PWNED_TRAVERSAL\n' "$bash_path" >"$T/outside/pwn"
chmod +x "$T/outside/pwn"
printf '[{"update_id":1,"message":{"message_id":1,"chat":{"id":42,"type":"private"},"text":"/../outside/pwn"}}]\n' >"$T/u.json"
: >"$MOCK_LOG"
start_mock "$T/u.json"
run_bot_until 'Unknown command' env TELEGRAM_BOT_TOKEN=T TELEGRAM_POST_ONLY=0 TELEGRAM_ALLOWED_CHAT_IDS=42 TELEGRAM_COMMANDS_DIR="$COMMANDS"
want "traversal refused" 'Unknown command' "$MOCK_LOG"
absent "planted binary NOT executed" 'PWNED_TRAVERSAL' "$MOCK_LOG"

echo "== tg-bot: args are not glob-expanded =="
printf '[{"update_id":1,"message":{"message_id":1,"chat":{"id":42,"type":"private"},"text":"/ping *"}}]\n' >"$T/u.json"
: >"$MOCK_LOG"
start_mock "$T/u.json"
run_bot_until 'pong' env TELEGRAM_BOT_TOKEN=T TELEGRAM_POST_ONLY=0 TELEGRAM_ALLOWED_CHAT_IDS=42 TELEGRAM_COMMANDS_DIR="$COMMANDS"
want "literal '*' passed (no glob)" 'pong *' "$MOCK_LOG"
absent "dir listing not leaked" 'pong ping status' "$MOCK_LOG"

echo "== tg-bot: unauthorized chat =="
printf '[{"update_id":1,"message":{"message_id":1,"chat":{"id":999,"type":"private"},"text":"/ping hi"}}]\n' >"$T/u.json"
: >"$MOCK_LOG"
start_mock "$T/u.json"
run_bot_until 'Not authorized' env TELEGRAM_BOT_TOKEN=T TELEGRAM_POST_ONLY=0 TELEGRAM_ALLOWED_CHAT_IDS=42 TELEGRAM_COMMANDS_DIR="$COMMANDS"
want "rejected" 'Not authorized' "$MOCK_LOG"
absent "command not run" 'pong' "$MOCK_LOG"

echo "== tg-bot: post-only + builtin /id =="
printf '[{"update_id":1,"message":{"message_id":1,"chat":{"id":42,"type":"private"},"text":"/ping x"}}]\n' >"$T/u.json"
: >"$MOCK_LOG"
start_mock "$T/u.json"
run_bot_until 'post-only' env TELEGRAM_BOT_TOKEN=T TELEGRAM_POST_ONLY=1
want "post-only refusal" 'post-only' "$MOCK_LOG"
printf '[{"update_id":1,"message":{"message_id":1,"chat":{"id":42,"type":"private"},"text":"/id"}}]\n' >"$T/u.json"
: >"$MOCK_LOG"
start_mock "$T/u.json"
run_bot_until 'chat id: 42' env TELEGRAM_BOT_TOKEN=T TELEGRAM_POST_ONLY=1
want "/id reply" 'chat id: 42' "$MOCK_LOG"

echo "== tg-bot: command parse-mode sentinel (\x01parse_mode=…) =="
printf '#!%s\nprintf "\\001parse_mode=MarkdownV2\\n*bold*\\n"\n' "$bash_path" >"$COMMANDS/md"
chmod +x "$COMMANDS/md"
printf '[{"update_id":1,"message":{"message_id":1,"chat":{"id":42,"type":"private"},"text":"/md"}}]\n' >"$T/u.json"
: >"$MOCK_LOG"
start_mock "$T/u.json"
run_bot_until '*bold*' env TELEGRAM_BOT_TOKEN=T TELEGRAM_POST_ONLY=0 TELEGRAM_ALLOWED_CHAT_IDS=42 TELEGRAM_COMMANDS_DIR="$COMMANDS"
want "parse_mode applied from sentinel" '"parse_mode": "MarkdownV2"' "$MOCK_LOG"
want "sentinel stripped from text" '"text": "*bold*"' "$MOCK_LOG"

echo "== tg-bot: _poll_answer hook =="
printf '#!%s\necho "vote $POLL_OPTIONS by $POLL_VOTER on $POLL_ID"\n' "$bash_path" >"$COMMANDS/_poll_answer"
chmod +x "$COMMANDS/_poll_answer"
printf '[{"update_id":1,"poll_answer":{"poll_id":"PID7","user":{"id":42},"option_ids":[1,2]}}]\n' >"$T/u.json"
: >"$MOCK_LOG"
start_mock "$T/u.json"
run_bot_until 'vote' env TELEGRAM_BOT_TOKEN=T TELEGRAM_CHAT_ID=42 TELEGRAM_POST_ONLY=0 TELEGRAM_ALLOWED_CHAT_IDS=42 TELEGRAM_COMMANDS_DIR="$COMMANDS"
want "poll hook ran with options" 'vote [1,2] by 42 on PID7' "$MOCK_LOG"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
