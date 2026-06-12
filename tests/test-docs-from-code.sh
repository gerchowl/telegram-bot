#!/usr/bin/env bash
# Self-test for gates/docs-from-code.sh — proves it complains on ungoverned prose and
# passes when the prose is generated / decorator-wrapped / whitelisted.
set -uo pipefail
GATE="${1:?path to docs-from-code.sh}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cd "$T" || exit 2
: >guardrails-allow.txt
fail=0
check() { # $1=label $2=expected-rc  (gate run on $T/*.md)
  bash "$GATE" ./*.md >/dev/null 2>&1
  local rc=$?
  if [ "$rc" = "$2" ]; then echo "  PASS: $1"; else
    echo "  FAIL: $1 (rc=$rc want $2)"
    fail=1
  fi
}

# 1. bare prose → complain (rc 1)
printf '# Title\n\nThis sentence is ungoverned prose that drifts.\n' >doc.md
check "ungoverned prose fails" 1

# 2. structural-only (heading + list + fenced code) → ok (rc 0)
printf '# Title\n\n- a bullet\n\n```sh\necho generated\n```\n' >doc.md
check "structure + code-fence passes" 0

# 3. decorator-wrapped constant prose → ok
printf '# Title\n<!-- guardrails-ok-begin license boilerplate -->\nMIT licensed, constant text.\n<!-- guardrails-ok-end -->\n' >doc.md
check "wrapped constant prose passes" 0

# 4. generated block → ok
printf '# Title\n<!-- generated: tg-send --help -->\nUSAGE: tg-send ...\n<!-- /generated -->\n' >doc.md
check "generated block passes" 0

# 5. whitelisted file → ok even with prose
printf 'legacy.md\n' >guardrails-allow.txt
printf '# Title\n\nLegacy ungoverned prose, baselined.\n' >legacy.md
bash "$GATE" legacy.md >/dev/null 2>&1 && echo "  PASS: whitelisted file passes" || {
  echo "  FAIL: whitelisted file should pass"
  fail=1
}

[ "$fail" = 0 ] && echo "test-docs-from-code: ok" || {
  echo "test-docs-from-code: FAILED" >&2
  exit 1
}
