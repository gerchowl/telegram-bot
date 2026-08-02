#!/usr/bin/env bash
# Hermetic end-to-end test for tg-onboard, run as a nix flake check. tg-onboard,
# sops, age-keygen, python3 come from PATH (provided by the check derivation).
# Uses the same localhost mock Telegram API as tests/e2e.sh.
#
# tg-onboard is interactive, so every scenario drives it by piping the answers
# on stdin. It reads the token via rpassword only when stdin is a terminal;
# piped input takes the plain-read path, which is what runs here.
set -uo pipefail

T="$(mktemp -d)"
export MOCK_LOG="$T/log.jsonl"
export MOCK_PORT_FILE="$T/port"
export HOME="$T"
MOCK_PY="${TGB_MOCK:?set TGB_MOCK to mock.py}"
MOCK_PID=""

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

TOKEN='123456:FAKETOKEN'
UPDATES="$T/u.json"
printf '[{"update_id":1,"message":{"message_id":1,"chat":{"id":4242,"type":"private","first_name":"Lars"},"text":"/start"}}]\n' >"$UPDATES"

echo "== tg-onboard: --help and argument errors =="
tg-onboard --help >"$T/help.out" 2>&1
want "help mentions --dir" 'tg-onboard [--dir PROJECT_DIR]' "$T/help.out"
if tg-onboard --bogus >/dev/null 2>&1; then
  no "unknown argument should exit nonzero"
else
  [ "$?" -eq 2 ] && ok "unknown argument exits 2" || no "unknown argument should exit 2"
fi

echo "== tg-onboard: full run with a discovered age key =="
start_mock "$UPDATES"
mkdir -p "$T/agehome" "$T/proj1"
age-keygen -o "$T/agehome/keys.txt" 2>/dev/null
chmod 600 "$T/agehome/keys.txt"
RECIPIENT="$(age-keygen -y "$T/agehome/keys.txt")"
# stdin: Enter (BotFather step) · token · "1" (use the discovered key)
printf '\n%s\n1\n' "$TOKEN" | env SOPS_AGE_KEY_FILE="$T/agehome/keys.txt" \
  tg-onboard --dir "$T/proj1" >"$T/run1.out" 2>&1
if [ "$?" -eq 0 ]; then ok "exits 0"; else
  no "exits 0"
  cat "$T/run1.out"
fi
want "validated the token via getMe" 'bot is @mockbot' "$T/run1.out"
want "discovered the age key" "$T/agehome/keys.txt" "$T/run1.out"
want "found the chat from an update" 'id 4242' "$T/run1.out"
want ".sops.yaml carries the recipient" "$RECIPIENT" "$T/proj1/.sops.yaml"
want ".sops.yaml rule targets secrets/*.yaml" 'path_regex: secrets/' "$T/proj1/.sops.yaml"
want "token is encrypted at rest" 'ENC[AES256_GCM' "$T/proj1/secrets/telegram.yaml"
# The whole point: the encrypted file must decrypt back to the exact token.
env SOPS_AGE_KEY_FILE="$T/agehome/keys.txt" \
  sops -d --extract '["telegram_bot_token"]' "$T/proj1/secrets/telegram.yaml" >"$T/dec.out" 2>&1
want "sops round-trips the token" "$TOKEN" "$T/dec.out"
want "config.env points at the sops file" 'TELEGRAM_BOT_SOPS_FILE' "$T/proj1/config.env"
want "config.env records the chat id" 'TELEGRAM_CHAT_ID:-4242' "$T/proj1/config.env"
want "config.env records the username" 'TELEGRAM_BOT_USERNAME:-mockbot' "$T/proj1/config.env"
want "config.env lets env override" '${TELEGRAM_CHAT_ID:-' "$T/proj1/config.env"
want "sent the test message" '"chat_id": "4242"' "$MOCK_LOG"
# The plaintext token must exist nowhere on disk outside the encrypted blob.
if grep -rqF "$TOKEN" "$T/proj1" 2>/dev/null; then
  no "plaintext token left on disk"
  grep -rlF "$TOKEN" "$T/proj1"
else
  ok "no plaintext token on disk"
fi

echo "== tg-onboard: generates a key when none is found, and gitignores a local one =="
start_mock "$UPDATES"
mkdir -p "$T/proj2"
# stdin: Enter · token · "g" (generate) · "2" (repo-local ./keys.txt)
(
  cd "$T/proj2" || exit 1
  printf '\n%s\ng\n2\n' "$TOKEN" | env -u SOPS_AGE_KEY_FILE tg-onboard >"$T/run2.out" 2>&1
)
want "generated a new key" 'created age key' "$T/run2.out"
want "gitignored the repo-local key" 'keys.txt' "$T/proj2/.gitignore"
want "encrypted with the generated key" 'ENC[AES256_GCM' "$T/proj2/secrets/telegram.yaml"
if [ -f "$T/proj2/keys.txt" ]; then
  perm="$(stat -c '%a' "$T/proj2/keys.txt" 2>/dev/null || stat -f '%Lp' "$T/proj2/keys.txt")"
  [ "$perm" = "600" ] && ok "private key is chmod 600" || no "private key perms are $perm, want 600"
