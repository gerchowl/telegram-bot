# shellcheck shell=bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Lars Gerchow
# Shared helpers, concatenated into each telegram-bot CLI by flake.nix.
# Provides config loading, token resolution (env > file > sops) and a send helper.

TG_API_BASE="${TELEGRAM_API_BASE:-https://api.telegram.org}"

# Source a non-secret config.env if present. The config file is expected to use
# `export VAR="${VAR:-default}"` so that explicit environment variables always win.
tg_load_config() {
  local cfg="${1:-${TELEGRAM_BOT_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/telegram-bot/config.env}}"
  if [ -f "$cfg" ]; then
    # shellcheck disable=SC1090
    . "$cfg"
  fi
}

# Resolve the bot token. Precedence:
#   1. $TELEGRAM_BOT_TOKEN              (raw token in env)
#   2. $TELEGRAM_BOT_TOKEN_FILE         (path to a file holding the token; e.g. a sops-nix secret)
#   3. $TELEGRAM_BOT_SOPS_FILE          (sops-encrypted yaml, key $TELEGRAM_BOT_SOPS_KEY)
# Prints the token to stdout, or an error to stderr and returns 2.
tg_resolve_token() {
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
    printf '%s' "$TELEGRAM_BOT_TOKEN"
    return 0
  fi
  if [ -n "${TELEGRAM_BOT_TOKEN_FILE:-}" ] && [ -f "${TELEGRAM_BOT_TOKEN_FILE}" ]; then
    tr -d '\r\n' <"$TELEGRAM_BOT_TOKEN_FILE"
    return 0
  fi
  if [ -n "${TELEGRAM_BOT_SOPS_FILE:-}" ]; then
    local key="${TELEGRAM_BOT_SOPS_KEY:-telegram_bot_token}"
    sops -d --extract "[\"${key}\"]" "$TELEGRAM_BOT_SOPS_FILE" | tr -d '\r\n'
    return 0
  fi
  echo "telegram-bot: no bot token found. Set TELEGRAM_BOT_TOKEN, TELEGRAM_BOT_TOKEN_FILE or TELEGRAM_BOT_SOPS_FILE (run 'tg-onboard' to set up)." >&2
  return 2
}

# Call a Telegram Bot API method with urlencoded form fields.
# Usage: tg_api <token> <method> [curl-args...]   -> prints raw JSON response
# NOTE: Telegram's Bot API authenticates by putting the token in the URL path
# (there is no header-based auth), so the token can appear in `curl --verbose`,
# proxy logs, or `strace` output. This is unavoidable; keep such traces private.
tg_api() {
  local tok="$1" method="$2"
  shift 2
  curl --silent --show-error --max-time 30 "$@" "$TG_API_BASE/bot${tok}/${method}"
}

# Send a text message.
#   $1 chat_id   $2 text   $3 parse_mode(optional)   $4 silent(1 to mute)
tg_send_message() {
  local tok chat text resp
  tok="$(tg_resolve_token)" || return $?
  chat="$1"
  text="$2"
  if [ -z "$chat" ]; then
    echo "telegram-bot: no chat id (set TELEGRAM_CHAT_ID or pass --chat)" >&2
    return 2
  fi
  local args=(--data-urlencode "chat_id=${chat}" --data-urlencode "text=${text}")
  [ -n "${3:-}" ] && args+=(--data-urlencode "parse_mode=${3}")
  [ "${4:-0}" = 1 ] && args+=(--data-urlencode "disable_notification=true")
  resp="$(tg_api "$tok" sendMessage "${args[@]}")" || {
    echo "telegram-bot: network error talking to Telegram" >&2
    return 1
  }
  if [ "$(jq -r '.ok' <<<"$resp")" != "true" ]; then
    echo "telegram-bot: API error: $(jq -r '.description // "unknown error"' <<<"$resp")" >&2
    return 1
  fi
  return 0
}
