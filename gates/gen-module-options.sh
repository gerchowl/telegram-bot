#!/usr/bin/env bash
# Emit the module option table from the option DECLARATIONS in modules/*.nix.
#
# This is the surface that actually drifted: the README advertised a `commands`
# option that only the NixOS module implemented, and nothing caught it for
# months (#18). Reading the declarations means the table cannot claim an option
# that isn't there, or miss one that is.
#
# Parses `name = mkOption { ... description = "..."; ... }` blocks. The nix is
# nixfmt-formatted, so the shape is stable; a malformed block yields no row
# rather than a wrong one.
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
  echo "**\`$2\`**"
  echo
  echo '| option | default | description |'
  echo '|--------|---------|-------------|'
  echo '| `enable` | `false` | Enable the daemon. |'
  echo '| `package` | the flake'"'"'s `telegram-bot-rs` | Package providing `bin/tg-bot`. |'
  opts_of "$1" | while IFS=$'\t' read -r n d desc; do
    [ -n "$d" ] || d="—"
    printf '| `%s` | `%s` | %s |\n' "$n" "$d" "$desc"
  done
  echo
}

emit modules/nixos.nix "services.telegram-bot (NixOS)"
emit modules/home-manager.nix "services.telegram-bot (Home-Manager)"
