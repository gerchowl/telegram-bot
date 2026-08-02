# Contributing

## Dev environment

```sh
direnv allow         # auto-loads the dev shell on cd (needs nix-direnv) — preferred
nix develop          # or enter it manually
```

The shell has the CLIs + `curl jq sops age`, the Rust toolchain (`cargo rustc clippy
cargo-audit`), the formatters/linters (`nixfmt shfmt statix deadnix`), and `gitleaks`,
`prek`, `just`. No `devenv` needed — plain devShell + direnv is the whole setup.

## Tasks — `just`

```sh
just                 # list recipes
just fmt             # nix fmt (nix + shell + rust)
just check           # nix flake check (the full gate)
just build           # build the binaries
just cargo clippy    # run cargo in rust/
just audit           # cargo audit (RustSec CVEs)
just sizes           # closure size of the shipped artifact
```

`just` recipes are thin wrappers over the flake's `nix run .#…` apps and `nix` commands
— the apps (`onboard`/`send`/`bot`/`poll`/`mcp`) are the canonical entrypoints.

## Format, lint, test — all via the flake

```sh
nix fmt              # format all *.nix (nixfmt), shell (shfmt), rust (rustfmt)
nix flake check      # the full gate (see below)
```

`nix flake check` is the single source of truth and is exactly what CI runs. It covers:

- **format** (`checks.format`) — `nixfmt --check` + `shfmt -d` + `rustfmt --check`,
- **lint** (`checks.lint`) — `statix` + `deadnix`,
- **licenses** (`checks.licenses`) — asserts every dependency is free-licensed, with an SPDX report,
- **e2e** (`checks.e2e`) — the daemon/CLIs against a mock Telegram API, including the path-traversal / glob RCE regression tests,
- **e2e-onboard** (`checks.e2e-onboard`) — `tg-onboard` driving `sops`/`age` for real: the token must decrypt back byte-identical and leave no plaintext on disk,
- **docs-from-code** (`checks.docs-from-code`) — Markdown must be generated, decorator-wrapped or whitelisted.

## Security & supply-chain CI

Beyond the gate above, separate workflows run:

- **`audit.yml`** — `cargo audit` (RustSec advisory DB, blocking, on PR/push + weekly),
  `vulnix` (CVE scan of the runtime closure — weekly, informational), and
  `dependency-review` (blocks PRs adding known-vulnerable deps).
- **`secret-scan.yml`** — `gitleaks` + GitHub push-protection.
- **Dependabot** (`.github/dependabot.yml`) — weekly PRs for `cargo` deps and pinned
  GitHub Actions, plus auto security-update PRs; `update-flake-lock.yml` covers Nix inputs.

## Distribution

- **Nix users**: CI pushes built outputs to a Cachix cache (`gerchowl`) so consumers
  auto-fetch prebuilt binaries per-OS instead of compiling. Setup (one-time): create the
  cache at app.cachix.org, add a `CACHIX_AUTH_TOKEN` repo secret, and uncomment the
  `nixConfig` block in `flake.nix` with the cache's real public key. On your own machine:
  `cachix use gerchowl`.
- **Reproducibility**: each release attaches a `vendor.tar.gz` (`cargo vendor` output) so
  the Rust build stays buildable even if a crate is later yanked from crates.io.

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
