# shellcheck shell=bash
# tg-send — push a message (or file) to Telegram. The outbound interface other
# tooling uses: `tg-send "build done"`, `journalctl -u foo | tg-send --file -`.

usage() {
  cat >&2 <<'EOF'
tg-send — send a Telegram message or document.

USAGE:
  tg-send [options] [message]
  echo "message" | tg-send [options]

OPTIONS:
  -c, --chat ID         Target chat id (default: $TELEGRAM_CHAT_ID)
  -p, --parse-mode M    MarkdownV2 | HTML  (default: plain text)
  -s, --silent          Send without a notification sound
  -f, --file PATH       Send PATH as a document ('-' for stdin); message becomes the caption
      --config PATH      Use this config.env instead of the default
  -h, --help            Show this help

TOKEN / CHAT resolution (highest precedence first):
  token: $TELEGRAM_BOT_TOKEN > $TELEGRAM_BOT_TOKEN_FILE > $TELEGRAM_BOT_SOPS_FILE
  chat:  --chat > $TELEGRAM_CHAT_ID
A config.env (written by tg-onboard) is auto-sourced from
$TELEGRAM_BOT_CONFIG or ${XDG_CONFIG_HOME:-~/.config}/telegram-bot/config.env.
EOF
}

main() {
  local chat="" parse_mode="" silent=0 file="" config="" message=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -c|--chat)       chat="$2"; shift 2;;
      -p|--parse-mode) parse_mode="$2"; shift 2;;
      -s|--silent)     silent=1; shift;;
      -f|--file)       file="$2"; shift 2;;
      --config)        config="$2"; shift 2;;
      -h|--help)       usage; return 0;;
      --)              shift; break;;
      -*)              echo "tg-send: unknown option: $1" >&2; usage; return 2;;
      *)               break;;
    esac
  done

  tg_load_config "$config"
  [ -n "$chat" ] || chat="${TELEGRAM_CHAT_ID:-}"

  # Remaining args (or stdin) form the message / caption.
  if [ "$#" -gt 0 ]; then
    message="$*"
  elif [ -z "$file" ] && [ ! -t 0 ]; then
    message="$(cat)"
  elif [ -n "$file" ] && [ ! -t 0 ] && [ "$file" != "-" ] && [ "$#" -eq 0 ]; then
    : # caption optional for files; leave empty
  fi

  if [ -n "$file" ]; then
    send_document "$chat" "$file" "$message" "$parse_mode" "$silent"
  else
    if [ -z "$message" ]; then
      echo "tg-send: nothing to send (pass a message argument or pipe via stdin)" >&2
      return 2
    fi
    tg_send_message "$chat" "$message" "$parse_mode" "$silent"
  fi
}

send_document() {
  local chat="$1" file="$2" caption="$3" parse_mode="$4" silent="$5" tok resp
  tok="$(tg_resolve_token)" || return $?
  [ -n "$chat" ] || { echo "tg-send: no chat id" >&2; return 2; }

  local args=(--silent --show-error --max-time 120 -F "chat_id=${chat}")
  if [ "$file" = "-" ]; then
    args+=(-F "document=@-;filename=stdin.txt")
  else
    [ -f "$file" ] || { echo "tg-send: no such file: $file" >&2; return 2; }
    args+=(-F "document=@${file}")
  fi
  [ -n "$caption" ] && args+=(-F "caption=${caption}")
  [ -n "$parse_mode" ] && args+=(-F "parse_mode=${parse_mode}")
  [ "$silent" = 1 ] && args+=(-F "disable_notification=true")

  resp="$(curl "${args[@]}" "$TG_API_BASE/bot${tok}/sendDocument")" || {
    echo "tg-send: network error" >&2; return 1; }
  if [ "$(jq -r '.ok' <<<"$resp")" != "true" ]; then
    echo "tg-send: API error: $(jq -r '.description // "unknown error"' <<<"$resp")" >&2
    return 1
  fi
}

main "$@"
