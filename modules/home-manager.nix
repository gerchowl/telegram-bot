# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Lars Gerchow
self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    types
    mkPackageOption
    concatStringsSep
    optionalAttrs
    ;
  cfg = config.services.telegram-bot;
in
{
  options.services.telegram-bot = {
    enable = mkEnableOption "Telegram bot polling daemon (user service)";
    package = mkPackageOption self.packages.${pkgs.stdenv.hostPlatform.system} "tg-bot" {
      default = [ "tg-bot" ];
      pkgsText = "telegram-bot.packages.\${system}";
    };
    tokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to a file containing only the bot token.";
    };
    chatId = mkOption {
      type = types.nullOr (types.either types.int types.str);
      default = null;
      description = "Default chat id.";
    };
    postOnly = mkOption {
      type = types.bool;
      default = true;
      description = "Send-only when true; enable the command runner when false.";
    };
    allowedChatIds = mkOption {
      type = types.listOf (types.either types.int types.str);
      default = [ ];
      description = "Chat ids allowed to run commands (empty ⇒ none).";
    };
    commandsDir = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Directory of executable commands.";
    };
    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Extra environment variables.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !(!cfg.postOnly && cfg.allowedChatIds == [ ]);
        message = "services.telegram-bot: command mode requires a non-empty allowedChatIds.";
      }
    ];

    systemd.user.services.telegram-bot = {
      Unit = {
        Description = "Telegram bot daemon";
        After = [ "network-online.target" ];
      };
      Install.WantedBy = [ "default.target" ];
      Service = {
        ExecStart = "${cfg.package}/bin/tg-bot";
        Restart = "on-failure";
        RestartSec = 5;
        Environment =
          let
            base = {
              TELEGRAM_POST_ONLY = if cfg.postOnly then "1" else "0";
              TELEGRAM_ALLOWED_CHAT_IDS = concatStringsSep "," (map toString cfg.allowedChatIds);
            }
            // optionalAttrs (cfg.tokenFile != null) { TELEGRAM_BOT_TOKEN_FILE = toString cfg.tokenFile; }
            // optionalAttrs (cfg.commandsDir != null) { TELEGRAM_COMMANDS_DIR = toString cfg.commandsDir; }
            // optionalAttrs (cfg.chatId != null) { TELEGRAM_CHAT_ID = toString cfg.chatId; }
            // cfg.extraEnvironment;
          in
          lib.mapAttrsToList (n: v: "${n}=${v}") base;
      };
    };
  };
}
