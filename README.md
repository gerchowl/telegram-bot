# telegram-bot

A small, general-purpose Telegram bot you drop into any project as a **notification
and control channel**. One flake gives you:

- **`tg-onboard`** — guided first-run: walks you through BotFather, validates and
  **sops-encrypts** the token, finds your chat id (you just message the bot once),
  writes a non-secret `config.env`, and sends a test message.
- **`tg-send`** — the outbound interface other tooling calls:
  `tg-send "build done"`, `journalctl -u foo | tg-send --file -`.
- **`tg-bot`** — a long-polling daemon that receives messages and, optionally,
  runs **commands** under a strict rights model.
- **NixOS** (`services.telegram-bot`) and **Home-Manager** modules, plus a
  project **template** and a `mkSend` helper for downstream flakes.

Pure `bash` + `curl` + `jq` at the core; commands are arbitrary executables, so the
*logic* you wire up can be in any language.

> **The one manual step:** Telegram has no API to *create* a bot — you register it
> once by hand with [@BotFather](https://t.me/BotFather) in any Telegram client.
> `tg-onboard` walks you through it and automates everything after the token exists.

---

## Quick start

From inside the project you want notifications for:

```sh
nix run github:gerchowl/telegram-bot#onboard      # interactive setup, writes into $PWD
source ./config.env
nix run github:gerchowl/telegram-bot#send -- "hello from $(hostname)"
```

Or get the CLIs on your PATH:

```sh
nix profile install github:gerchowl/telegram-bot   # tg-send, tg-bot, tg-onboard
# or, per-project:
nix develop github:gerchowl/telegram-bot
```

`tg-onboard` produces, in the current directory:

| file | secret? | purpose |
|------|---------|---------|
| `secrets/telegram.yaml` | encrypted | the bot token (sops/age) — **safe to commit** |
| `.sops.yaml`            | no | recipient rule for `secrets/*.yaml` |
| `config.env`            | no | chat id, bot username, sops file path |

The age identity is created at `~/.config/sops/age/keys.txt` if you don't already
have one. Keep that file private (it decrypts the token); it is **not** in the repo.

---

## `tg-send`

```
tg-send [options] [message]
echo "message" | tg-send [options]

  -c, --chat ID         target chat (default: $TELEGRAM_CHAT_ID)
  -p, --parse-mode M    MarkdownV2 | HTML
  -s, --silent          no notification sound
  -f, --file PATH       send PATH as a document ('-' = stdin); message = caption
      --config PATH      use a specific config.env
```

**Token resolution** (highest first): `$TELEGRAM_BOT_TOKEN` → `$TELEGRAM_BOT_TOKEN_FILE`
→ `$TELEGRAM_BOT_SOPS_FILE` (decrypted on demand with `sops`).
**Chat resolution:** `--chat` → `$TELEGRAM_CHAT_ID`.
`config.env` is auto-sourced from `$TELEGRAM_BOT_CONFIG` or
`~/.config/telegram-bot/config.env`, and uses `${VAR:-default}` so explicit env vars win.

Examples:

```sh
tg-send "deploy finished ✅"
df -h | tg-send --file - --silent
tg-send -p MarkdownV2 "*alert*: disk full on \`$(hostname)\`"
```

---

## Commands & rights (the `tg-bot` daemon)

`tg-bot` long-polls Telegram. It always answers the built-ins **`/start`**, **`/id`**,
**`/help`**. Beyond that it is **safe by default**:

| mode | env | behaviour |
|------|-----|-----------|
| **post-only** (default) | `TELEGRAM_POST_ONLY=1` | never runs anything; inbound commands are refused |
| **command mode** | `TELEGRAM_POST_ONLY=0` + `TELEGRAM_ALLOWED_CHAT_IDS` + `TELEGRAM_COMMANDS_DIR` | runs `/name` → executable `name` in the commands dir, **only** for allow-listed chats |

Guarantees in command mode:

- An **empty allowlist authorizes no one** — you must opt chats in explicitly.
- Message args are passed as **separate argv** — never `eval`'d, so `/deploy; rm -rf`
  is just two literal arguments to `deploy`.
- Every command runs under `timeout` (`TELEGRAM_COMMAND_TIMEOUT`, default 60s) and
  output is truncated to Telegram's message limit.

### Adding a command

A command is just an executable in the commands dir. Whatever it prints (stdout +
stderr) is sent back. The daemon exports `TG_CHAT_ID` and `TG_COMMAND`; message words
arrive as `$1, $2, …`.

```sh
cat > commands/deploy <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
systemctl restart myapp
echo "restarted myapp ✅ (requested in chat $TG_CHAT_ID)"
EOF
chmod +x commands/deploy
```

Run the daemon locally:

```sh
source ./config.env
TELEGRAM_POST_ONLY=0 \
TELEGRAM_ALLOWED_CHAT_IDS="$TELEGRAM_CHAT_ID" \
TELEGRAM_COMMANDS_DIR="$PWD/commands" \
  tg-bot
```

Then message `/deploy` from your chat. (See `commands/ping` and `commands/status`.)

---

## NixOS service

The module takes a **`tokenFile`** path and stays agnostic about *how* it's decrypted
— pair it with [sops-nix](https://github.com/Mic92/sops-nix) or
[agenix](https://github.com/ryantm/agenix).

```nix
{
  inputs.telegram-bot.url = "github:gerchowl/telegram-bot";
  # inputs.sops-nix.url = "github:Mic92/sops-nix";

  # in your host config:
  imports = [ telegram-bot.nixosModules.default ];

  # sops-nix decrypts secrets/telegram.yaml → /run/secrets/telegram_bot_token,
  # owned by the bot user so it can read it:
  sops.secrets.telegram_bot_token = {
    sopsFile = ./secrets/telegram.yaml;
    key = "telegram_bot_token";
    owner = "telegram-bot";
  };

  # Send-only (notifications):
  services.telegram-bot = {
    enable = true;
    tokenFile = config.sops.secrets.telegram_bot_token.path;
    chatId = 123456789;
  };
}
```

Command mode, with commands defined inline (built into hardened wrapper scripts):

```nix
services.telegram-bot = {
  enable = true;
  tokenFile = config.sops.secrets.telegram_bot_token.path;
  postOnly = false;
  allowedChatIds = [ 123456789 ];
  commandRuntimeInputs = [ pkgs.systemd ];
  commands = {
    deploy = "systemctl restart myapp && echo restarted";
    logs   = "journalctl -u myapp -n 30 --no-pager";
  };
  # If a command needs to escape the sandbox (restart other units, write
  # outside the state dir), relax hardening or set extraServiceConfig:
  # hardening = false;
};
```

Other tooling on the host sends notifications by putting `tg-send` on the path
(`environment.systemPackages = [ telegram-bot.packages.${system}.tg-send ];`) — you
don't need the daemon enabled just to *send*.

### Module options (highlights)

`enable`, `tokenFile`, `chatId`, `postOnly` (default true), `allowedChatIds`,
`commands` (attr→script) / `commandsDir`, `commandRuntimeInputs`, `commandTimeout`,
`user`/`group`/`stateDir`, `environmentFile`, `extraEnvironment`, `hardening`
(default true), `extraServiceConfig`.

---

## Home-Manager

```nix
imports = [ telegram-bot.homeManagerModules.default ];
services.telegram-bot = {
  enable = true;
  tokenFile = "%r/secrets/telegram_bot_token"; # e.g. sops-nix user secret
  chatId = 123456789;
};
```

---

## Downstream `mkSend` helper

Bake a config path into a ready-to-use `tg-send` for a project's devshell:

```nix
let send = telegram-bot.lib.${system}.mkSend { configFile = ./config.env; };
in pkgs.mkShell { packages = [ send ]; };
```

---

## Layout

```
flake.nix                 packages · apps · nixos/home modules · template · lib.mkSend
scripts/lib.sh            shared: config load, token resolution, send helper
scripts/tg-onboard.sh     guided BotFather setup + sops encrypt + chat-id discovery
scripts/tg-send.sh        outbound CLI (message / document)
scripts/tg-bot.sh         long-polling daemon + command runner
modules/nixos.nix         services.telegram-bot (hardened systemd unit)
modules/home-manager.nix  user-service variant
commands/{ping,status}    example drop-in commands
template/                 `nix flake init -t` scaffold for a consuming project
```

## Security notes

- The token is the bot's password — it lives only in `secrets/telegram.yaml`
  (encrypted) and at runtime in a `tokenFile`. Never commit a plaintext token.
- Command mode executes code on your machine on receipt of a Telegram message.
  Keep `allowedChatIds` tight, set BotFather privacy mode, prefer narrow command
  scripts, and keep `hardening = true` unless a command genuinely needs more.
- `tg-onboard` reads the token with hidden input so it won't hit your shell history.
