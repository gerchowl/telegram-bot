#!/usr/bin/env bash
# Emit the module option table from the option DECLARATIONS in modules/*.nix.
#
# This is the surface that actually drifted: the README advertised a `commands`
# option that only the NixOS module implemented, and nothing caught it for
# months (#18). Reading the declarations means the table cannot claim an option
# that isn't there, or miss one that is.
#
# Parses `name = mkOption { ... description = "..."; ... }` blocks. The nix is
# nixfmt-formatted, so the shape is stable, and the parse is cross-checked
# against a looser detector below — a shape it cannot handle fails the build
# rather than silently shipping a partial table.
#
# KNOWN LIMITATION: multi-line descriptions are truncated to their first
# sentence, so qualifications living in later sentences do not reach the table
# (tokenFile's "must be readable by the service user", postOnly's "requires
# allowedChatIds", hardening's override guidance). The table is an index of
# what exists with a one-line gloss; the declaration remains the full text.
# Put the load-bearing sentence first if it must appear here.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

opts_of() { # $1 = file
  awk '
    /^    [a-zA-Z][a-zA-Z0-9]* = mkOption \{/ {
      name = $1; desc = ""; def = ""; depth = 1; next
    }
    # Multi-line description = '"''"' ... '"''"'; — take its first sentence.
    name != "" && indesc {
      if ($0 ~ /^      '"''"';/) { indesc = 0; next }
      # Accumulate until the first sentence ends, so a description wrapped
      # across lines is not cut mid-clause.
      if (desc !~ /\.$/) {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        sub(/[[:space:]]+$/, "", line)
        if (line != "") desc = (desc == "" ? line : desc " " line)
        if (desc ~ /\. /) sub(/\. .*$/, ".", desc)
      }
      next
    }
    name != "" {
      if ($0 ~ /description = '"''"'[[:space:]]*$/) { indesc = 1; next }
      if ($0 ~ /description = /) {
        line = $0
        sub(/.*description = "?/, "", line)
        sub(/";?[[:space:]]*$/, "", line)
        if (line != "") desc = line
      }
      if ($0 ~ /^      default = /) {
        line = $0
        sub(/^      default = /, "", line)
        sub(/;[[:space:]]*$/, "", line)
        def = line
      }
      if ($0 ~ /^    \};/) {
        if (desc != "") printf "%s\t%s\t%s\n", name, def, desc
        name = ""
      }
    }
  ' "$1"
}

# mkEnableOption / mkPackageOption declare options too, but with a different
# shape; name them explicitly so the table is complete.
emit() { # $1 = file, $2 = label
  # Fail loudly rather than emitting an empty table. If a nixfmt reflow or a new
  # way of declaring options breaks the parse, the generated doc must not
  # quietly become "this module has two options" while the gate stays green.
  local declared parsed
  # Deliberately LOOSER than the parser: it must notice shapes the parser
  # cannot handle (lib.mkOption, a missing description) rather than agreeing
  # with it by construction.
  declared="$(grep -cE '^    [a-zA-Z][a-zA-Z0-9]* = (lib\.)?mkOption' "$1")"
  parsed="$(opts_of "$1" | wc -l | tr -d ' ')"
  if [ "$parsed" -ne "$declared" ]; then
    echo "gen-module-options: parsed $parsed of $declared mkOption blocks in $1 —" \
      "the declaration shape changed; fix the parser rather than shipping a partial table" >&2
    exit 2
  fi
  echo "**\`$2\`**"
  echo
  echo '| option | default | description |'
  echo '|--------|---------|-------------|'
  # enable/package are declared with mkEnableOption / mkPackageOption, whose
  # shape the mkOption parser doesn't cover. Confirm each is actually declared
  # before claiming it exists — a row for an option that isn't there is worse
  # than a missing row, because a reader will try to set it.
  if grep -q 'enable = mkEnableOption' "$1"; then
    printf '| `enable` | `false` | %s |\n' \
      "$(sed -n 's/.*mkEnableOption "\(.*\)";.*/\1/p' "$1" | head -1)"
  else
    echo "gen-module-options: no mkEnableOption in $1" >&2
    exit 2
  fi
  if grep -q 'package = mkPackageOption' "$1"; then
    printf '| `package` | `%s` | Package providing `bin/tg-bot`. |\n' \
      "$(sed -n 's/.*mkPackageOption [^ ]* "\([^"]*\)".*/\1/p' "$1" | head -1)"
  else
    echo "gen-module-options: no mkPackageOption in $1" >&2
    exit 2
  fi
  opts_of "$1" | while IFS=$'\t' read -r n d desc; do
    [ -n "$d" ] || d="—"
    printf '| `%s` | `%s` | %s |\n' "$n" "$d" "$desc"
  done
  echo
}

emit modules/nixos.nix "services.telegram-bot (NixOS)"
emit modules/home-manager.nix "services.telegram-bot (Home-Manager)"
