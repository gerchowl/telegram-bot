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
    mapAttrsToList
    concatStringsSep
    optionalAttrs
    ;
  cfg = config.services.telegram-bot;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  logDir = if cfg.logDir != null then cfg.logDir else "${config.home.homeDirectory}/Library/Logs";

  # Build a commands directory from the `commands` attrset, if given. Mirrors
  # modules/nixos.nix so a config can move between the two modules unchanged.
  builtCommandsDir =
    if cfg.commands != { } then
      pkgs.linkFarm "telegram-bot-commands" (
        mapAttrsToList (name: script: {
          inherit name;
          # Point straight at the executable; tg-bot runs `$dir/$name` directly.
          path = "${
            pkgs.writeShellApplication {
              inherit name;
              runtimeInputs = cfg.commandRuntimeInputs;
              text = script;
            }
          }/bin/${name}";
        }) cfg.commands
      )
    else
      null;

  commandsDir =
    if builtCommandsDir != null then
      builtCommandsDir
    else if cfg.commandsDir != null then
      cfg.commandsDir
    else
      null;

  # One environment mapping, rendered as a K=V list for systemd and as an
  # attrset for launchd's EnvironmentVariables.
  envAttrs = {
    TELEGRAM_POST_ONLY = if cfg.postOnly then "1" else "0";
    TELEGRAM_ALLOWED_CHAT_IDS = concatStringsSep "," (map toString cfg.allowedChatIds);
    TELEGRAM_COMMAND_TIMEOUT = toString cfg.commandTimeout;
  }
  // optionalAttrs (cfg.tokenFile != null) { TELEGRAM_BOT_TOKEN_FILE = toString cfg.tokenFile; }
  // optionalAttrs (commandsDir != null) { TELEGRAM_COMMANDS_DIR = toString commandsDir; }
  // optionalAttrs (cfg.chatId != null) { TELEGRAM_CHAT_ID = toString cfg.chatId; }
  // cfg.extraEnvironment;
in
{
  options.services.telegram-bot = {
    enable = mkEnableOption "Telegram bot polling daemon (user service)";
    package = mkPackageOption self.packages.${pkgs.stdenv.hostPlatform.system} "telegram-bot-rs" {
      default = [ "telegram-bot-rs" ];
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
    commands = mkOption {
      type = types.attrsOf types.lines;
      default = { };
      example = lib.literalExpression ''
        {
          deploy = "systemctl --user restart myapp && echo restarted";
          logs = "journalctl --user -u myapp -n 30 --no-pager";
        }
      '';
      description = "Map of command name → shell script body. Each becomes /name.";
    };

    commandsDir = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Alternative to {option}`commands`: a directory of executables. Ignored if `commands` is set.";
    };

    commandRuntimeInputs = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Packages available on PATH to scripts defined via {option}`commands`.";
    };

    commandTimeout = mkOption {
      type = types.int;
      default = 60;
      description = "Per-command timeout in seconds.";
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Extra environment variables.";
    };

    logDir = mkOption {
      type = types.nullOr types.str;
      default = null;
      defaultText = lib.literalExpression ''"''${config.home.homeDirectory}/Library/Logs"'';
      description = ''
        darwin only: directory for the agent's stdout/stderr logs. launchd has
        no journal, so without this the daemon's output is discarded.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !(!cfg.postOnly && cfg.allowedChatIds == [ ]);
        message = "services.telegram-bot: command mode requires a non-empty allowedChatIds.";
      }
    ];

    # Linux gets a systemd user unit; darwin a launchd agent. Same options
    # either way — a consumer's config moves between hosts unchanged. Before
    # this, the module emitted only systemd.user, so on darwin `enable = true`
    # silently did nothing and consumers hand-rolled launchd.agents (#17).
    systemd.user.services = mkIf (!isDarwin) {
      telegram-bot = {
        # No network-online.target ordering: it isn't meaningful for user
        # services, and the daemon already retries on network errors anyway.
        Unit.Description = "Telegram bot daemon";
        Install.WantedBy = [ "default.target" ];
        Service = {
          ExecStart = "${cfg.package}/bin/tg-bot";
          Restart = "on-failure";
          RestartSec = 5;
          Environment = mapAttrsToList (n: v: "${n}=${v}") envAttrs;
        };
      };
    };

    launchd.agents = mkIf isDarwin {
      telegram-bot = {
        enable = true;
        config = {
          ProgramArguments = [ "${cfg.package}/bin/tg-bot" ];
          EnvironmentVariables = envAttrs;
          RunAtLoad = true;
          # SuccessfulExit = false restarts only on a non-zero exit, which is
          # launchd's nearest equivalent to systemd's Restart=on-failure.
          KeepAlive.SuccessfulExit = false;
          ThrottleInterval = 5; # ~= RestartSec
          StandardOutPath = "${logDir}/telegram-bot.log";
          StandardErrorPath = "${logDir}/telegram-bot.err.log";
        };
      };
    };
  };
}
