# shellcheck shell=bash
# tg-onboard — interactive first-run setup for a Telegram bot.
#   1. walks you through registering a bot with @BotFather
#   2. validates the token you paste and encrypts it with sops/age
#   3. polls for your chat id (you just message the bot once)
#   4. writes a non-secret config.env and sends a test message
#
# Everything is written into the *current* project directory (override with --dir).

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n' "$*"; }
ok()    { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m!\033[0m %s\n' "$*"; }
err()   { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
rule()  { printf '\033[2m%s\033[0m\n' "────────────────────────────────────────────────────────"; }

main() {
  local dir="$PWD"
  while [ $# -gt 0 ]; do
    case "$1" in
      -d|--dir) dir="$2"; shift 2;;
      -h|--help) echo "usage: tg-onboard [--dir PROJECT_DIR]"; return 0;;
      *) err "unknown argument: $1"; return 2;;
    esac
  done
  mkdir -p "$dir"
  cd "$dir"

  rule
  bold "  Telegram bot onboarding"
  dim  "  setting up in: $dir"
  rule
  echo

  step_botfather
  local token; token="$(step_token)"
  local username; username="$(step_validate "$token")"
  step_sops "$token"
  local chat_id; chat_id="$(step_chat_id "$token" "$username")"
  step_config "$username" "$chat_id"
  step_test "$token" "$chat_id"
  step_next_steps "$username"
}

step_botfather() {
  bold "1. Register a bot with BotFather"
  cat <<'EOF'

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

   Optional, also via BotFather:  /setdescription, /setcommands, /setprivacy.
EOF
  echo
  read -r -p "   Press Enter once you have a token… " _
  echo
}

step_token() {
  local token=""
  while [ -z "$token" ]; do
    # prompt + read silently so the token never lands in scrollback / history
    printf '\033[1m2. Paste the bot token\033[0m (input hidden): ' >&2
    read -rs token
    echo >&2
    token="$(printf '%s' "$token" | tr -d '[:space:]')"
    [ -z "$token" ] && err "empty — try again"
  done
  printf '%s' "$token"
}

step_validate() {
  local token="$1" resp username
  resp="$(curl --silent --show-error --max-time 20 "$TG_API_BASE/bot${token}/getMe")" || {
    err "could not reach Telegram"; exit 1; }
  if [ "$(jq -r '.ok' <<<"$resp")" != "true" ]; then
    err "token rejected by Telegram: $(jq -r '.description // "invalid token"' <<<"$resp")"
    exit 1
  fi
  username="$(jq -r '.result.username' <<<"$resp")"
  ok "token valid — bot is @${username} ($(jq -r '.result.first_name' <<<"$resp"))" >&2
  echo >&2
  printf '%s' "$username"
}

# Print validated age private-key files found in standard + repo-local
# locations, one per line, de-duplicated by canonical path.
discover_age_keys() {
  local c real
  local seen=()
  local candidates=(
    "${SOPS_AGE_KEY_FILE:-}"
    "${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt"
    "$HOME/.config/sops/age/keys.txt"
    "./keys.txt" "./age.key" "./.age/keys.txt" "./.sops/age/keys.txt"
  )
  for c in "${candidates[@]}"; do
    [ -n "$c" ] && [ -f "$c" ] || continue
    grep -q 'AGE-SECRET-KEY-' "$c" 2>/dev/null || continue
    age-keygen -y "$c" >/dev/null 2>&1 || continue
    real="$(readlink -f "$c" 2>/dev/null || printf '%s' "$c")"
    case " ${seen[*]-} " in *" $real "*) continue ;; esac
    seen+=("$real")
    printf '%s\n' "$c"
  done
}

