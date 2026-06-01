# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Lars Gerchow
{
  description = "A general-purpose Telegram bot for projects: guided onboarding, a tg-send CLI, and a NixOS/Home-Manager service with a safe command runner.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    let
      inherit (nixpkgs) lib;
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        libSh = builtins.readFile ./scripts/lib.sh;

        # Each CLI = shared lib.sh ++ its own script, wrapped so curl/jq/sops/age
        # are always on PATH. writeShellApplication runs shellcheck at build time.
        mkTool =
          {
            name,
            src,
            runtimeInputs ? [ ],
          }:
          pkgs.writeShellApplication {
            inherit name;
            runtimeInputs = runtimeInputs ++ [
              pkgs.curl
              pkgs.jq
              pkgs.coreutils
            ];
            text = libSh + "\n" + builtins.readFile src;
            meta = {
              mainProgram = name;
              license = lib.licenses.mit;
            };
          };

        tg-send = mkTool {
          name = "tg-send";
          src = ./scripts/tg-send.sh;
          runtimeInputs = [ pkgs.sops ];
        };
        tg-bot = mkTool {
          name = "tg-bot";
          src = ./scripts/tg-bot.sh;
          runtimeInputs = [
            pkgs.sops
            pkgs.findutils
          ];
        };
        tg-onboard = mkTool {
          name = "tg-onboard";
          src = ./scripts/tg-onboard.sh;
          runtimeInputs = [
            pkgs.sops
            pkgs.age
          ];
        };

        telegram-bot = pkgs.symlinkJoin {
          name = "telegram-bot";
          paths = [
            tg-send
            tg-bot
            tg-onboard
          ];
          meta = {
            description = "tg-send, tg-bot and tg-onboard in one package";
            license = lib.licenses.mit;
          };
        };

        # ---- v2: compiled Rust implementation of tg-send + tg-bot ----
        # Drop-in compatible with the bash versions (same env contract, flags,
        # rights model). A single ~small binary per tool, no curl/jq/sops/age in
        # the runtime closure. tg-onboard stays bash (interactive sops/age glue).
        telegram-bot-rs = pkgs.rustPlatform.buildRustPackage {
          pname = "telegram-bot-rs";
          version = "0.1.0";
          src = ./rust;
          cargoLock.lockFile = ./rust/Cargo.lock;
          nativeBuildInputs = [ pkgs.pkg-config ];
          buildInputs = [ pkgs.openssl ]; # for native-tls (openssl-sys)
          meta = {
            description = "Rust (v2) implementation of tg-send + tg-bot";
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
        shFiles = "scripts/*.sh tests/*.sh commands/ping commands/status";

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
      in
      {
        packages = {
          inherit
            tg-send
            tg-bot
            tg-onboard
            telegram-bot
            telegram-bot-rs
            ;
          default = telegram-bot;
        };

        apps = {
          onboard = {
            type = "app";
            program = "${tg-onboard}/bin/tg-onboard";
          };
          send = {
            type = "app";
            program = "${tg-send}/bin/tg-send";
          };
          bot = {
            type = "app";
            program = "${tg-bot}/bin/tg-bot";
          };
          default = self.apps.${system}.onboard;
        };

        # Building the tools = running shellcheck on every script, so this is a
        # real check. `e2e` runs the scripts against a localhost mock Telegram API.
        checks = {
          inherit tg-send tg-bot tg-onboard;
          format = checkFormat;
          lint = checkLint;
          licenses = checkLicenses;
          e2e =
            pkgs.runCommand "telegram-bot-e2e"
              {
                nativeBuildInputs = [
                  tg-send
                  tg-bot
                  pkgs.python3
                  pkgs.curl
                  pkgs.jq
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
          # Same hermetic suite, but with the Rust binaries on PATH — proves the
          # v2 implementation is behaviourally identical. Note: no curl/jq here.
          e2e-rs =
            pkgs.runCommand "telegram-bot-e2e-rs"
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
        };

        formatter = treefmt;

        devShells.default = pkgs.mkShell {
          packages = [
            tg-send
            tg-bot
            tg-onboard
            pkgs.curl
            pkgs.jq
            pkgs.sops
            pkgs.age
            pkgs.shellcheck
            pkgs.gitleaks
            pkgs.prek
          ]
          ++ fmtInputs
          ++ lintInputs;
          shellHook = ''
            echo "telegram-bot devshell — 'tg-onboard' to set up · 'nix fmt' · 'nix flake check' · 'prek install'."
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
              runtimeInputs = [ tg-send ];
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
