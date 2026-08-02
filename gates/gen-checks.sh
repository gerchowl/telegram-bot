#!/usr/bin/env bash
# Emit the list of `nix flake check` gates, read from the `checks` attrset in
# flake.nix. CONTRIBUTING used to describe this by hand and drifted twice: it
# advertised a shellcheck gate that left with the bash implementation (#22), and
# module evaluation that never ran at all until #37.
#
# Descriptions live next to the attr name in flake.nix as a `# doc:` comment on
# the line above, so the blurb sits at the definition rather than in prose.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

out="$(awk '
  /^        checks = \{/ { inchecks = 1; next }
  inchecks && /^        \};/ { inchecks = 0 }
  !inchecks { next }
  /# doc:/ { sub(/.*# doc:[[:space:]]*/, ""); doc = $0; next }
  # An attr at exactly 10 spaces of indent is a check name.
  /^          [a-z][a-z0-9-]* =/ {
    name = $1
    if (doc != "") { printf "- **`%s`** — %s\n", name, doc; doc = "" }
    else { printf "- **`%s`**\n", name }
  }
' flake.nix)"

# An empty list would mean the attrset shape changed and the parse silently
# stopped matching — that must fail, not render a doc claiming no gates exist.
declared="$(awk '/^        checks = \{/{i=1;next} i&&/^        \};/{i=0} i&&/^          [a-z][a-z0-9-]* =/{n++} END{print n+0}' flake.nix)"
parsed="$(printf '%s\n' "$out" | grep -c '^- ')"
if [ "$parsed" -eq 0 ] || [ "$parsed" -ne "$declared" ]; then
  echo "gen-checks: parsed $parsed of $declared checks — the attrset shape changed" >&2
  exit 2
fi
printf '%s\n' "$out"
