# telegram-bot — project template

<!-- guardrails-ok-begin: scaffold guidance for a consuming project; the flake it describes is template/flake.nix -->

This project consumes the [`telegram-bot`](https://github.com/gerchowl/telegram-bot) flake.

## Setup (once)

```sh
nix develop          # tg-send / tg-onboard on PATH
tg-onboard           # walks you through BotFather, encrypts the token, finds your chat id
source ./config.env
tg-send "hello from $(hostname)"
```

`tg-onboard` writes:

- `secrets/telegram.yaml` — the **sops-encrypted** token (safe to commit)
- `.sops.yaml` — recipient rule for `secrets/*.yaml`
- `config.env` — non-secret defaults (chat id, bot username, sops file path)

## As a NixOS service

See `flake.nix` (`nixosConfigurations.example`) and the upstream README section
**"Commands & rights"** for the post-only vs command-runner model.

<!-- guardrails-ok-end -->
