# squadjs.nix
#
# NixOS module for SquadJS (https://github.com/Team-Silver-Sphere/SquadJS)
# plus third-party plugins (map voting etc.) — the full admin/QoL stack.
#
# Per instance, enabled by default:
#   AutoTKWarn            — auto-warns teamkillers
#   AutoKickUnassigned    — kicks players who refuse to join a squad
#   SeedingMode           — seeding rules broadcast until live threshold
#   ChatCommands          — simple !command responses
#   IntervalledBroadcasts — rotating rules/description messages
#   TeamRandomizer        — admins can !randomize teams
#   MapVote               — fantinodavide/squad-js-map-vote (!vote at round
#                           start; third-party, auto-installed)
# With a Discord bot token + channel IDs, additionally:
#   DiscordChat / DiscordAdminRequest (+admin-cam & TK logs) / DiscordRcon
#   DiscordKillFeed / DiscordRoundWinner / CBLInfo (Community Ban List
#   warnings when a flagged player joins)
#
# Discord prerequisites (one-time): create app+bot at
# discord.com/developers/applications, enable the Message Content intent,
# invite the bot, enable Developer Mode in Discord and copy channel IDs.

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.squadjs;
  stateDir = "/var/lib/squadjs";
  nodejs = pkgs.nodejs_22;

  # Custom plugin: in-game broadcasts for knife kills, teamkills, and
  # helicopter shootdowns. Knife/TK detection uses SquadJS's solid event
  # stream; heli shootdowns are a heuristic (possession tracking + death
  # weapon matching) — tune the regexes via plugin options if needed.
  broadcastEventsJs = pkgs.writeText "broadcast-events.js" ''
    import BasePlugin from './base-plugin.js';

    export default class BroadcastEvents extends BasePlugin {
      static get description() {
        return 'Broadcasts knife kills, teamkills and helicopter shootdowns.';
      }
      static get defaultEnabled() { return false; }
      static get optionsSpecification() {
        return {
          knife:    { required: false, default: true,  description: 'broadcast knife kills' },
          teamkill: { required: false, default: true,  description: 'broadcast teamkills' },
          heli:     { required: false, default: true,  description: 'broadcast heli shootdowns' },
          knifeRegex: { required: false, default: '(bayonet|knife|socp|kabar)',
                        description: 'weapon classname regex for melee kills' },
          heliRegex:  { required: false, default: '(helicopter|heli_|_heli|uh60|uh1y|mi8|mi17|mi24|mi28|sz8|z8|ch146|ch178|ch53|mh6|mh60|ah64|ah1z|ka52|loach|littlebird|raven|gazelle|tigre|tiger_hap|nh90|caracal|puma|cougar|merlin|wildcat|apache|venom|viper|blackhawk|chinook|havoc|hind|hokum)',
                        description: 'classname regex for helicopters (extend per mod via plugin options)' },
          cooldownMs: { required: false, default: 15000,
                        description: 'min ms between heli broadcasts (dedupes multi-crew deaths)' }
        };
      }

      constructor(server, options, connectors) {
        super(server, options, connectors);
        this.pilots = new Map();        // eosID -> heli classname
        this.lastHeliBroadcast = 0;
        this.onWound = this.onWound.bind(this);
        this.onTeamkill = this.onTeamkill.bind(this);
        this.onPossess = this.onPossess.bind(this);
        this.onUnpossess = this.onUnpossess.bind(this);
        this.onDied = this.onDied.bind(this);
      }

      async mount() {
        this.server.on('PLAYER_WOUNDED', this.onWound);
        this.server.on('TEAMKILL', this.onTeamkill);
        this.server.on('PLAYER_POSSESS', this.onPossess);
        this.server.on('PLAYER_UNPOSSESS', this.onUnpossess);
        this.server.on('PLAYER_DIED', this.onDied);
      }
      async unmount() {
        this.server.removeEventListener('PLAYER_WOUNDED', this.onWound);
        this.server.removeEventListener('TEAMKILL', this.onTeamkill);
        this.server.removeEventListener('PLAYER_POSSESS', this.onPossess);
        this.server.removeEventListener('PLAYER_UNPOSSESS', this.onUnpossess);
        this.server.removeEventListener('PLAYER_DIED', this.onDied);
      }

      say(msg) { this.server.rcon.broadcast(msg).catch(() => {}); }
      pid(p) { return p && (p.eosID || p.steamID || p.name); }

      onWound(info) {
        if (!this.options.knife) return;
        if (!info.attacker || !info.victim || !info.weapon) return;
        if (info.teamkill) return;
        if (new RegExp(this.options.knifeRegex, 'i').test(info.weapon)) {
          this.say(`KNIFE KILL! ''${info.attacker.name} sliced ''${info.victim.name}!`);
        }
      }

      onTeamkill(info) {
        if (!this.options.teamkill) return;
        if (!info.attacker || !info.victim) return;
        this.say(`TEAMKILL: ''${info.attacker.name} teamkilled ''${info.victim.name}. Apologize in all chat!`);
      }

      onPossess(info) {
        if (!info.player || !info.possessClassname) return;
        // harvest aid: every possession classname at verbosity 2 —
        // `journalctl -u squadjs-<x> | grep POSSESS` after a session gives
        // the real (modded) classnames to add to heliRegex
        this.verbose(2, `POSSESS ''${info.player.name} -> ''${info.possessClassname}`);
        if (new RegExp(this.options.heliRegex, 'i').test(info.possessClassname)) {
          this.pilots.set(this.pid(info.player), info.possessClassname);
        }
      }
      onUnpossess(info) {
        if (info.player) this.pilots.delete(this.pid(info.player));
      }

      onDied(info) {
        if (!this.options.heli) return;
        if (!info.victim || !info.weapon) return;
        const wasFlying = this.pilots.has(this.pid(info.victim));
        const heliWeapon = new RegExp(this.options.heliRegex, 'i').test(info.weapon);
        if (!wasFlying || !heliWeapon) return;
        this.pilots.delete(this.pid(info.victim));
        const now = Date.now();
        if (now - this.lastHeliBroadcast < this.options.cooldownMs) return;
        this.lastHeliBroadcast = now;
        if (info.attacker && info.attacker.name !== info.victim.name && !info.teamkill) {
          this.say(`SHOT DOWN! ''${info.attacker.name} downed ''${info.victim.name}'s helicopter!`);
        } else {
          this.say(`''${info.victim.name}'s helicopter went down in flames!`);
        }
      }
    }
  '';

  # Custom plugin: private welcome popup to each connecting player.
  welcomeMessageJs = pkgs.writeText "welcome-message.js" ''
    import BasePlugin from './base-plugin.js';

    export default class WelcomeMessage extends BasePlugin {
      static get description() { return 'Greets connecting players with a private warn message.'; }
      static get defaultEnabled() { return false; }
      static get optionsSpecification() {
        return {
          message: { required: true, description: 'welcome text', default: 'Welcome!' },
          delayMs: { required: false, default: 20000,
                     description: 'wait before greeting so the player is past the loading screen' }
        };
      }
      constructor(server, options, connectors) {
        super(server, options, connectors);
        this.onConnect = this.onConnect.bind(this);
      }
      async mount() { this.server.on('PLAYER_CONNECTED', this.onConnect); }
      async unmount() { this.server.removeEventListener('PLAYER_CONNECTED', this.onConnect); }
      onConnect(info) {
        if (!info.player) return;
        const id = info.player.eosID || info.player.steamID;
        if (!id) return;
        setTimeout(() => {
          this.server.rcon.warn(id, this.options.message).catch(() => {});
        }, this.options.delayMs);
      }
    }
  '';

  mkConfig = name: i:
    let
      hasDiscord = i.discord.token != null;
      base = {
        server = {
          id = 1;
          host = "127.0.0.1";
          queryPort = i.queryPort;
          rconPort = i.rconPort;
          rconPassword = i.rconPassword;
          logReaderMode = "tail";
          logDir = i.logDir;
          adminLists = optional (i.adminsFile != null) {
            type = "local";
            source = i.adminsFile;
          };
        };
        connectors = optionalAttrs hasDiscord { discord = i.discord.token; };
        plugins =
          [
            { plugin = "AutoTKWarn"; enabled = true; }
            { plugin = "AutoKickUnassigned"; enabled = true;
              warningMessage = "Join a squad — unassigned players are kicked.";
              kickMessage = "Unassigned - automatically removed";
              frequencyOfWarnings = 30;
              unassignedTimer = 360;
              playerThreshold = 28;
              roundStartDelay = 900; }
            { plugin = "SeedingMode"; enabled = true;
              interval = 150000;
              seedingThreshold = 50;
              seedingMessage = "Seeding Rules Active! Fight only over the middle flags, no FOB camping!";
              liveEnabled = true;
              liveThreshold = 52;
              liveMessage = "Live!"; }
            { plugin = "ChatCommands"; enabled = true;
              commands = [
                { command = "squadjs"; type = "warn";
                  response = "This server runs SquadJS on NixOS.";
                  ignoreChats = [ ]; }
              ]; }
            { plugin = "TeamRandomizer"; enabled = true; }
          ]
          ++ optional i.mapVote.enable (recursiveUpdate {
            plugin = "MapVote";
            enabled = true;
            automaticVoteStart = true;
            minPlayersForVote = i.mapVote.minPlayersForVote;
            voteWaitTimeFromMatchStart = 15;   # minutes
            voteBroadcastInterval = 7;          # minutes
            # consult github.com/fantinodavide/squad-js-map-vote for the
            # full option set; add/override via mapVote.extraOptions
          } i.mapVote.extraOptions)
          ++ optional i.funBroadcasts.enable ({
            plugin = "BroadcastEvents";
            enabled = true;
            knife = i.funBroadcasts.knife;
            teamkill = i.funBroadcasts.teamkill;
            heli = i.funBroadcasts.heli;
          } // optionalAttrs (i.funBroadcasts.heliRegex != null) {
            heliRegex = i.funBroadcasts.heliRegex;
          })
          ++ optional (i.welcomeMessage != null) {
            plugin = "WelcomeMessage";
            enabled = true;
            message = i.welcomeMessage;
          }
          ++ optional (i.broadcasts != [ ]) {
            plugin = "IntervalledBroadcasts";
            enabled = true;
            interval = i.broadcastIntervalMs;
            broadcasts = i.broadcasts;
          }
          ++ optional (hasDiscord && i.discord.chatChannelId != null) {
            plugin = "DiscordChat"; enabled = true;
            discordClient = "discord"; channelID = i.discord.chatChannelId; }
          ++ optional (hasDiscord && i.discord.chatChannelId != null) {
            plugin = "DiscordRoundWinner"; enabled = true;
            discordClient = "discord"; channelID = i.discord.chatChannelId; }
          ++ optional (hasDiscord && i.discord.adminChannelId != null) {
            plugin = "DiscordAdminRequest"; enabled = true;
            discordClient = "discord"; channelID = i.discord.adminChannelId;
            pingDelay = 60000; }
          ++ optional (hasDiscord && i.discord.adminChannelId != null) {
            plugin = "DiscordAdminCamLogs"; enabled = true;
            discordClient = "discord"; channelID = i.discord.adminChannelId; }
          ++ optional (hasDiscord && i.discord.adminChannelId != null) {
            plugin = "DiscordTeamkill"; enabled = true;
            discordClient = "discord"; channelID = i.discord.adminChannelId; }
          ++ optional (hasDiscord && i.discord.adminChannelId != null) {
            # Community Ban List: warns admins when a flagged player joins
            plugin = "CBLInfo"; enabled = true;
            discordClient = "discord"; channelID = i.discord.adminChannelId;
            threshold = 6; }
          ++ optional (hasDiscord && i.discord.killfeedChannelId != null) {
            plugin = "DiscordKillFeed"; enabled = true;
            discordClient = "discord"; channelID = i.discord.killfeedChannelId;
            disableCBL = false; }
          ++ optional (hasDiscord && i.discord.rconChannelId != null) {
            # Full RCON from Discord (`!rcon ListLayers`). ADMINS-ONLY channel!
            plugin = "DiscordRcon"; enabled = true;
            discordClient = "discord"; channelID = i.discord.rconChannelId;
            prependAdminNameInBroadcast = true; }
          ++ i.extraPlugins;
      };
    in pkgs.writeText "squadjs-${name}-config.json"
      (builtins.toJSON (recursiveUpdate base i.extraConfig));

  instanceModule = types.submodule ({ name, ... }: {
    options = {
      enable = mkOption { type = types.bool; default = true; };

      gameService = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "squad-weather";
      };

      queryPort    = mkOption { type = types.port; };
      rconPort     = mkOption { type = types.port; };
      rconPassword = mkOption { type = types.str; };

      logDir = mkOption { type = types.path; };

      adminsFile = mkOption { type = types.nullOr types.path; default = null; };

      funBroadcasts = {
        enable   = mkOption { type = types.bool; default = true; };
        knife    = mkOption { type = types.bool; default = true; };
        teamkill = mkOption { type = types.bool; default = true; };
        heli     = mkOption { type = types.bool; default = true;
          description = "Heli shootdown broadcasts (heuristic: possession tracking + death-weapon match)."; };
        heliRegex = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Override the helicopter classname regex (e.g. after harvesting modded classnames from the POSSESS log lines).";
        };
      };

      mapVote = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "fantinodavide/squad-js-map-vote: automatic layer vote each round.";
        };
        minPlayersForVote = mkOption { type = types.int; default = 20; };
        extraOptions = mkOption {
          type = types.attrs;
          default = { };
          description = "Merged over the MapVote plugin config (see its README for options like layer filters).";
        };
      };

      layerListUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "https://raw.githubusercontent.com/fantinodavide/SquadLayerList/main/mods/incredible-crazy-mode/layers.old.json";
        description = ''
          Replace SquadJS's built-in (vanilla) layer list with a custom one,
          e.g. a modded list from fantinodavide/SquadLayerList, so MapVote
          and layer validation know modded layers. Leave null for vanilla.
        '';
      };

      welcomeMessage = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "Welcome! Rules: PTO, no toxicity. Discord: discord.gg/xyz";
        description = "Private greeting popup sent to each player ~20s after connecting.";
      };

      broadcasts = mkOption { type = types.listOf types.str; default = [ ]; };
      broadcastIntervalMs = mkOption { type = types.int; default = 300000; };

      discord = {
        token = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Bot token (nix-store visibility caveat applies; sops-nix for production).";
        };
        chatChannelId     = mkOption { type = types.nullOr types.str; default = null; };
        adminChannelId    = mkOption { type = types.nullOr types.str; default = null; };
        rconChannelId     = mkOption { type = types.nullOr types.str; default = null; };
        killfeedChannelId = mkOption { type = types.nullOr types.str; default = null; };
      };

      externalPlugins = mkOption {
        type = types.listOf (types.submodule {
          options = {
            name = mkOption { type = types.str; };
            repo = mkOption { type = types.str; };
            ref  = mkOption { type = types.str; default = "master"; };
          };
        });
        default = [
          { name = "map-vote";
            repo = "https://github.com/fantinodavide/squad-js-map-vote";
            ref = "master"; }
        ];
        description = "Third-party plugin repos; their .js files are installed into squad-server/plugins/.";
      };

      extraPlugins = mkOption { type = types.listOf types.attrs; default = [ ]; };
      extraConfig  = mkOption { type = types.attrs; default = { }; };
    };
  });

  enabledInstances = filterAttrs (_: i: i.enable) cfg.instances;

