# Task runner for telegram-bot. `just` lists recipes.
# Tools come from the dev shell — use direnv (`direnv allow`) or `nix develop`.

# list recipes
default:
    @just --list

# format nix + shell + rust sources
fmt:
    nix fmt

# full gate: format · lint · licenses · e2e · e2e-onboard · docs-from-code
check:
    nix flake check -L

# guided first-run setup (BotFather → sops → chat id)
onboard:
    nix run .#onboard

# send a message, e.g. `just send "hello"`
send *ARGS:
    nix run .#send -- {{ ARGS }}

# send a poll; prints the poll id, e.g. `just poll "Deploy?" yes no`
poll *ARGS:
    nix run .#poll -- {{ ARGS }}

# run the polling daemon
bot:
    nix run .#bot

# build the binaries and show them
build:
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

# runtime closure size of the shipped artifact
sizes:
    nix path-info -Sh .#telegram-bot-rs
