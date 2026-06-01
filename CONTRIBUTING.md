# Contributing

## Dev environment

```sh
nix develop          # tg-send/tg-bot/tg-onboard + curl jq sops age + nixfmt shfmt statix deadnix gitleaks prek
```

## Format, lint, test — all via the flake

```sh
nix fmt              # format all *.nix (nixfmt) and shell scripts (shfmt)
nix flake check      # the full gate (see below)
```

`nix flake check` is the single source of truth and is exactly what CI runs. It covers:

- **shellcheck** on every script (build-time, via `writeShellApplication`),
- **format** (`checks.format`) — `nixfmt --check` + `shfmt -d`,
- **lint** (`checks.lint`) — `statix` + `deadnix`,
- **licenses** (`checks.licenses`) — asserts every dependency is free-licensed, with an SPDX report,
- **e2e** (`checks.e2e`) — the daemon + CLIs against a mock Telegram API, including the path-traversal / glob RCE regression tests,
- NixOS / Home-Manager module evaluation.

## Pre-commit hooks

Hooks live in `.pre-commit-config.yaml` and work with [`prek`](https://github.com/j178/prek) or `pre-commit`:

```sh
prek install         # or: pre-commit install
```

On commit: whitespace/EOF/large-file/yaml/json checks, `gitleaks` secret scan, `nixfmt`, `shfmt`.
On push: the full `nix flake check`.

## Commit messages — Conventional Commits

Releases are automated by [release-please](https://github.com/googleapis/release-please), which reads
[Conventional Commits](https://www.conventionalcommits.org/) to compute the next version and the changelog:

- `fix: …` → patch release
- `feat: …` → minor release
- `feat!: …` / `BREAKING CHANGE:` → major (pre-1.0: bumped as minor)
- `chore:`, `docs:`, `ci:`, `refactor:`, `test:` → no release on their own

release-please maintains a release PR; merging it tags `vX.Y.Z`, updates `CHANGELOG.md`, and cuts a GitHub release.

## Security

Please report vulnerabilities privately — see [SECURITY.md](SECURITY.md).
