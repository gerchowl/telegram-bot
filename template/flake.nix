# SPDX-License-Identifier: MIT
{
  description = "A project using the telegram-bot flake for notifications / control.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    telegram-bot.url = "github:gerchowl/telegram-bot"; # ← point at this repo
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      telegram-bot,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        # `nix develop` gives you tg-send / tg-poll / tg-onboard on PATH.
        # sops + age are what tg-onboard shells out to during setup.
        devShells.default = pkgs.mkShell {
          packages = [
            telegram-bot.packages.${system}.default
            pkgs.sops
            pkgs.age
          ];
          shellHook = ''
            [ -f ./config.env ] && source ./config.env
            echo "Run 'tg-onboard' once, then 'tg-send \"hello\"'."
          '';
        };
      }
    )
    // {
      # Example NixOS host using the bot as a service. See README "Commands & rights".
      nixosConfigurations.example = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          telegram-bot.nixosModules.default
          (_: {
            # sops-nix (or agenix) decrypts secrets/telegram.yaml to this path:
            # sops.secrets."telegram_bot_token" = { owner = "telegram-bot"; };
            services.telegram-bot = {
              enable = true;
              tokenFile = "/run/secrets/telegram_bot_token";
              chatId = 123456789;
              postOnly = true; # send-only; flip to false + add allowedChatIds for commands
            };
          })
        ];
      };
    };
}
