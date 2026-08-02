#!/usr/bin/env bash
# Emit the repo layout table from the tracked file list, so it can't go stale
# the way it did when scripts/ was deleted (#22) and the README kept listing it.
# One line per entry, with a hand-kept blurb looked up by path prefix — the
# PATHS come from git, the descriptions are the only prose here.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

blurb() {
  case "$1" in
    flake.nix) echo "packages · apps · nixos/home modules · template · lib.mkSend" ;;
    justfile) echo "task runner — 'just' lists recipes" ;;
    rust/src/lib.rs) echo "shared: config load, token resolution, Telegram client" ;;
    rust/src/bin/tg-send.rs) echo "outbound CLI (message / document)" ;;
    rust/src/bin/tg-bot.rs) echo "long-polling daemon + command runner" ;;
    rust/src/bin/tg-poll.rs) echo "send a poll, print its id" ;;
    rust/src/bin/tg-onboard.rs) echo "guided BotFather setup + sops encrypt + chat-id discovery" ;;
    rust/src/bin/tg-mcp.rs) echo "MCP server + reply-routing daemon" ;;
    modules/nixos.nix) echo "services.telegram-bot (hardened systemd unit)" ;;
    modules/home-manager.nix) echo "user-service variant (systemd on Linux, launchd on darwin)" ;;
    *) echo "" ;;
  esac
}

echo '```'
for f in flake.nix justfile rust/src/lib.rs \
  rust/src/bin/tg-send.rs rust/src/bin/tg-bot.rs rust/src/bin/tg-poll.rs \
  rust/src/bin/tg-onboard.rs rust/src/bin/tg-mcp.rs \
  modules/nixos.nix modules/home-manager.nix; do
  git ls-files --error-unmatch "$f" >/dev/null 2>&1 || continue
  printf '%-26s %s\n' "$f" "$(blurb "$f")"
done
# Directories, described by what they hold rather than enumerated file by file.
printf '%-26s %s\n' "commands/" "example drop-in commands ($(git ls-files 'commands/*' | wc -l | tr -d ' ') of them)"
printf '%-26s %s\n' "gates/" "repo-local guardrails (docs-from-code, doc generators)"
printf '%-26s %s\n' "tests/" "hermetic e2e suites + mock Telegram API"
printf '%-26s %s\n' "template/" "\`nix flake init -t\` scaffold for a consuming project"
echo '```'
