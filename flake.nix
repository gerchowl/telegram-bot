# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Lars Gerchow
{
  description = "A general-purpose Telegram bot for projects: guided onboarding, a tg-send CLI, and a NixOS/Home-Manager service with a safe command runner.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      lib = nixpkgs.lib;
    in
    flake-utils.lib.eachDefaultSystem
      (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        libSh = builtins.readFile ./scripts/lib.sh;

        # Each CLI = shared lib.sh ++ its own script, wrapped so curl/jq/sops/age
        # are always on PATH. writeShellApplication runs shellcheck at build time.
        mkTool = { name, src, runtimeInputs ? [ ] }:
          pkgs.writeShellApplication {
            inherit name;
            runtimeInputs = runtimeInputs ++ [ pkgs.curl pkgs.jq pkgs.coreutils ];
            text = libSh + "\n" + builtins.readFile src;
            meta = { mainProgram = name; license = lib.licenses.mit; };
          };

        tg-send = mkTool {
          name = "tg-send";
          src = ./scripts/tg-send.sh;
          runtimeInputs = [ pkgs.sops ];
        };
        tg-bot = mkTool {
          name = "tg-bot";
          src = ./scripts/tg-bot.sh;
          runtimeInputs = [ pkgs.sops pkgs.findutils ];
        };
        tg-onboard = mkTool {
          name = "tg-onboard";
          src = ./scripts/tg-onboard.sh;
          runtimeInputs = [ pkgs.sops pkgs.age ];
        };

        telegram-bot = pkgs.symlinkJoin {
          name = "telegram-bot";
          paths = [ tg-send tg-bot tg-onboard ];
          meta = {
            description = "tg-send, tg-bot and tg-onboard in one package";
            license = lib.licenses.mit;
          };
        };
      in
      {
        packages = {
          inherit tg-send tg-bot tg-onboard telegram-bot;
          default = telegram-bot;
        };

        apps = {
          onboard = { type = "app"; program = "${tg-onboard}/bin/tg-onboard"; };
          send = { type = "app"; program = "${tg-send}/bin/tg-send"; };
          bot = { type = "app"; program = "${tg-bot}/bin/tg-bot"; };
          default = self.apps.${system}.onboard;
        };

        # Building the tools = running shellcheck on every script, so this is a
        # real check. `e2e` runs the scripts against a localhost mock Telegram API.
        checks = {
          inherit tg-send tg-bot tg-onboard;
          e2e = pkgs.runCommand "telegram-bot-e2e"
            {
              nativeBuildInputs = [
                tg-send tg-bot pkgs.python3 pkgs.curl pkgs.jq
                pkgs.coreutils pkgs.gnugrep pkgs.bash
              ];
              TGB_COMMANDS = ./commands;
              TGB_MOCK = ./tests/mock.py;
            } ''
            bash ${./tests/e2e.sh}
            touch "$out"
          '';
        };

        devShells.default = pkgs.mkShell {
          packages = [ tg-send tg-bot tg-onboard pkgs.curl pkgs.jq pkgs.sops pkgs.age pkgs.shellcheck ];
          shellHook = ''
            echo "telegram-bot devshell — run 'tg-onboard' to set up, then 'source ./config.env'."
          '';
        };

        # Helper for downstream flakes: a tg-send pre-bound to a config file.
        #   telegram-bot.lib.${system}.mkSend { configFile = ./config.env; }
        lib = {
          mkSend = { configFile ? null, chatId ? null, name ? "tg-send" }:
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
      })
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