in
{
  options.services.squadjs = {
    enable = mkEnableOption "SquadJS admin framework";

    version = mkOption {
      type = types.str;
      default = "master";
      description = "Git ref of SquadJS to deploy.";
    };

    gameGroup = mkOption { type = types.str; default = "squadsrv"; };

    instances = mkOption { type = types.attrsOf instanceModule; default = { }; };
  };

  config = mkIf cfg.enable {

    users.users.squadjs = {
      isSystemUser = true;
      group = "squadjs";
      home = stateDir;
      createHome = true;
      extraGroups = [ cfg.gameGroup ];
    };
    users.groups.squadjs = { };

    systemd.tmpfiles.rules = [ "d ${stateDir} 0750 squadjs squadjs -" ];

    systemd.services = mapAttrs' (name: i: nameValuePair "squadjs-${name}" {
      description = "SquadJS admin framework: ${name}";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ]
        ++ optional (i.gameService != null) "${i.gameService}.service";
      wants = [ "network-online.target" ]
        ++ optional (i.gameService != null) "${i.gameService}.service";

      path = [ nodejs pkgs.git pkgs.gnused pkgs.cacert ];

      preStart = ''
        set -euo pipefail
        export HOME=${stateDir}
        APP=${stateDir}/${name}/app

        if [ ! -d "$APP/.git" ]; then
          git clone https://github.com/Team-Silver-Sphere/SquadJS "$APP"
        fi
        cd "$APP"
        git fetch --all --tags
        git checkout ${cfg.version}
        git pull --ff-only || true

        npm install --omit=dev

        # ---- third-party plugins -------------------------------------
        ${concatMapStrings (p: ''
          PDIR=${stateDir}/${name}/ext/${p.name}
          if [ ! -d "$PDIR/.git" ]; then
            git clone ${p.repo} "$PDIR"
          fi
          (cd "$PDIR" && git fetch --all && git checkout ${p.ref} && git pull --ff-only || true)
          find "$PDIR" -maxdepth 1 -name '*.js' -exec cp {} "$APP/squad-server/plugins/" \;
        '') i.externalPlugins}

        # ---- custom (modded) layer list -------------------------------
        ${optionalString (i.layerListUrl != null) ''
          sed -i "s|https://raw.githubusercontent.com[^'\"]*layers[^'\"]*\.json|${i.layerListUrl}|g" \
            "$APP"/squad-server/layers/*.js || true
        ''}

        # custom broadcast plugin shipped from the nix store
        install -m 0644 ${broadcastEventsJs} "$APP/squad-server/plugins/broadcast-events.js"
        install -m 0644 ${welcomeMessageJs} "$APP/squad-server/plugins/welcome-message.js"

        install -m 0600 ${mkConfig name i} "$APP/config.json"
      '';

      serviceConfig = {
        User = "squadjs";
        Group = "squadjs";
        WorkingDirectory = "${stateDir}/${name}/app";
        ExecStart = "${nodejs}/bin/node ${stateDir}/${name}/app/index.js";
        ExecStartPre = "${pkgs.coreutils}/bin/sleep 5";
        Restart = "on-failure";
        RestartSec = "10s";
        ProtectSystem = "full";
        ReadWritePaths = [ stateDir ];
        PrivateTmp = true;
      };
    }) enabledInstances;
  };
}
