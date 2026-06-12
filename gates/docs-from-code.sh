#!/usr/bin/env bash
# guardrails(local, dogfood): docs-from-code — Markdown must be GENERATED, WRAPPED, or WHITELISTED.
#
# Every doc surface should come from the code that implements it (a --help / command / option
# generator), as close to the definition as possible. Non-generated *prose* is "gossip": it drifts
# from the implementation the moment either changes. So a prose line passes only when it is:
#   * inside a fenced code block      ``` … ```
#   * inside a generated block        <!-- generated: CMD -->  …  <!-- /generated -->
#   * inside a decorator wrap         <!-- guardrails-ok-begin [why] -->  …  <!-- guardrails-ok-end -->
#       (the "mark truly-constant prose at its home" escape — same model as the other gates)
#   * carrying a per-line escape      … <!-- guardrails-ok -->
#   * in a file/prefix listed in      guardrails-allow.txt  (the migrate-me baseline; see the
#                                     docs-from-code RFC — whitelisting is a TODO, not a blessing)
# Structural Markdown (headings, list items, tables, blockquotes, images/badges, link-only lines,
# HTML comments, blank lines) is not prose and is ignored — we gate sentences, not structure.
set -uo pipefail
allow="guardrails-allow.txt"

files=()
if [ "$#" -gt 0 ]; then
  # Explicit args are relative to the caller's cwd — do NOT cd (that would break them).
  for a in "$@"; do files+=("$a"); done
else
  # No args: discover every tracked Markdown file from the repo root.
  root="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
  cd "$root" || exit 2
  while IFS= read -r f; do files+=("$f"); done < <(git ls-files '*.md' 2>/dev/null)
  [ "${#files[@]}" -gt 0 ] || while IFS= read -r f; do files+=("$f"); done < <(find . -type f -name '*.md' 2>/dev/null)
fi

wl=()
[ -f "$allow" ] && while IFS= read -r l; do
  l="${l%%#*}"
  l="$(printf '%s' "$l" | tr -d '[:space:]')"
  [ -n "$l" ] && wl+=("$l")
done <"$allow"

whitelisted() {
  local f="${1#./}" p
  for p in "${wl[@]:-}"; do
    [ -n "$p" ] || continue
    # shellcheck disable=SC2254 — glob match on purpose (prefix/path patterns)
    case "$f" in $p*) return 0 ;; esac
  done
  return 1
}

# A "prose" line = a sentence-ish line that is not structural Markdown.
is_prose() {
  local s="${1#"${1%%[![:space:]]*}"}" # left-trim
  case "$s" in
    '' | '#'* | '-'* | '*'* | '+'* | '>'* | '|'* | '!['* | '<'* | '```'*) return 1 ;;
    '['*']:'* | 'http'*) return 1 ;;              # link reference / bare URL
    [0-9]'.'' '* | [0-9][0-9]'.'' '*) return 1 ;; # ordered list item
  esac
  # has at least two words with letters → reads as prose
  case "$s" in *[A-Za-z]*' '*[A-Za-z]*) return 0 ;; esac
  return 1
}

fails=0
for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  whitelisted "$f" && continue
  in_fence=0 in_ok=0 in_gen=0 ln=0
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln + 1))
    case "$line" in '```'*)
      in_fence=$((1 - in_fence))
      continue
      ;;
    esac
    [ "$in_fence" = 1 ] && continue
    case "$line" in
      *guardrails-ok-begin*)
        in_ok=1
        continue
        ;;
      *guardrails-ok-end*)
        in_ok=0
        continue
        ;;
      *'<!-- generated:'*)
        in_gen=1
        continue
        ;;
      *'<!-- /generated'*)
        in_gen=0
        continue
        ;;
    esac
    { [ "$in_ok" = 1 ] || [ "$in_gen" = 1 ]; } && continue
    case "$line" in *guardrails-ok*) continue ;; esac
    if is_prose "$line"; then
      echo "$f:$ln: ungoverned prose — generate it, wrap in <!-- guardrails-ok-begin/-end -->, or whitelist: ${line:0:78}"
      fails=$((fails + 1))
    fi
  done <"$f"
done

if [ "$fails" -gt 0 ]; then
  echo "docs-from-code: $fails ungoverned prose line(s) — docs must be generated, wrapped, or whitelisted." >&2
  exit 1
fi
echo "docs-from-code: ok"
