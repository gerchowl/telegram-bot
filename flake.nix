# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Lars Gerchow
{
  description = "A general-purpose Telegram bot for projects: guided onboarding, a tg-send CLI, and a NixOS/Home-Manager service with a safe command runner.";

  # To let downstream flakes AUTO-FETCH prebuilt outputs from the Cachix cache
  # instead of compiling, create the cache, then uncomment and paste its real
  # public key (shown at app.cachix.org when the cache is created):
  #   nixConfig = {
  #     extra-substituters = [ "https://gerchowl.cachix.org" ];
  #     extra-trusted-public-keys = [ "gerchowl.cachix.org-1:PASTE_REAL_KEY=" ];
  #   };
  # (For your own machine you can instead run once: `cachix use gerchowl`.)

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    guardrails.url = "github:gerchowl/guardrails";
    # Only used by checks.modules, to evaluate the Home-Manager module (#37).
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      guardrails,
      home-manager,
    }:
    let
      inherit (nixpkgs) lib;
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # ---- the implementation: compiled Rust (#22) ----
        # tg-send, tg-bot, tg-poll, tg-onboard and tg-mcp as small binaries with
        # no curl/jq in the runtime closure. tg-onboard still invokes sops and
        # age-keygen, but as the user's own tools rather than a shipped closure.
        telegram-bot-rs = pkgs.rustPlatform.buildRustPackage {
          pname = "telegram-bot-rs";
          version = "0.1.0";
          src = ./rust;
          cargoLock.lockFile = ./rust/Cargo.lock;
          # rustls + webpki-roots: pure-Rust TLS, no openssl-sys/pkg-config needed (see #26).
          meta = {
            description = "Telegram bot: tg-send, tg-bot, tg-poll, tg-onboard, tg-mcp";
            license = lib.licenses.mit;
            mainProgram = "tg-send";
          };
        };

        # ---- formatting / lint / license tooling (shared by `nix fmt` + checks) ----
        fmtInputs = [
          pkgs.nixfmt-rfc-style
          pkgs.shfmt
          pkgs.rustfmt
          pkgs.findutils
        ];
        lintInputs = [
          pkgs.statix
          pkgs.deadnix
        ];
        shfmtFlags = "-i 2 -ci";
        # The implementation is Rust; the shell that remains is test harnesses,
        # gates and the example commands.
        shFiles = "tests/*.sh gates/*.sh commands/ping commands/status";

        treefmt = pkgs.writeShellApplication {
          name = "fmt";
          runtimeInputs = fmtInputs;
          text = ''
            mapfile -t nixf < <(find . -name '*.nix' -not -path './.git/*')
            [ "''${#nixf[@]}" -gt 0 ] && nixfmt "''${nixf[@]}"
            shfmt -w ${shfmtFlags} ${shFiles}
            mapfile -t rsf < <(find rust -name '*.rs')
            [ "''${#rsf[@]}" -gt 0 ] && rustfmt --edition 2021 "''${rsf[@]}"
          '';
        };

        checkFormat = pkgs.runCommand "check-format" { nativeBuildInputs = fmtInputs; } ''
          cd ${self}
          mapfile -t nixf < <(find . -name '*.nix' -not -path './.git/*')
          nixfmt --check "''${nixf[@]}"
          shfmt -d ${shfmtFlags} ${shFiles}
          rustfmt --edition 2021 --check $(find rust -name '*.rs')
          touch "$out"
        '';

        checkLint = pkgs.runCommand "check-lint" { nativeBuildInputs = lintInputs; } ''
          cd ${self}
          statix check .
          deadnix --fail flake.nix modules/nixos.nix modules/home-manager.nix
          touch "$out"
        '';

        # Assert every package we build on / ship is free-licensed, and emit an
        # SPDX report. Guards against a future dependency with an unfree license.
        checkLicenses =
          let
            used = {
              inherit (pkgs)
                curl
                jq
                coreutils
                findutils
                gnugrep
                bash
                sops
                age
                shellcheck
                python3
                nixfmt-rfc-style
                shfmt
                statix
                deadnix
                ;
            };
            licsOf =
              p:
              let
                l = p.meta.license or [ ];
              in
              if builtins.isList l then l else [ l ];
            idOf = l: l.spdxId or l.shortName or "unknown";
            freeOf = p: builtins.all (l: l.free or false) (licsOf p);
            row =
              name: p:
              "${if freeOf p then "free   " else "NONFREE"}  ${name}: "
              + lib.concatStringsSep ", " (map idOf (licsOf p));
            report = lib.concatStringsSep "\n" (lib.mapAttrsToList row used);
            allFree = builtins.all freeOf (builtins.attrValues used);
          in
          pkgs.runCommand "check-licenses" { inherit report; } ''
            printf '%s\n' "$report" | tee "$out"
            ${lib.optionalString (
              !allFree
            ) ''echo "ERROR: a non-free dependency license was detected" >&2; exit 1''}
          '';
        # Nothing else instantiates the modules, so a dangling package attr or a
        # broken option would ship green — that is how the bash removal nearly
        # left services.telegram-bot.package pointing at a deleted derivation
        # (#37). Evaluate both modules and assert on what consumers depend on.
        # The Home-Manager module is evaluated for BOTH platforms regardless of
        # the host, so the darwin launchd branch is covered from Linux CI too.
        #
        # Scope: this asserts on the config the modules PRODUCE. Home-Manager
        # rewrites ProgramArguments (wrapping it in wait4path) before writing
        # the plist, so a regression inside Home-Manager's own wrapping is out
        # of range — as is whether launchd actually accepts the job.
        checkModules =
          let
            common = {
              services.telegram-bot = {
                enable = true;
                tokenFile = "/run/secrets/tg";
                chatId = 42;
                postOnly = false;
                allowedChatIds = [ 42 ];
                commands.hello = "echo hi";
              };
            };
            nixosSvc =
              (nixpkgs.lib.nixosSystem {
                system = "x86_64-linux";
                modules = [
                  self.nixosModules.telegram-bot
                  common
                  {
                    boot.loader.grub.devices = [ "nodev" ];
                    fileSystems."/" = {
                      device = "/dev/null";
                      fsType = "ext4";
                    };
                    system.stateVersion = "24.05";
                  }
                ];
              }).config.systemd.services.telegram-bot;
            hmFor =
              sys:
              (home-manager.lib.homeManagerConfiguration {
                pkgs = nixpkgs.legacyPackages.${sys};
                modules = [
                  self.homeManagerModules.telegram-bot
                  common
                  {
                    home = {
                      username = "test";
                      homeDirectory =
                        if nixpkgs.legacyPackages.${sys}.stdenv.hostPlatform.isDarwin then "/Users/test" else "/home/test";
                      stateVersion = "24.05";
                      # home-manager tracks master while nixpkgs is pinned by
                      # the lock; the mismatch warning is noise here.
                      enableNixpkgsReleaseCheck = false;
                    };
                  }
                ];
              }).config;
            hmLinux = hmFor "x86_64-linux";
            hmDarwin = hmFor "aarch64-darwin";
            linuxSvc = hmLinux.systemd.user.services.telegram-bot;
            darwinAgent = hmDarwin.launchd.agents.telegram-bot.config;
            # These strings reference store paths for foreign systems. This
            # check asserts on how the modules EVALUATE, so drop the context —
            # keeping it would make the derivation depend on building an
            # x86_64-linux package, which no darwin runner can do.
            noCtx = builtins.unsafeDiscardStringContext;
            # ExecStart / ProgramArguments come back as a string from one module
            # and a single-element list from the other; normalise both.
            asStr = v: noCtx (if builtins.isList v then lib.concatStringsSep " " v else v);
          in
          pkgs.runCommand "telegram-bot-modules"
            {
              nixosExec = asStr nixosSvc.serviceConfig.ExecStart;
              nixosCommands = asStr nixosSvc.environment.TELEGRAM_COMMANDS_DIR;
              hmLinuxExec = asStr linuxSvc.Service.ExecStart;
              hmLinuxEnv = asStr linuxSvc.Service.Environment;
              hmLinuxHasAgent = lib.boolToString (hmLinux.launchd.agents ? telegram-bot);
              hmDarwinExec = asStr darwinAgent.ProgramArguments;
              hmDarwinCommands = asStr darwinAgent.EnvironmentVariables.TELEGRAM_COMMANDS_DIR;
              hmDarwinOut = asStr darwinAgent.StandardOutPath;
              hmDarwinKeepAlive = lib.boolToString darwinAgent.KeepAlive.SuccessfulExit;
              hmDarwinRunAtLoad = lib.boolToString darwinAgent.RunAtLoad;
              hmDarwinThrottle = toString darwinAgent.ThrottleInterval;
              hmDarwinToken = asStr darwinAgent.EnvironmentVariables.TELEGRAM_BOT_TOKEN_FILE;
              hmDarwinHasUnit = lib.boolToString (hmDarwin.systemd.user.services ? telegram-bot);
            }
            ''
              fail=0
              chk() { # name expected-suffix actual
                case "$3" in
                  *$2) echo "  PASS: $1" ;;
                  *) echo "  FAIL: $1 — got '$3', want *$2"; fail=1 ;;
                esac
              }
              eq() { if [ "$3" = "$2" ]; then echo "  PASS: $1"; else echo "  FAIL: $1 — got '$3', want '$2'"; fail=1; fi; }
              has() { # name substring actual
                case "$3" in
                  *$2*) echo "  PASS: $1" ;;
                  *) echo "  FAIL: $1 — got '$3', want to contain '$2'"; fail=1 ;;
                esac
              }

              echo "== NixOS module =="
              chk "ExecStart is the shipped tg-bot" "/bin/tg-bot" "$nixosExec"
              chk "commands attrset builds a commands dir" "telegram-bot-commands" "$nixosCommands"

              echo "== Home-Manager on linux =="
              chk "systemd unit ExecStart" "/bin/tg-bot" "$hmLinuxExec"
              has "commands attrset reaches the unit" "TELEGRAM_COMMANDS_DIR=/nix/store" "$hmLinuxEnv"
              has "command timeout reaches the unit" "TELEGRAM_COMMAND_TIMEOUT=60" "$hmLinuxEnv"
              has "allowlist reaches the unit" "TELEGRAM_ALLOWED_CHAT_IDS=42" "$hmLinuxEnv"
              eq "no launchd agent on linux" "false" "$hmLinuxHasAgent"

              echo "== Home-Manager on darwin =="
              chk "launchd runs the shipped tg-bot" "/bin/tg-bot" "$hmDarwinExec"
              chk "commands attrset reaches the agent" "telegram-bot-commands" "$hmDarwinCommands"
              chk "stdout is captured to a log" "/telegram-bot.log" "$hmDarwinOut"
              eq "restarts only on failure" "false" "$hmDarwinKeepAlive"
              eq "starts at load" "true" "$hmDarwinRunAtLoad"
              eq "respawn is throttled" "5" "$hmDarwinThrottle"
              eq "tokenFile reaches the agent" "/run/secrets/tg" "$hmDarwinToken"
              eq "no systemd unit on darwin" "false" "$hmDarwinHasUnit"

              [ "$fail" -eq 0 ] || { echo "module checks FAILED"; exit 1; }
              echo "all module checks passed"
              touch "$out"
            '';

      in
      {
        packages = {
          inherit telegram-bot-rs;
          # Historical attr name, kept so existing consumers keep resolving.
          telegram-bot = telegram-bot-rs;
          # The compiled implementation is the artifact (#22): `nix run
          # github:gerchowl/telegram-bot#send` and friends resolve to binaries,
          # not a curl/jq/sops shell closure.
          default = telegram-bot-rs;
        };

        apps = {
          onboard = {
            type = "app";
            program = "${telegram-bot-rs}/bin/tg-onboard";
          };
          send = {
            type = "app";
            program = "${telegram-bot-rs}/bin/tg-send";
          };
          bot = {
            type = "app";
            program = "${telegram-bot-rs}/bin/tg-bot";
          };
          poll = {
            type = "app";
            program = "${telegram-bot-rs}/bin/tg-poll";
          };
          # MCP bridge (notify/ask) for Claude Code & other agents. No args =
          # stdio client of a daemon (via TG_MCP_REMOTE or the local socket);
          # `-- daemon` runs the central poll/route daemon. Rust-only.
          mcp = {
            type = "app";
            program = "${telegram-bot-rs}/bin/tg-mcp";
          };
          default = self.apps.${system}.onboard;
        };

        checks = {
          # doc: both modules are evaluated (NixOS + Home-Manager on each platform) and asserted on
          modules = checkModules;
          # doc: `nixfmt --check` + `shfmt -d` + `rustfmt --check`
          format = checkFormat;
          # doc: `statix` + `deadnix`
          lint = checkLint;
          # doc: every dependency is free-licensed, with an SPDX report
          licenses = checkLicenses;
          # The hermetic suite, run against the binaries via a localhost mock
          # Telegram API. No curl/jq in the closure.
          # doc: the daemon and CLIs against a mock Telegram API, incl. the path-traversal / glob RCE regression tests
          e2e =
            pkgs.runCommand "telegram-bot-e2e"
              {
                nativeBuildInputs = [
                  telegram-bot-rs
                  pkgs.python3
                  pkgs.coreutils
                  pkgs.gnugrep
                  pkgs.bash
                ];
                TGB_COMMANDS = ./commands;
                TGB_MOCK = ./tests/mock.py;
              }
              ''
                bash ${./tests/e2e.sh}
                touch "$out"
              '';
          # tg-mcp had no coverage at all; send_file puts file bytes on that
          # path, so this runs a real daemon over a Unix socket with a real
          # stdio client against the mock API — the two-process split an agent
          # uses, including central mode where the daemon is on another host.
          e2e-mcp =
            pkgs.runCommand "telegram-bot-e2e-mcp"
              {
                nativeBuildInputs = [
                  telegram-bot-rs
                  pkgs.python3
                  pkgs.coreutils
                  pkgs.gnugrep
                  pkgs.bash
                ];
                TGB_MOCK = ./tests/mock.py;
              }
              ''
                bash ${./tests/e2e-mcp.sh}
                touch "$out"
              '';
          # tg-onboard drives sops/age for real against the mock API: the token it
          # encrypts must decrypt back byte-identical, and no plaintext may be
          # left on disk. Rust-only — onboarding is interactive, so the suite
          # feeds every answer on stdin.
          # doc: `tg-onboard` driving `sops`/`age` for real — the token must decrypt back byte-identical and leave no plaintext behind
          e2e-onboard =
            pkgs.runCommand "telegram-bot-e2e-onboard"
              {
                nativeBuildInputs = [
                  telegram-bot-rs
                  pkgs.sops
                  pkgs.age
                  pkgs.python3
                  pkgs.coreutils
                  pkgs.gnugrep
                  pkgs.bash
                ];
                TGB_MOCK = ./tests/mock.py;
              }
              ''
                bash ${./tests/e2e-onboard.sh}
                touch "$out"
              '';
          # guardrails(local, dogfood): every Markdown surface must be generated, decorator-wrapped,
          # or whitelisted in guardrails-allow.txt — no hand-prose that silently drifts from the
          # code. Also runs the gate's own self-test (it must complain on prose, pass on wrapped).
          # doc: Markdown must be generated, decorator-wrapped or whitelisted, and generated blocks must be current
          docs-from-code =
            pkgs.runCommand "telegram-bot-docs-from-code"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.findutils
                  pkgs.gnused
                  pkgs.gnugrep
                  pkgs.gawk
                  pkgs.diffutils
                  pkgs.git
                ];
              }
              ''
                cp -r --no-preserve=mode ${./.} src
                cd src
                bash gates/docs-from-code.sh
                bash tests/test-docs-from-code.sh "$PWD/gates/docs-from-code.sh"
                # Generated blocks must be current: regenerating must be a no-op.
                # Without this the <!-- generated --> markers would be decoration
                # and the content could drift exactly like hand-prose.
                bash gates/gen-docs.sh --check
                touch "$out"
              '';
        };

        formatter = treefmt;

        devShells.default = guardrails.lib.${system}.mkDevShell {
          inherit pkgs;
          name = "telegram-bot-dev";
          extra = [
            telegram-bot-rs
            pkgs.curl
            pkgs.jq
            pkgs.sops
            pkgs.age
            pkgs.shellcheck
            pkgs.gitleaks
            pkgs.prek
            pkgs.just
            # Rust toolchain for the v2 crate (rust/)
            pkgs.cargo
            pkgs.rustc
            pkgs.clippy
            pkgs.cargo-audit
          ]
          ++ fmtInputs
          ++ lintInputs;
          hook = ''
            echo "telegram-bot devshell — 'just' for tasks · 'nix fmt' · 'nix flake check' · 'prek install'."
          '';
        };

        # Helper for downstream flakes: a tg-send pre-bound to a config file.
        #   telegram-bot.lib.${system}.mkSend { configFile = ./config.env; }
        lib = {
          mkSend =
            {
              configFile ? null,
              chatId ? null,
              name ? "tg-send",
            }:
            pkgs.writeShellApplication {
              inherit name;
              runtimeInputs = [ telegram-bot-rs ];
              text = ''
                ${lib.optionalString (configFile != null) ''export TELEGRAM_BOT_CONFIG="${toString configFile}"''}
                ${lib.optionalString (chatId != null) ''export TELEGRAM_CHAT_ID="${toString chatId}"''}
                exec tg-send "$@"
              '';
            };
        };
      }
    )
    // {
      nixosModules.telegram-bot = import ./modules/nixos.nix self;
      nixosModules.default = self.nixosModules.telegram-bot;
      homeManagerModules.telegram-bot = import ./modules/home-manager.nix self;
      homeManagerModules.default = self.homeManagerModules.telegram-bot;

      templates.default = {
        path = ./template;
        description = "A project wired up with the telegram-bot flake (devshell + NixOS service example).";
      };
      templates.project = self.templates.default;
    };
}
