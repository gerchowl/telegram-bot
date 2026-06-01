# shellcheck shell=bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Lars Gerchow
# tg-bot — long-polling daemon. Receives messages and (optionally) runs commands.
#
# Rights model (safe by default):
#   • TELEGRAM_POST_ONLY=1 (default)  → never executes anything; built-ins only.
#   • command mode (POST_ONLY=0) requires BOTH:
#       - TELEGRAM_ALLOWED_CHAT_IDS  (comma/space list; empty ⇒ nobody authorized)
#       - TELEGRAM_COMMANDS_DIR      (dir of executables; '/foo' runs './foo')
#   Command names are restricted to [A-Za-z0-9_-] so they cannot escape the
#   commands dir; args are split into separate argv with NO glob/pathname
#   expansion and NO eval; each command runs under `timeout` and its combined
#   output is sent back (truncated to Telegram's limit).
#
# Built-in commands (always available): /start /id /help

TG_LIMIT=3900 # leave headroom under Telegram's 4096-char message cap

# Is chat id "$1" in the allowlist? Empty allowlist ⇒ no one is authorized.
tg_is_allowed() {
  local id="$1" list=" ${TELEGRAM_ALLOWED_CHAT_IDS:-} "
  list="${list//,/ }"
  [ -n "${TELEGRAM_ALLOWED_CHAT_IDS:-}" ] || return 1
  case " $list " in *" $id "*) return 0 ;; *) return 1 ;; esac
}

tg_help_text() {
  local txt="Available commands:
  /start — check the bot is alive
  /id    — show this chat id
  /help  — this message"
  if [ "${TELEGRAM_POST_ONLY:-1}" != 1 ] && [ -n "${TELEGRAM_COMMANDS_DIR:-}" ] && [ -d "${TELEGRAM_COMMANDS_DIR}" ]; then
    local extra
    extra="$(find "$TELEGRAM_COMMANDS_DIR" -maxdepth 1 -type f -perm -u+x -printf '  /%f\n' 2>/dev/null | sort)"
    [ -n "$extra" ] && txt="$txt
Custom commands:
$extra"
  else
    txt="$txt
(this bot is post-only; custom commands are disabled)"
  fi
  printf '%s' "$txt"
}

tg_run_command() {
  local cmd="$1" rest="$2" chat="$3" dir="${TELEGRAM_COMMANDS_DIR:-}"
  # Hard gate: a command name must be a simple identifier. This is the control
  # that keeps execution INSIDE the commands dir — it rejects path traversal
  # ("/../../bin/sh") and any name with '/', '.', whitespace, etc. Without it,
  # "$dir/$cmd" could resolve to an arbitrary executable anywhere on disk.
  case "$cmd" in
    '' | *[!A-Za-z0-9_-]*)
      tg_send_message "$chat" "❓ Unknown command: /$cmd  (try /help)"
      return 0
      ;;
  esac
  if [ -z "$dir" ] || [ ! -x "$dir/$cmd" ]; then
    tg_send_message "$chat" "❓ Unknown command: /$cmd  (try /help)"
    return 0
  fi
  # Split args into separate argv. `read -a` does word-splitting ONLY — no
  # pathname/glob expansion and no eval — unlike `argv=( $rest )`, so "/ping *"
  # passes a literal "*" rather than the directory listing.
  local argv=()
  IFS=' ' read -r -a argv <<<"$rest" || true
  local out rc
  set +e
  out="$(cd "$dir" && TG_CHAT_ID="$chat" TG_COMMAND="$cmd" \
    timeout "${TELEGRAM_COMMAND_TIMEOUT:-60}" "./$cmd" "${argv[@]}" 2>&1)"
  rc=$?
  set -e
  [ -n "$out" ] || out="(/$cmd exited $rc with no output)"
  out="${out:0:$TG_LIMIT}"
  tg_send_message "$chat" "$out"
}

tg_handle_update() {
  local upd="$1" chat text cmd rest
  chat="$(jq -r '.message.chat.id // empty' <<<"$upd")"
  text="$(jq -r '.message.text // empty' <<<"$upd")"
  [ -n "$chat" ] && [ -n "$text" ] || return 0
  case "$text" in /*) ;; *) return 0 ;; esac # only react to /commands

  cmd="${text%%[[:space:]]*}" # leading token incl. slash
  cmd="${cmd#/}"              # strip slash
  cmd="${cmd%%@*}"            # strip @botname (groups append it)
  rest="${text#/"$cmd"}"
  rest="${rest#@*[[:space:]]}" # tolerate /cmd@bot args
  rest="${rest# }"

  case "$cmd" in
    start)
      tg_send_message "$chat" "👋 Online. /help for commands. This chat id is $chat."
      return 0
      ;;
    id)
      tg_send_message "$chat" "chat id: $chat"
      return 0
      ;;
    help)
      tg_send_message "$chat" "$(tg_help_text)"
      return 0
      ;;
  esac

  if [ "${TELEGRAM_POST_ONLY:-1}" = 1 ]; then
    tg_send_message "$chat" "🔒 This bot is post-only; commands are disabled."
    return 0
  fi
  if ! tg_is_allowed "$chat"; then
    echo "tg-bot: rejected /$cmd from unauthorized chat $chat" >&2
    tg_send_message "$chat" "⛔ Not authorized."
    return 0
  fi
  tg_run_command "$cmd" "$rest" "$chat"
}

main() {
  tg_load_config
  local tok
  tok="$(tg_resolve_token)" || exit $?
  export TELEGRAM_BOT_TOKEN="$tok" # cache so replies don't re-decrypt sops each time

  local state_dir offset_file offset resp n i uid
  state_dir="${TELEGRAM_BOT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/telegram-bot}"
  mkdir -p "$state_dir"
  offset_file="$state_dir/offset"
  offset="$(cat "$offset_file" 2>/dev/null || echo 0)"

  echo "tg-bot: starting (post_only=${TELEGRAM_POST_ONLY:-1}, commands_dir=${TELEGRAM_COMMANDS_DIR:-none}, allow=${TELEGRAM_ALLOWED_CHAT_IDS:-none})" >&2
  curl --silent --max-time 20 "$TG_API_BASE/bot${tok}/deleteWebhook" >/dev/null 2>&1 || true

  while true; do
    set +e
    resp="$(curl --silent --show-error --max-time 70 "$TG_API_BASE/bot${tok}/getUpdates?timeout=50&offset=${offset}")"
    local curl_rc=$?
    set -e
    if [ "$curl_rc" -ne 0 ]; then
      sleep 3
      continue
    fi
    if [ "$(jq -r '.ok // false' <<<"$resp")" != "true" ]; then
      echo "tg-bot: getUpdates error: $(jq -r '.description // "unknown"' <<<"$resp")" >&2
      sleep 5
      continue
    fi
    n="$(jq '.result | length' <<<"$resp")"
    [ "${n:-0}" -gt 0 ] || continue
    for ((i = 0; i < n; i++)); do
      tg_handle_update "$(jq -c ".result[$i]" <<<"$resp")"
      uid="$(jq -r ".result[$i].update_id" <<<"$resp")"
      case "$uid" in
        '' | *[!0-9]*) ;; # ignore non-numeric; never crash the loop
        *)
          offset=$((uid + 1))
          echo "$offset" >"$offset_file"
          ;;
      esac
    done
  done
}

main "$@"
