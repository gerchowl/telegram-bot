# Security Policy

## Threat model

`telegram-bot` is **send-only by default** (`postOnly = true` / `TELEGRAM_POST_ONLY=1`)
and runs no inbound code. Opt-in **command mode** executes executables on the host
in response to Telegram messages. In that mode the trust boundary is:

- **The bot token** — anyone holding it controls the bot. Keep it in an encrypted
  sops/age secret or a `tokenFile` readable only by the service user. Never commit
  a plaintext token. Rotate it via [@BotFather](https://t.me/BotFather) if leaked.
- **`allowedChatIds`** — every allow-listed chat can run every command in the
  commands dir. An empty allowlist authorizes no one (enforced by a module assertion).
- **The commands you define** — they run with the daemon's privileges. Scope them
  narrowly, keep the systemd `hardening = true` sandbox on, and prefer least privilege.

## Built-in mitigations

- Command **names are restricted to `[A-Za-z0-9_-]`** and resolved only inside the
  commands dir — a name containing `/`, `.`, or whitespace is rejected, so a message
  cannot path-traverse to an executable elsewhere on disk.
- Command **arguments are split into separate argv with no glob/pathname expansion
  and are never `eval`'d** — `/deploy; rm -rf /` and `/ping *` are passed literally.
- Every command runs under **`timeout`** and its output is **truncated** to Telegram's
  message limit.
- The NixOS service ships a **strict systemd sandbox** by default
  (`NoNewPrivileges`, `ProtectSystem=strict`, `SystemCallFilter=@system-service`, …).

## Reporting a vulnerability

Please report security issues privately via GitHub Security Advisories
("Report a vulnerability" on the repository's **Security** tab) rather than opening a
public issue.

## No warranty

This software is provided "as is", without warranty of any kind — see
[LICENSE](LICENSE). Operating a bot, especially in command mode, is at your own risk;
you are responsible for its configuration and for compliance with
[Telegram's Bot Terms](https://telegram.org/tos).
