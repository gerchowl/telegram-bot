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
  # A command may opt into a Telegram parse mode by emitting a sentinel first
  # line:  \x01parse_mode=MarkdownV2  (stripped before sending). Lets a command
  # return rich/aligned output without changing the default plain behaviour.
  local pmode=""
  case "$out" in
    $'\001parse_mode='*)
      pmode="${out%%$'\n'*}"
      pmode="${pmode#*=}"
      out="${out#*$'\n'}"
      ;;
  esac
  out="${out:0:$TG_LIMIT}"
  tg_send_message "$chat" "$out" "$pmode"
}

# A non-anonymous poll vote. Runs the optional `_poll_answer` hook in the
# commands dir with POLL_ID / POLL_OPTIONS (JSON array of selected indexes) /
# POLL_VOTER; any output is sent to the configured chat as a confirmation.
tg_handle_poll_answer() {
  local upd="$1" dir="${TELEGRAM_COMMANDS_DIR:-}" poll_id voter opts out
  [ -n "$dir" ] && [ -x "$dir/_poll_answer" ] || return 0
  poll_id="$(jq -r '.poll_answer.poll_id // empty' <<<"$upd")"
  voter="$(jq -r '.poll_answer.user.id // empty' <<<"$upd")"
  opts="$(jq -rc '.poll_answer.option_ids // []' <<<"$upd")"
  [ -n "$poll_id" ] || return 0
  set +e
  out="$(cd "$dir" && POLL_ID="$poll_id" POLL_OPTIONS="$opts" POLL_VOTER="$voter" \
    timeout "${TELEGRAM_COMMAND_TIMEOUT:-60}" "./_poll_answer" 2>&1)"
  set -e
  if [ -n "$out" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    tg_send_message "$TELEGRAM_CHAT_ID" "${out:0:$TG_LIMIT}"
  fi
  return 0
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

# Auto-register the slash-command menu (Bot API setMyCommands) from the commands
# dir: each executable's first `# desc: <text>` line becomes its menu description,
# so the "/" autocomplete is populated straight from the scripts — no manual
# BotFather /setcommands step. Opt out with TELEGRAM_SET_COMMANDS=0. No-op in
# post-only mode or without a commands dir. Telegram requires command names to be
# 1–32 chars of [a-z0-9_]; anything else (and `_`-prefixed hooks) is skipped.
tg_register_commands() {
  local tok="$1" dir="${TELEGRAM_COMMANDS_DIR:-}"
  [ "${TELEGRAM_SET_COMMANDS:-1}" != 0 ] || return 0
  [ "${TELEGRAM_POST_ONLY:-1}" != 1 ] || return 0
  [ -n "$dir" ] && [ -d "$dir" ] || return 0

  local json="[]" f name desc
  for f in "$dir"/*; do
    [ -f "$f" ] && [ -x "$f" ] || continue
    name="$(basename "$f")"
    case "$name" in
      _* | *[!a-z0-9_]*) continue ;;
    esac
    [ "${#name}" -le 32 ] || continue
    desc="$(sed -n 's/^#[[:space:]]*desc:[[:space:]]*//p' "$f" | head -n1)"
    [ -n "$desc" ] || continue
    desc="${desc:0:256}" # Telegram caps descriptions at 256 chars
    json="$(jq -c --arg c "$name" --arg d "$desc" '. + [{command:$c,description:$d}]' <<<"$json")"
  done

  [ "$json" != "[]" ] || return 0
  local resp
  resp="$(tg_api "$tok" setMyCommands --data-urlencode "commands=${json}")" || {
    echo "tg-bot: setMyCommands request failed (network?)" >&2
    return 0
  }
  if [ "$(jq -r '.ok // false' <<<"$resp")" = "true" ]; then
    echo "tg-bot: registered $(jq 'length' <<<"$json") command(s) via setMyCommands" >&2
  else
    echo "tg-bot: setMyCommands failed: $(jq -r '.description // "unknown"' <<<"$resp")" >&2
  fi
}

main() {
  tg_load_config
  local tok
  tok="$(tg_resolve_token)" || exit $?
  export TELEGRAM_BOT_TOKEN="$tok" # cache so replies don't re-decrypt sops each time

  local state_dir offset_file offset resp n i uid upd
  state_dir="${TELEGRAM_BOT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/telegram-bot}"
  mkdir -p "$state_dir"
  offset_file="$state_dir/offset"
  offset="$(cat "$offset_file" 2>/dev/null || echo 0)"

  echo "tg-bot: starting (post_only=${TELEGRAM_POST_ONLY:-1}, commands_dir=${TELEGRAM_COMMANDS_DIR:-none}, allow=${TELEGRAM_ALLOWED_CHAT_IDS:-none})" >&2
  curl --silent --max-time 20 "$TG_API_BASE/bot${tok}/deleteWebhook" >/dev/null 2>&1 || true
  tg_register_commands "$tok" # populate the "/" menu from the commands' `# desc:` lines

  while true; do
    set +e
    # allowed_updates includes poll_answer so the command runner can record
    # votes (e.g. a workout-tracking poll); URL-encoded ["message","poll_answer"].
    resp="$(curl --silent --show-error --max-time 70 "$TG_API_BASE/bot${tok}/getUpdates?timeout=50&offset=${offset}&allowed_updates=%5B%22message%22%2C%22poll_answer%22%5D")"
    local curl_rc=$?
    set -e
    if [ "$curl_rc" -ne 0 ]; then
      sleep 3
      continue
    fi
    if [ "$(jq -r '.ok // false' <<<"$resp")" != "true" ]; then
      local code desc
      code="$(jq -r '.error_code // 0' <<<"$resp")"
      desc="$(jq -r '.description // "unknown"' <<<"$resp")"
      # 401/404 mean the token is invalid/empty — a config error, not a blip.
      # Fail loud (non-zero exit) instead of retrying it forever in silence.
      case "$code" in
        401 | 404)
          echo "tg-bot: FATAL getUpdates ${code}: ${desc} — bot token is invalid or empty; refusing to retry. Check token resolution (sops/age)." >&2
          exit 1
          ;;
      esac
      echo "tg-bot: getUpdates error ${code}: ${desc}" >&2
      sleep 5
      continue
    fi
    n="$(jq '.result | length' <<<"$resp")"
    [ "${n:-0}" -gt 0 ] || continue
    for ((i = 0; i < n; i++)); do
      upd="$(jq -c ".result[$i]" <<<"$resp")"
      if [ "$(jq -r 'has("poll_answer")' <<<"$upd")" = "true" ]; then
        tg_handle_poll_answer "$upd"
      else
        tg_handle_update "$upd"
      fi
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