else
  no "generated key file missing"
fi

echo "== tg-onboard: refuses to clobber an existing key file =="
start_mock "$UPDATES"
mkdir -p "$T/proj3"
printf 'not-a-key\n' >"$T/proj3/keys.txt"
(
  cd "$T/proj3" || exit 1
  printf '\n%s\ng\n2\n' "$TOKEN" | env -u SOPS_AGE_KEY_FILE tg-onboard >"$T/run3.out" 2>&1
)
want "refuses to overwrite" 'refusing to overwrite' "$T/run3.out"
want "existing file untouched" 'not-a-key' "$T/proj3/keys.txt"
absent "no secrets written after the refusal" 'ENC[' "$T/run3.out"

echo "== tg-onboard: a pre-planted symlink cannot redirect the plaintext token =="
# secrets/telegram.yaml is plaintext for the moment between write and `sops
# --encrypt --in-place`. If it were a symlink, the token would land at the
# target and the failure-path cleanup would unlink only the link.
start_mock "$UPDATES"
mkdir -p "$T/proj4/secrets"
printf 'untouched\n' >"$T/decoy"
ln -s "$T/decoy" "$T/proj4/secrets/telegram.yaml"
printf '\n%s\n1\n' "$TOKEN" | env SOPS_AGE_KEY_FILE="$T/agehome/keys.txt" \
  tg-onboard --dir "$T/proj4" >"$T/run4.out" 2>&1
absent "symlink target did not receive the token" "$TOKEN" "$T/decoy"
want "decoy left intact" 'untouched' "$T/decoy"
if [ -L "$T/proj4/secrets/telegram.yaml" ]; then
  no "secrets/telegram.yaml is still a symlink"
else
  ok "symlink replaced by a regular file"
fi
want "token encrypted into the real file" 'ENC[AES256_GCM' "$T/proj4/secrets/telegram.yaml"

echo "== tg-onboard: a failing sops leaves no plaintext token behind =="
# The cleanup branch: plaintext is written, sops then fails, and the file must
# be removed. Driven by a pre-existing .sops.yaml whose rule does not match
# secrets/*.yaml, which tg-onboard leaves untouched -> "no matching creation
# rules found".
start_mock "$UPDATES"
mkdir -p "$T/proj5"
cat >"$T/proj5/.sops.yaml" <<'YAML'
creation_rules:
  - path_regex: nothing-matches-this/[^/]+\.yaml$
    age: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
YAML
printf '\n%s\n1\n' "$TOKEN" | env SOPS_AGE_KEY_FILE="$T/agehome/keys.txt" \
  tg-onboard --dir "$T/proj5" >"$T/run5.out" 2>&1
if [ "$?" -ne 0 ]; then ok "aborts nonzero when sops fails"; else no "should exit nonzero when sops fails"; fi
want "reports the encryption failure" 'sops encryption failed' "$T/run5.out"
if [ -e "$T/proj5/secrets/telegram.yaml" ]; then
  no "plaintext secrets/telegram.yaml was left behind"
else
  ok "plaintext secrets file removed"
fi
if grep -rqF "$TOKEN" "$T/proj5" 2>/dev/null; then
  no "token found on disk after the failure"
  grep -rlF "$TOKEN" "$T/proj5"
else
  ok "no token anywhere under the project after the failure"
fi
absent "token not echoed in the error output" "$TOKEN" "$T/run5.out"

echo "== token resolution: sops failures are diagnosed, not silently empty =="
# Both controls existed in the deleted scripts/lib.sh. With Rust the only
# implementation they have to live here, or a misconfigured key just 404s.
env TELEGRAM_CHAT_ID=42 TELEGRAM_BOT_SOPS_FILE="$T/proj1/secrets/telegram.yaml" \
  TELEGRAM_BOT_SOPS_KEY=no_such_key SOPS_AGE_KEY_FILE="$T/agehome/keys.txt" \
  tg-send "x" >"$T/badkey.out" 2>&1
if [ "$?" -ne 0 ]; then ok "wrong sops key exits nonzero"; else no "wrong sops key should exit nonzero"; fi
want "wrong sops key is diagnosed" 'sops failed to decrypt' "$T/badkey.out"
absent "no token in the error" "$TOKEN" "$T/badkey.out"
# No reachable age identity => sops cannot decrypt at all.
env TELEGRAM_CHAT_ID=42 TELEGRAM_BOT_SOPS_FILE="$T/proj1/secrets/telegram.yaml" \
  SOPS_AGE_KEY_FILE=/nonexistent tg-send "x" >"$T/nokey.out" 2>&1
want "unreachable identity mentions SOPS_AGE_KEY_FILE" 'SOPS_AGE_KEY_FILE' "$T/nokey.out"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
