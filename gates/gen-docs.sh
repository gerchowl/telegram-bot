#!/usr/bin/env bash
# guardrails(local): docs-from-code — expand generated blocks in Markdown.
#
# A block looks like:
#
#   <!-- generated: tg-send --help -->
#   ...anything here is REPLACED by the command's stdout...
#   <!-- /generated -->
#
# Run with no arguments to rewrite the blocks in place; with --check to fail
# when any block is stale. The check is what stops a doc surface drifting from
# the code that implements it (the docs-from-code RFC, #23).
#
# The command is run from the repo root with its stdout captured verbatim.
# Commands come from files in this repo and are reviewed like any other code —
# this is a build step, not a sandbox.
set -uo pipefail

mode="${1:-write}"
root="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$root" || exit 2

mapfile -t files < <(git ls-files '*.md' 2>/dev/null)
[ "${#files[@]}" -gt 0 ] || exit 0

stale=0

# A guardrails or generated marker inside a fenced code block is always a bug:
# GitHub renders it as literal text, and docs-from-code.sh skips fenced lines,
# so a stray `-end` never closes its wrap — the block then silently swallows
# every following section under one unrelated reason. This is exactly how the
# first cut of the #23/#24 wrapping went wrong (a `# comment` inside a ```sh
# block was mistaken for a heading), so it is checked every run, not just under
# --check.
for f in "${files[@]}"; do
  bad="$(awk '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    fence && /<!-- (guardrails-ok|generated:|\/generated)/ { print FILENAME ":" FNR ": " $0 }
  ' "$f")"
  if [ -n "$bad" ]; then
    echo "gen-docs: marker inside a fenced code block — it will render literally and will not close its wrap:" >&2
    printf '%s\n' "$bad" >&2
    exit 2
  fi
done

for f in "${files[@]}"; do
  grep -q '<!-- generated:' "$f" || continue
  out="$(mktemp)"
  in_block=0
  cmd=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '<!-- generated:'*)
        printf '%s\n' "$line" >>"$out"
        cmd="${line#<!-- generated:}"
        cmd="${cmd%-->}"
        # shellcheck disable=SC2001
        cmd="$(printf '%s' "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        # stderr is deliberately NOT swallowed: a generator that fails needs to
        # say why, or a broken doc surface looks like an unexplained build error.
        if ! bash -c "$cmd" >>"$out"; then
          echo "gen-docs: command failed in $f: $cmd" >&2
          rm -f "$out"
          exit 2
        fi
        in_block=1
        ;;
      '<!-- /generated -->')
        printf '%s\n' "$line" >>"$out"
        in_block=0
        ;;
      *)
        [ "$in_block" -eq 1 ] || printf '%s\n' "$line" >>"$out"
        ;;
    esac
  done <"$f"

  if [ "$in_block" -eq 1 ]; then
    echo "gen-docs: unterminated <!-- generated: --> block in $f" >&2
    rm -f "$out"
    exit 2
  fi

  if cmp -s "$f" "$out"; then
    rm -f "$out"
    continue
  fi
  if [ "$mode" = "--check" ]; then
    echo "gen-docs: STALE generated block in $f — run 'just gen-docs'" >&2
    diff -u "$f" "$out" | head -40 >&2
    stale=1
    rm -f "$out"
  else
    mv "$out" "$f"
    echo "gen-docs: regenerated $f"
  fi
done

exit "$stale"
