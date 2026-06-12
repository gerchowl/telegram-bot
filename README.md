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
*logic* you wire up can be in any language. A compiled **Rust implementation (v2)**
of `tg-send`/`tg-bot` is also available — identical behaviour, ~⅓ the runtime closure
(see [Rust implementation](#rust-implementation-v2)).

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
- Command **names are restricted to `[A-Za-z0-9_-]`** and resolved only inside the
  commands dir — a name with `/`, `.` or whitespace is rejected, so a message can't
  path-traverse to an executable elsewhere on disk.
- Message args are split into **separate argv with no glob/pathname expansion** and
  are never `eval`'d — `/deploy; rm -rf /` and `/ping *` are passed literally.
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

### The `/` menu (auto-registered)

Give a command a `# desc:` line and `tg-bot` registers the Telegram **`/` autocomplete
menu** for you on startup (Bot API `setMyCommands`) — no manual BotFather `/setcommands`:

```sh
#!/usr/bin/env bash
# desc: restart myapp
set -euo pipefail
systemctl restart myapp && echo "restarted ✅"
```

Only commands with a `# desc:` are listed; names must be Telegram-valid (`[a-z0-9_]`,
≤32 chars). Set `TELEGRAM_SET_COMMANDS=0` to opt out (e.g. if you manage the menu by hand).

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

## Rust implementation (v2)

`tg-send` and `tg-bot` also exist as a single compiled Rust crate (`rust/`),
built by the flake as `packages.telegram-bot-rs`. It is **drop-in compatible** —
same flags, same env contract, same rights model — and runs the *same* e2e suite
(`checks.e2e-rs`), so behaviour is identical (the security regression tests pass
against it too).

Why it exists: the bash tools pull `curl`/`jq`/`sops`/`age`/coreutils into the
runtime closure (~123 MB for `tg-bot` alone). The Rust binaries are ~1 MB each
with a **~48 MB closure** (glibc + openssl), and ship as standalone binaries you
can `scp` anywhere. Because there's no shell, the glob/word-split/eval bug classes
can't occur — arguments go straight to `argv` via `std::process::Command`.

Use it:

```sh
nix run .#telegram-bot-rs -- ...        # tg-send / tg-bot binaries
nix profile install .#telegram-bot-rs
```

In the NixOS module, just point `package` at it (the unit runs `${package}/bin/tg-bot`):

```nix
services.telegram-bot = {
  enable = true;
  package = telegram-bot.packages.${system}.telegram-bot-rs; # Rust daemon
  tokenFile = config.sops.secrets.telegram_bot_token.path;
};
```

`tg-onboard` stays bash (one-time interactive sops/age setup) — run it once, then
the Rust daemon/sender consume the same `config.env` / `tokenFile`. The bash tools
remain the default; the Rust build is opt-in until it's had more mileage.

Could shrink further (rustls instead of native-tls drops openssl; musl static for a
fully self-contained binary) — noted as future tuning.

---

## Layout

```
flake.nix                 packages · apps · nixos/home modules · template · lib.mkSend
rust/                     v2: compiled tg-send + tg-bot (Cargo crate, buildRustPackage)
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

> **⚠️ Command mode runs commands on your host in response to Telegram messages.**
> Anyone who controls an allow-listed chat — or who obtains your bot token — can run
> those commands as the bot's user. You alone decide which commands to expose and to
> whom. Provided "as is", without warranty (see [LICENSE](LICENSE)). Keep
> `postOnly = true` unless you understand and accept this. Full threat model in
> [SECURITY.md](SECURITY.md).

- The token is the bot's password — it lives only in `secrets/telegram.yaml`
  (encrypted) and at runtime in a `tokenFile`. Never commit a plaintext token.
  Telegram's API puts the token in the request URL, so keep `curl -v` / proxy /
  `strace` traces private.
- Command mode executes code on your machine on receipt of a Telegram message.
  Keep `allowedChatIds` tight, set BotFather privacy mode, prefer narrow command
  scripts, and keep `hardening = true` unless a command genuinely needs more.
- `tg-onboard` reads the token with hidden input so it won't hit your shell history.

## Privacy

- The bot receives whatever users send it (message text, sender/chat metadata) and
  forwards command output back through Telegram. **Message content is processed in
  memory and not written to disk** — only the Telegram update offset is persisted
  under the state dir. Note that stderr/journal logs include chat ids (and rejected
  command names), so journal access means metadata access.
- All messages transit **Telegram's servers** and are subject to
  [Telegram's Privacy Policy](https://telegram.org/privacy). If you process other
  people's messages you may be a data controller — keep `allowedChatIds` tight and
  enable BotFather privacy mode so the bot only sees commands addressed to it.

## License & trademark

MIT — see [LICENSE](LICENSE). Not affiliated with or endorsed by Telegram.
"Telegram" is a trademark of Telegram Messenger Inc.; used here descriptively to
identify the API this tool talks to. You, the bot operator, are responsible for
compliance with [Telegram's Bot Terms](https://telegram.org/tos).
