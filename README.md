# telegram-bot

<!-- guardrails-ok-begin: what the project is and the one manual BotFather step — intent, not derivable from code -->

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

<!-- guardrails-ok-end -->

## Quick start

<!-- guardrails-ok-begin: onboarding narrative; the commands are in fenced blocks -->

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

<!-- guardrails-ok-end -->

## `tg-send`

<!-- guardrails-ok-begin: resolution-order explanation; the usage block is the arg parser's own text -->

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

<!-- guardrails-ok-end -->

## `tg-poll`

<!-- guardrails-ok-begin: why polls default to non-anonymous — a Telegram API constraint -->

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

<!-- guardrails-ok-end -->

## Commands & rights (the `tg-bot` daemon)

<!-- guardrails-ok-begin: the rights model and its rationale — the security contract this project exists to state -->

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

**Don't leave background processes holding the pipe.** A command runs in its own
process group, and anything still holding its stdout/stderr shortly after it
exits gets the group reaped. A bare `some-service &` is therefore killed a
couple of seconds later. That is deliberate — a grandchild holding the pipe used
to stop the daemon polling *permanently* (#47) — and the daemon logs when it
happens.

Redirect the background job's output and it keeps running:

```sh
nohup some-service >/var/log/some-service.log 2>&1 &
```

It is still in the command's process group, so if the *command* hits
`TELEGRAM_COMMAND_TIMEOUT` the whole group is killed, background job included.
For anything that must outlive the command regardless, hand it to a real
supervisor (a launchd agent or systemd unit) instead of backgrounding it here.

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

<!-- guardrails-ok-end -->

## NixOS service

<!-- guardrails-ok-begin: deployment guidance and secret-management pairing; the option table below is generated -->

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

### Module options

<!-- generated: bash gates/gen-module-options.sh -->
**`services.telegram-bot (NixOS)`**

| option | default | description |
|--------|---------|-------------|
| `enable` | `false` | Telegram bot polling daemon (tg-bot) |
| `package` | `telegram-bot-rs` | Package providing `bin/tg-bot`. |
| `tokenFile` | `null` | Path to a file containing **only** the bot token. |
| `chatId` | `null` | Default chat id used by tg-send / built-in replies. |
| `postOnly` | `true` | When true the bot only sends messages and answers built-ins (/start, /id, /help); all inbound commands are refused. |
| `allowedChatIds` | `[ ]` | Chat ids permitted to run commands. Empty ⇒ nobody is authorized. |
| `commands` | `{ }` | Map of command name → shell script body. Each becomes /name. |
| `commandsDir` | `null` | Alternative to {option}`commands`: a directory of executables. Ignored if `commands` is set. |
| `commandRuntimeInputs` | `[ ]` | Packages available on PATH to scripts defined via {option}`commands`. |
| `commandTimeout` | `60` | Per-command timeout in seconds. |
| `user` | `"telegram-bot"` | User the daemon runs as. |
| `group` | `"telegram-bot"` | Group the daemon runs as. |
| `stateDir` | `"/var/lib/telegram-bot"` | Where the long-poll offset is persisted. |
| `environmentFile` | `null` | Extra EnvironmentFile (e.g. for TELEGRAM_BOT_TOKEN directly instead of tokenFile). |
| `extraEnvironment` | `{ }` | Extra environment variables for the service. |
| `hardening` | `true` | Apply a strict systemd sandbox. |
| `extraServiceConfig` | `{ }` | Merged into systemd serviceConfig (wins over defaults). |

**`services.telegram-bot (Home-Manager)`**

| option | default | description |
|--------|---------|-------------|
| `enable` | `false` | Telegram bot polling daemon (user service) |
| `package` | `telegram-bot-rs` | Package providing `bin/tg-bot`. |
| `tokenFile` | `null` | Path to a file containing only the bot token. |
| `chatId` | `null` | Default chat id. |
| `postOnly` | `true` | Send-only when true; enable the command runner when false. |
| `allowedChatIds` | `[ ]` | Chat ids allowed to run commands (empty ⇒ none). |
| `commands` | `{ }` | Map of command name → shell script body. Each becomes /name. |
| `commandsDir` | `null` | Alternative to {option}`commands`: a directory of executables. Ignored if `commands` is set. |
| `commandRuntimeInputs` | `[ ]` | Packages available on PATH to scripts defined via {option}`commands`. |
| `commandTimeout` | `60` | Per-command timeout in seconds. |
| `extraEnvironment` | `{ }` | Extra environment variables. |
| `logDir` | `null` | darwin only: directory for the agent's stdout/stderr logs. |

<!-- /generated -->

---

<!-- guardrails-ok-end -->

## Home-Manager

<!-- guardrails-ok-begin: platform differences and why logDir exists — launchd has no journal -->

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

<!-- guardrails-ok-end -->

## Downstream `mkSend` helper

<!-- guardrails-ok-begin: usage note for the lib helper -->

Bake a config path into a ready-to-use `tg-send` for a project's devshell:

```nix
let send = telegram-bot.lib.${system}.mkSend { configFile = ./config.env; };
in pkgs.mkShell { packages = [ send ]; };
```

---

<!-- guardrails-ok-end -->

## Implementation

<!-- guardrails-ok-begin: why bash was removed and what the closure costs — history, not state -->

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
server that gives an agent (Claude Code, etc.) three tools over Telegram: **`notify`**
(one-way status update), **`send_file`** (one-way file — a chart, screenshot, log,
PDF) and **`ask`** (blocking question with one-tap inline-button options, routed back
to the waiting agent). Exposed as the `mcp` flake app:

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

#### Central mode is authenticated

The TCP transport requires a shared secret. Set the same value on the daemon and
on every remote client:

```sh
TG_MCP_LISTEN=100.x.y.z:8765  TG_MCP_TOKEN=…   # daemon
TG_MCP_REMOTE=100.x.y.z:8765  TG_MCP_TOKEN=…   # client
```

Two things fail closed rather than degrading quietly, because the consequence
is a daemon that can message you as you:

- **`TG_MCP_LISTEN` without `TG_MCP_TOKEN`** — the TCP listener does not open.
- **A bind address that is not a Tailscale address or loopback** — `0.0.0.0`,
  `::` or a LAN IP is refused. A typo here would otherwise put the port on
  every interface, silently.

In both cases the Unix socket keeps working, so local agents are unaffected.

Be clear about what the token is and isn't. It is **defence in depth against a
mis-set ACL or a node you admit to the tailnet later** — Tailscale falls back to
allow-all on an empty policy file. It is **not** a defence against a compromised
fleet node: that machine has the token and the network position both. Restrict
reachability with Tailscale ACLs as well; the token is the second lock, not the
first. The Unix socket stays unauthenticated — filesystem permissions already
bound it to you, and a second copy of the secret would only be one more thing
to leak.

#### `ask` and the human on the other end

Every `ask` carries a `via` footer showing where the daemon saw the request come
from — `local`, or the peer address. It is derived from the socket, not from the
request, so an agent cannot claim to be somewhere it isn't.

Asks phrased around irreversible actions (`--force`, `rm -rf`, `drop table`,
`push to main`, `deploy prod`, …) are sent **without buttons** and require a
typed reply. This is not about authentication: a coding agent ingests issue
text, dependency READMEs and web pages, any of which can carry a prompt
injection, and an injected agent on a fully authorised host can phrase a
plausible question. The button label is what people actually read on a
lockscreen. For actions that cannot be undone, the friction is the point.

Every string the message renders is scanned — question, options, default and
recommendation — not just the question. Checking only the question left the
obvious hole: `"Proceed?"` with a `"Force push to main"` button.

**Treat this as a speed bump, not a boundary.** It is a denylist, so a
determined injection can word around it, and it deliberately errs toward
friction — a benign question mentioning production loses its buttons, which
costs you one typed reply. It catches the careless and the obvious. The real
control is not making irreversible actions reachable by a single tap.

#### Sending files

`send_file` takes a `path`, an optional one-line `caption`, and `inline` (default
false) to render an image as a photo instead of a file attachment — photos are
re-encoded and downscaled, so the default preserves the bytes.

The **client** reads the file and ships the bytes to the daemon, not the path:
in central mode the daemon is on another host across the tailnet, where a
client-side path means nothing. Files over Telegram's 50 MB bot cap are refused.

Set **`TG_MCP_MEDIA_ROOT`** to confine what the client will read; unset means any
readable path. Unrestricted is the sensible default here — unlike the bot's
command runner, this daemon acts for an agent that already reads your filesystem
and could paste a file's contents into `notify`. Set the root when you want the
daemon's reach bounded anyway, so a stray or manipulated path can't quietly turn
one chat into a file-exfiltration channel. Paths are resolved with `canonicalize`,
so symlinks pointing out of the root are rejected.

---

<!-- guardrails-ok-end -->

## Layout

<!-- generated: bash gates/gen-layout.sh -->
```
flake.nix                  packages · apps · nixos/home modules · template · lib.mkSend
justfile                   task runner — 'just' lists recipes
rust/src/lib.rs            shared: config load, token resolution, Telegram client
rust/src/bin/tg-send.rs    outbound CLI (message / document)
rust/src/bin/tg-bot.rs     long-polling daemon + command runner
rust/src/bin/tg-poll.rs    send a poll, print its id
rust/src/bin/tg-onboard.rs guided BotFather setup + sops encrypt + chat-id discovery
rust/src/bin/tg-mcp.rs     MCP server + reply-routing daemon
modules/nixos.nix          services.telegram-bot (hardened systemd unit)
modules/home-manager.nix   user-service variant (systemd on Linux, launchd on darwin)
commands/                  example drop-in commands (2 of them)
gates/                     repo-local guardrails (docs-from-code, doc generators)
tests/                     hermetic e2e suites + mock Telegram API
template/                  `nix flake init -t` scaffold for a consuming project
```
<!-- /generated -->

## Security notes

<!-- guardrails-ok-begin: operator-facing threat statement; deliberately hand-written and reviewed -->

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

<!-- guardrails-ok-end -->

## Privacy

<!-- guardrails-ok-begin: statement of what the software does with user data -->

- The bot receives whatever users send it (message text, sender/chat metadata) and
  forwards command output back through Telegram. **Message content is processed in
  memory and not written to disk** — only the Telegram update offset is persisted
  under the state dir. Note that stderr/journal logs include chat ids (and rejected
  command names), so journal access means metadata access.
- All messages transit **Telegram's servers** and are subject to
  [Telegram's Privacy Policy](https://telegram.org/privacy). If you process other
  people's messages you may be a data controller — keep `allowedChatIds` tight and
  enable BotFather privacy mode so the bot only sees commands addressed to it.

<!-- guardrails-ok-end -->

## License & trademark

<!-- guardrails-ok-begin: legal text -->

MIT — see [LICENSE](LICENSE). Not affiliated with or endorsed by Telegram.
"Telegram" is a trademark of Telegram Messenger Inc.; used here descriptively to
identify the API this tool talks to. You, the bot operator, are responsible for
compliance with [Telegram's Bot Terms](https://telegram.org/tos).

<!-- guardrails-ok-end -->
