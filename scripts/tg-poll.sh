# shellcheck shell=bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Lars Gerchow
# tg-poll — send a Telegram poll and print its poll id, so a project can map
# incoming poll_answer updates back to what was asked. Non-anonymous by default
# (the bot needs the voter to record answers).

usage() {
  cat >&2 <<'EOF'
tg-poll — send a Telegram poll; prints the poll id on stdout.

USAGE:
  tg-poll [options] "Question" "Option 1" "Option 2" [...]

OPTIONS:
  -c, --chat ID     Target chat id (default: $TELEGRAM_CHAT_ID)
  -m, --multi       Allow multiple answers
      --anonymous   Anonymous poll (no voter; can't be tracked)
      --config PATH Use this config.env instead of the default
  -h, --help        Show this help

Token/chat resolution matches tg-send. 2–10 options; non-anonymous by default.
EOF
}

main() {
  local chat="" config="" multi=false anon=false
  while [ $# -gt 0 ]; do
    case "$1" in
      -c | --chat)
        chat="$2"
        shift 2
        ;;
      -m | --multi)
        multi=true
        shift
        ;;
      --anonymous)
        anon=true
        shift
        ;;
      --config)
        config="$2"
        shift 2
        ;;
      -h | --help)
        usage
        return 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "tg-poll: unknown option: $1" >&2
        usage
        return 2
        ;;
      *) break ;;
    esac
  done

  tg_load_config "$config"
  [ -n "$chat" ] || chat="${TELEGRAM_CHAT_ID:-}"

  local question="${1:-}"
  [ "$#" -gt 0 ] && shift
  local options=("$@")
  if [ -z "$question" ]; then
    echo "tg-poll: a question is required" >&2
    return 2
  fi
  if [ "${#options[@]}" -lt 2 ]; then
    echo "tg-poll: at least two options are required" >&2
    return 2
  fi

  local options_json tok resp
  options_json="$(printf '%s\n' "${options[@]}" | jq -R . | jq -cs .)"
  tok="$(tg_resolve_token)" || return $?
  [ -n "$chat" ] || {
    echo "tg-poll: no chat id (set TELEGRAM_CHAT_ID or pass --chat)" >&2
    return 2
  }

  resp="$(curl --silent --show-error --max-time 30 \
    --data-urlencode "chat_id=${chat}" \
    --data-urlencode "question=${question}" \
    --data-urlencode "options=${options_json}" \
    --data-urlencode "is_anonymous=${anon}" \
    --data-urlencode "allows_multiple_answers=${multi}" \
    "$TG_API_BASE/bot${tok}/sendPoll")" || {
    echo "tg-poll: network error talking to Telegram" >&2
    return 1
  }
  if [ "$(jq -r '.ok' <<<"$resp")" != "true" ]; then
    echo "tg-poll: API error: $(jq -r '.description // "unknown error"' <<<"$resp")" >&2
    return 1
  fi
  jq -r '.result.poll.id' <<<"$resp"
}

main "$@"
