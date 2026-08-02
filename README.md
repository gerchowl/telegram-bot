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
- **`tg-poll`** — send a poll and print its id, so `poll_answer` updates can be
  mapped back to what was asked.
- **NixOS** (`services.telegram-bot`) and **Home-Manager** modules, plus a
  project **template** and a `mkSend` helper for downstream flakes.

Compiled Rust, shipped as small binaries with no `curl`/`jq` in the runtime
closure. Commands are arbitrary executables, so the *logic* you wire up can
still be in any language.

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
nix profile install github:gerchowl/telegram-bot   # tg-send, tg-bot, tg-poll, tg-onboard, tg-mcp
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

## `tg-poll`

```
tg-poll [options] "Question" "Option 1" "Option 2" [...]

  -c, --chat ID     target chat (default: $TELEGRAM_CHAT_ID)
  -m, --multi       allow multiple answers
      --anonymous   anonymous poll (no voter; can't be tracked)
      --config PATH use a specific config.env
```

Prints the poll id on stdout. Token/chat resolution matches `tg-send`; 2–10
options. Polls are **non-anonymous by default** — Telegram only reports a voter
for non-anonymous polls, so anonymous polls can't be mapped back to a person:

```sh
id=$(tg-poll "Deploy to prod?" "yes" "no")
```

Record the answers by dropping a `_poll_answer` hook in the commands dir; the
daemon invokes it with `$POLL_ID`, `$POLL_VOTER` and `$POLL_OPTIONS`.

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

### Sentinels: formatting and attachments

A command can control how its reply is sent by emitting `\x01key=value` lines at
the **very start** of stdout. They are stripped before sending, and only a
contiguous run at the start counts — so nothing later in the output can inject one.

| sentinel | effect |
|----------|--------|
| `\x01parse_mode=MarkdownV2` \| `HTML` | render the reply (or caption) as formatted text |
| `\x01document=PATH` | upload `PATH` as a file attachment; remaining stdout becomes the caption |
| `\x01photo=PATH` | same, but rendered inline as an image (Telegram re-encodes it) |

```sh
cat > commands/report <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
generate-report > /var/lib/telegram-bot/media/report.pdf
printf '\001document=/var/lib/telegram-bot/media/report.pdf\n'
echo "nightly report ✅"
EOF
```

**Attachments are opt-in.** They do nothing unless `TELEGRAM_MEDIA_ROOT` is set,
and the path must resolve (after following symlinks) inside that root — otherwise
the upload is refused, the reason is appended to the reply, and the command's own
output is still delivered.

That root is not a defence against a *hostile* command — one already runs
arbitrary code as the bot user and could simply `cat` a file to stdout. It bounds
a **buggy** one: a script that interpolates a Telegram-supplied argument into a
path would otherwise turn `/report ../../etc/shadow` into an arbitrary-file read.
Keep the root a directory the bot owns and writes into.

Files over Telegram's 50 MB bot-upload cap are refused, as are non-regular files
(a FIFO would otherwise block the daemon on `open`). If a key repeats, the first
occurrence wins. Use `document` unless you specifically want inline rendering —
`photo` re-encodes and downscales.

### The `/` menu and `/help` (auto-registered)

Give a command a `# desc:` line and `tg-bot` registers the Telegram **`/` autocomplete
menu** for you on startup (Bot API `setMyCommands`) — no manual BotFather `/setcommands`:

```sh
#!/usr/bin/env bash
# desc: restart myapp
set -euo pipefail
systemctl restart myapp && echo "restarted ✅"
```

The same `# desc:` is what `/help` prints, so the two can't disagree:

```
Custom commands:
  /deploy — restart myapp
  /ping   — liveness check
  /status — report host status (uptime, load, disk)
```

Names must be Telegram-valid (`[a-z0-9_]`, ≤32 chars) and `_`-prefixed files are
hooks (`_poll_answer`), not commands — neither surface lists them. A command with
no `# desc:` still appears in `/help` but is left out of the `/` menu, which
requires a description per entry. Set `TELEGRAM_SET_COMMANDS=0` to opt out of the
menu (e.g. if you manage it by hand); `/help` is unaffected.

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

Other tooling on the host sends notifications by putting the package on the path
(`environment.systemPackages = [ telegram-bot.packages.${system}.default ];`) — you
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

Works on **Linux and darwin** from the same config: a `systemd.user` unit on
Linux, a `launchd` agent on darwin. The options are identical — `commands`,
`commandsDir`, `commandRuntimeInputs`, `commandTimeout`, `postOnly`,
`allowedChatIds`, `extraEnvironment` — so a config moves between hosts
unchanged.