# Generate a new age key, asking where it should live. Sets $key_file in the
# caller's scope (bash dynamic scoping) and gitignores repo-local keys.
gen_age_key() {
  local def loc ans base
  def="${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt"
  echo "   Where should the new age key live?"
  echo "     1) $def   (shared across your projects — recommended)"
  echo "     2) ./keys.txt   (repo-local; auto-gitignored)"
  read -r -p "   Choice [1], or type a path: " ans
  case "${ans:-1}" in
    1) loc="$def" ;;
    2) loc="./keys.txt" ;;
    *) loc="${ans/#\~/$HOME}" ;;
  esac
  [ -e "$loc" ] && { err "refusing to overwrite existing file: $loc"; exit 1; }
  mkdir -p "$(dirname "$loc")"
  age-keygen -o "$loc" >/dev/null 2>&1 || { err "age-keygen failed"; exit 1; }
  chmod 600 "$loc"
  ok "created age key: $loc"
  case "$loc" in
    ./* | "$PWD"/*)
      base="$(basename "$loc")"
      if [ ! -f .gitignore ] || ! grep -qxF "$base" .gitignore 2>/dev/null; then
        printf '%s\n' "$base" >> .gitignore
        dim "   added $base to .gitignore (never commit a private key)"
      fi ;;
  esac
  key_file="$loc"
}

step_sops() {
  local token="$1"
  bold "3. Encrypting the token with sops"
  echo "   An age key is needed to encrypt the token. Looking for one…"

  local keys=() key_file="" recipient="" ans i k
  mapfile -t keys < <(discover_age_keys)

  if [ "${#keys[@]}" -gt 0 ]; then
    echo "   Found age key(s):"
    i=1
    for k in "${keys[@]}"; do
      printf '     %d) %s  →  %s\n' "$i" "$k" "$(age-keygen -y "$k" 2>/dev/null | head -n1)"
      i=$((i + 1))
    done
    read -r -p "   Use which? [1-${#keys[@]}], (p)ath, (n)ew  [1]: " ans
    ans="${ans:-1}"
    case "$ans" in
      [pP]*) read -r -p "   Path to existing age key file: " key_file; key_file="${key_file/#\~/$HOME}" ;;
      [nN]*) gen_age_key ;;
      *)
        if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "${#keys[@]}" ]; then
          key_file="${keys[$((ans - 1))]}"
        else
          err "invalid choice: $ans"; exit 1
        fi ;;
    esac
  else
    warn "no age key found (looked in \$SOPS_AGE_KEY_FILE, ~/.config/sops/age/, ./keys.txt, ./.sops/age/…)"
    read -r -p "   (g)enerate a new key, or (p)rovide an existing path?  [g]: " ans
    case "${ans:-g}" in
      [pP]*) read -r -p "   Path to existing age key file: " key_file; key_file="${key_file/#\~/$HOME}" ;;
      *) gen_age_key ;;
    esac
  fi

  # Validate the chosen/provided key and derive its public recipient.
  { [ -n "$key_file" ] && [ -f "$key_file" ]; } || { err "no usable age key file: ${key_file:-<none>}"; exit 1; }
  grep -q 'AGE-SECRET-KEY-' "$key_file" 2>/dev/null || { err "$key_file is not an age private key"; exit 1; }
  recipient="$(age-keygen -y "$key_file" 2>/dev/null | head -n1)"
  [ -n "$recipient" ] || { err "could not derive a recipient from $key_file"; exit 1; }
  export SOPS_AGE_KEY_FILE="$key_file"
  ok "using age key: $key_file"
  dim "   public recipient: $recipient"
  echo

  # Ensure a .sops.yaml creation rule covers secrets/*.yaml.
  if [ ! -f .sops.yaml ]; then
    cat > .sops.yaml <<EOF
# Managed by tg-onboard. Adds your age key as a recipient for secrets/*.yaml.
creation_rules:
  - path_regex: secrets/[^/]+\.ya?ml\$
    age: ${recipient}
EOF
    ok "wrote .sops.yaml (recipient ${recipient})"
  else
    warn ".sops.yaml already exists — leaving it untouched"
    dim  "   ensure it has a rule for secrets/*.yaml including age key ${recipient}"
  fi

  # Encrypt the token. sops matches creation_rules against the *file path* it is
  # given, so write to the final secrets/ path and encrypt in place — otherwise
  # the secrets/*.yaml rule never matches ("no matching creation rules found").
  mkdir -p secrets
  printf 'telegram_bot_token: %s\n' "$token" > secrets/telegram.yaml
  if sops --encrypt --in-place secrets/telegram.yaml 2>/dev/null; then
    ok "encrypted token → secrets/telegram.yaml (safe to commit)"
  else
    rm -f secrets/telegram.yaml  # never leave the plaintext token on disk
    err "sops encryption failed (does .sops.yaml have a rule for secrets/*.yaml with your key?)"
    exit 1
  fi
  echo
}

step_chat_id() {
  local token="$1" username="$2"
  bold "4. Finding your chat id" >&2
  cat >&2 <<EOF

   The bot can only message a chat that has messaged it first.

     → Open Telegram, find  @${username}, and send it any message
       (just tap Start, or type /start).
     → For a group: add the bot to the group, then send a message there.

EOF
  # Webhooks block getUpdates polling; clear any.
  curl --silent --max-time 20 "$TG_API_BASE/bot${token}/deleteWebhook" >/dev/null 2>&1 || true

  local offset=0 chat_id="" chat_label="" resp n waited=0
  printf '   waiting for a message' >&2
  while [ "$waited" -lt 180 ]; do
    resp="$(curl --silent --max-time 35 "$TG_API_BASE/bot${token}/getUpdates?timeout=30&offset=${offset}")" || true
    if [ "$(jq -r '.ok // false' <<<"$resp")" = "true" ]; then
      n="$(jq '.result | length' <<<"$resp")"
      if [ "${n:-0}" -gt 0 ]; then
        chat_id="$(jq -r 'last(.result[]).message.chat.id // last(.result[]).my_chat_member.chat.id // empty' <<<"$resp")"
        chat_label="$(jq -r 'last(.result[]).message.chat | (.title // .username // .first_name // "?") + " (" + .type + ")" // empty' <<<"$resp")"
        offset="$(( $(jq -r 'last(.result[]).update_id' <<<"$resp") + 1 ))"
        [ -n "$chat_id" ] && break
      fi
    fi
    printf '.' >&2
    waited=$((waited + 30))
  done
  echo >&2
  if [ -z "$chat_id" ]; then
    err "timed out waiting for a message."
    read -r -p "   Enter the chat id manually (or leave blank to skip): " chat_id
  else
    ok "found chat: ${chat_label:-$chat_id}  →  id ${chat_id}" >&2
  fi
  echo >&2
  printf '%s' "$chat_id"
}

step_config() {
  local username="$1" chat_id="$2"
  bold "5. Writing config.env"
  local abs_sops; abs_sops="$(pwd)/secrets/telegram.yaml"
  # `${VAR:-...}` form ⇒ explicit environment variables override the config file.
  cat > config.env <<EOF
# Non-secret telegram-bot config — written by tg-onboard. Safe to commit.
# The token itself stays encrypted in secrets/telegram.yaml.
export TELEGRAM_BOT_SOPS_FILE="\${TELEGRAM_BOT_SOPS_FILE:-${abs_sops}}"
export TELEGRAM_BOT_SOPS_KEY="\${TELEGRAM_BOT_SOPS_KEY:-telegram_bot_token}"
export TELEGRAM_BOT_USERNAME="\${TELEGRAM_BOT_USERNAME:-${username}}"
export TELEGRAM_CHAT_ID="\${TELEGRAM_CHAT_ID:-${chat_id}}"
EOF
  ok "wrote config.env"
  dim "   source it (or set TELEGRAM_BOT_CONFIG=$(pwd)/config.env) before using tg-send."
  echo
}

step_test() {
  local token="$1" chat_id="$2"
  [ -n "$chat_id" ] || { warn "no chat id — skipping test message"; echo; return 0; }
  bold "6. Sending a test message"
  local resp
  resp="$(curl --silent --show-error --max-time 20 \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "text=✅ telegram-bot onboarding complete. You'll receive messages here." \
    "$TG_API_BASE/bot${token}/sendMessage")" || true
  if [ "$(jq -r '.ok // false' <<<"$resp")" = "true" ]; then
    ok "test message sent — check Telegram"
  else
    warn "test message failed: $(jq -r '.description // "unknown"' <<<"$resp")"
  fi
  echo
}

step_next_steps() {
  local username="$1"
  rule
  bold "  Done. Next steps"
  cat <<EOF

  Send from anything:
     source ./config.env
     tg-send "hello from \$(hostname)"
     journalctl -u myservice -n 50 | tg-send --file -

  Receive / run commands (optional) — see README.md "Commands & rights":
     • post-only (default): the bot only sends; inbound is ignored.
     • command mode: drop executables in a commands dir + set an allowlist,
       then run the tg-bot daemon (or the NixOS 'services.telegram-bot' module).

  NixOS service: point services.telegram-bot.tokenFile at a sops-nix secret
  decrypted from secrets/telegram.yaml. Full example in README.md.
EOF
  rule
}

main "$@"
