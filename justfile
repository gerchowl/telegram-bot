# Task runner for telegram-bot. `just` lists recipes.
# Tools come from the dev shell — use direnv (`direnv allow`) or `nix develop`.

# list recipes
default:
    @just --list

# format nix + shell + rust sources
fmt:
    nix fmt

# full gate: shellcheck · format · lint · licenses · e2e (bash+rust) · modules
check:
    nix flake check -L

# guided first-run setup (BotFather → sops → chat id)
onboard:
    nix run .#onboard

# send a message via the bash CLI, e.g. `just send "hello"`
send *ARGS:
    nix run .#send -- {{ ARGS }}

# run the bash daemon
bot:
    nix run .#bot

# build the Rust v2 binaries (tg-send, tg-bot) and show them
build-rs:
    nix build .#telegram-bot-rs && ls -l result/bin

# run cargo in the Rust crate, e.g. `just cargo build --release` or `just cargo clippy`
cargo *ARGS:
    cd rust && cargo {{ ARGS }}

# vendor crate sources (what the per-release tarball archives)
vendor:
    cd rust && cargo vendor

# audit Rust deps against the RustSec advisory DB
audit:
    cd rust && cargo audit

# runtime closure sizes: rust v2 vs bash daemon
sizes:
    nix path-info -Sh .#telegram-bot-rs .#tg-bot