`logDir` is darwin-only: launchd has no journal, so the agent's stdout/stderr
go to `~/Library/Logs/telegram-bot{,.err}.log` unless you point it elsewhere.
On Linux use `journalctl --user -u telegram-bot`.

---

## Downstream `mkSend` helper

Bake a config path into a ready-to-use `tg-send` for a project's devshell:

```nix
let send = telegram-bot.lib.${system}.mkSend { configFile = ./config.env; };
in pkgs.mkShell { packages = [ send ]; };
```

---

## Implementation

Every tool is one compiled Rust crate (`rust/`), built by the flake as
`packages.telegram-bot-rs` — also `packages.default`, and `packages.telegram-bot`
for consumers using the historical attr name.

A bash implementation shipped alongside it until 0.2.0. It was removed once the
Rust build reached parity: two implementations meant writing every feature twice
and letting them drift. The tools pulled `curl`/`jq`/`sops`/`age`/coreutils into
the runtime closure (162 MB); the binaries are ~1 MB each with a **52 MB closure**,
and `scp` anywhere. With no shell, the glob/word-split/eval bug classes can't
occur — arguments go straight to `argv` via `std::process::Command`.

`tg-onboard` still invokes `sops` and `age-keygen`, but as your own tools rather
than a wrapped closure; install them if you use the guided setup.

Use it:

```sh
nix run github:gerchowl/telegram-bot#send -- "hello"
nix profile install github:gerchowl/telegram-bot
```

Could shrink further (musl static for a fully self-contained binary) — noted as
future tuning.

### MCP bridge (`tg-mcp`)

The Rust crate also ships `tg-mcp` — a [Model Context Protocol](https://modelcontextprotocol.io)
server that gives an agent (Claude Code, etc.) two tools over Telegram: **`notify`**
(one-way status update) and **`ask`** (blocking question with one-tap inline-button
options, routed back to the waiting agent). Exposed as the `mcp` flake app:

```sh
nix run github:gerchowl/telegram-bot#mcp            # stdio MCP client (for an agent)
nix run github:gerchowl/telegram-bot#mcp -- daemon  # the central poll/route daemon
```

Two modes, one binary:

- **daemon** (`tg-mcp daemon`) — owns the single Telegram `getUpdates` long-poll and
  routes each answer back to the agent that asked. Bound to **one chat**, resolved
  once at startup from `TG_CHAT_ID` or the config's `TELEGRAM_CHAT_ID`. Listens on a
  local Unix socket (`TG_MCP_SOCK`, default `${XDG_RUNTIME_DIR:-~/.config/telegram-bot}/tg-mcp.sock`)
  and, if `TG_MCP_LISTEN=<addr:port>` is set, a TCP socket for remote agents over a
  tailnet.
- **client** (no args) — the stdio MCP server an agent spawns; forwards `notify`/`ask`
  to the daemon over the local socket, or over TCP when `TG_MCP_REMOTE=<addr:port>` is
  set. The chat is the daemon's, not the client's — run one daemon per target chat and
  point each project's client at the right one (give each daemon a distinct
  `TG_MCP_LISTEN` port **and** `TG_MCP_SOCK` so they don't collide).

Register it for Claude Code as an `mcpServers` entry (`~/.claude.json` for user scope,
or a project `.mcp.json`):

```json
{ "mcpServers": { "tg": {
  "type": "stdio",
  "command": "nix",
  "args": ["run", "github:gerchowl/telegram-bot#mcp"],
  "env": { "TG_MCP_REMOTE": "100.x.y.z:8765" }
} } }
```

---

## Layout

```
flake.nix                 packages · apps · nixos/home modules · template · lib.mkSend
rust/src/lib.rs           shared: config load, token resolution, Telegram client
rust/src/bin/tg-onboard   guided BotFather setup + sops encrypt + chat-id discovery
rust/src/bin/tg-send      outbound CLI (message / document)
rust/src/bin/tg-bot       long-polling daemon + command runner
rust/src/bin/tg-poll      send a poll, print its id
rust/src/bin/tg-mcp       MCP server + reply-routing daemon
modules/nixos.nix         services.telegram-bot (hardened systemd unit)
modules/home-manager.nix  user-service variant
commands/{ping,status}    example drop-in commands
gates/                    repo-local guardrails (docs-from-code)
tests/                    hermetic e2e suites + mock Telegram API
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
