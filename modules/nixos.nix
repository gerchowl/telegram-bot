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

  # Build a commands directory from the `commands` attrset, if given.
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
in
{
  options.services.telegram-bot = {
    enable = mkEnableOption "Telegram bot polling daemon (tg-bot)";

    package = mkPackageOption self.packages.${pkgs.stdenv.hostPlatform.system} "telegram-bot-rs" {
      default = [ "telegram-bot-rs" ];
      pkgsText = "telegram-bot.packages.\${system}";
    };

    tokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/secrets/telegram-bot-token";
      description = ''
        Path to a file containing **only** the bot token. Typically a
        sops-nix / agenix secret. Must be readable by {option}`services.telegram-bot.user`.
      '';
    };

    chatId = mkOption {
      type = types.nullOr (types.either types.int types.str);
      default = null;
      description = "Default chat id used by tg-send / built-in replies.";
    };

    postOnly = mkOption {
      type = types.bool;
      default = true;
      description = ''
        When true the bot only sends messages and answers built-ins
        (/start, /id, /help); all inbound commands are refused. Set to
        false to enable the command runner (also needs {option}`allowedChatIds`
        and a commands source).
      '';
    };

    allowedChatIds = mkOption {
      type = types.listOf (types.either types.int types.str);
      default = [ ];
      example = [ 123456789 ];
      description = "Chat ids permitted to run commands. Empty ⇒ nobody is authorized.";
    };

    commands = mkOption {
      type = types.attrsOf types.lines;
      default = { };
      example = lib.literalExpression ''
        {
          deploy = "systemctl restart myapp && echo restarted";
          logs = "journalctl -u myapp -n 30 --no-pager";
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

    user = mkOption {
      type = types.str;
      default = "telegram-bot";
      description = "User the daemon runs as.";
    };

    group = mkOption {
      type = types.str;
      default = "telegram-bot";
      description = "Group the daemon runs as.";
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/telegram-bot";
      description = "Where the long-poll offset is persisted.";
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Extra EnvironmentFile (e.g. for TELEGRAM_BOT_TOKEN directly instead of tokenFile).";
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Extra environment variables for the service.";
    };

    hardening = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Apply a strict systemd sandbox. Disable (or override via
        {option}`extraServiceConfig`) if your commands need broader access
        (e.g. restarting other units, writing outside the state dir).
      '';
    };

    extraServiceConfig = mkOption {
      type = types.attrs;
      default = { };
      description = "Merged into systemd serviceConfig (wins over defaults).";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.tokenFile != null || cfg.environmentFile != null;
        message = "services.telegram-bot: set `tokenFile` (recommended) or `environmentFile`.";
      }
      {
        assertion = !(!cfg.postOnly && cfg.allowedChatIds == [ ]);
        message = "services.telegram-bot: command mode (postOnly = false) requires a non-empty allowedChatIds allowlist.";
      }
    ];

    users.users = mkIf (cfg.user == "telegram-bot") {
      telegram-bot = {
        isSystemUser = true;
        inherit (cfg) group;
        description = "Telegram bot daemon";
      };
    };
    users.groups = mkIf (cfg.group == "telegram-bot") { telegram-bot = { }; };

    systemd.services.telegram-bot = {
      description = "Telegram bot daemon";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [ pkgs.coreutils ];

      environment = {
        TELEGRAM_POST_ONLY = if cfg.postOnly then "1" else "0";
        TELEGRAM_ALLOWED_CHAT_IDS = concatStringsSep "," (map toString cfg.allowedChatIds);
        TELEGRAM_COMMAND_TIMEOUT = toString cfg.commandTimeout;
        TELEGRAM_BOT_STATE_DIR = cfg.stateDir;
      }
      // optionalAttrs (cfg.tokenFile != null) { TELEGRAM_BOT_TOKEN_FILE = toString cfg.tokenFile; }
      // optionalAttrs (commandsDir != null) { TELEGRAM_COMMANDS_DIR = toString commandsDir; }
      // optionalAttrs (cfg.chatId != null) { TELEGRAM_CHAT_ID = toString cfg.chatId; }
      // cfg.extraEnvironment;

      serviceConfig = {
        ExecStart = "${cfg.package}/bin/tg-bot";
        User = cfg.user;
        Group = cfg.group;
        Restart = "on-failure";
        RestartSec = 5;
        StateDirectory = mkIf (cfg.stateDir == "/var/lib/telegram-bot") "telegram-bot";
      }
      // optionalAttrs (cfg.environmentFile != null) { EnvironmentFile = cfg.environmentFile; }
      // optionalAttrs cfg.hardening {
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          # AF_UNIX: needed by the Rust daemon's command timeout (the
          # wait-timeout crate uses a UnixStream self-pipe). Harmless for bash.
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallFilter = [ "@system-service" ];
        SystemCallArchitectures = "native";
      }
      // cfg.extraServiceConfig;
    };
  };
}
