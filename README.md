# SQ-Nixos Still WIP but it works pretty well
## tested on a hetzner instance all mods loaded and the server ran flawlessly

**Declarative, modded Squad dedicated server fleets on NixOS.**

Define your entire server fleet — game servers, Workshop mods, layer
rotations, admin lists, firewall rules, auto-updates, and a full
[SquadJS](https://github.com/Team-Silver-Sphere/SquadJS) admin stack
(map voting, Discord bots, broadcasts) — in a handful of Nix files.
Rebuild the whole thing from scratch on a blank machine in ~20 minutes.

```nix
services.squad-servers.instances.my-server = {
  serverName = "[EU] My Modded Server";
  mods.steel-division = "2432926361";
  layerRotation = [ "SD_Yehorivka_RAAS_v1" ];
  gamePort = 7787; queryPort = 27165; rconPort = 21114; beaconPort = 15000;
  rconPassword = "...";
};
```

## Features

- **Multi-instance fleet** from one shared game install — each server gets a
  disposable symlink farm + persistent `Saved/` state, so N servers cost ~1×
  the disk
- **Workshop mods, declaratively** — composable mod profiles
  (`mods/*.nix`) with curated layer rotations for Steel Division, SuperMod
  (incl. Going Dark night layers), ICM, and more
- **ModLoader support** — generated `ModLoader.json` for runtime-injection
  mods like Dynamic Weather
- **Resilient downloads** — SteamCMD wrapper with per-item resume/retry
  (multi-GB Workshop items routinely time out; this handles it)
- **Nightly auto-updates** — systemd timer stops the fleet, updates game +
  all mods, restarts (mod updates otherwise mismatch-kick updated clients)
- **Correct networking out of the box** — the full port matrix from the
  official wiki (game UDP, query UDP+TCP, **beacon UDP+TCP** — the port the
  post-EOS server browser actually pings — RCON, ephemeral range)
- **SquadJS admin stack** (`squadjs.nix`): map voting
  ([squad-js-map-vote](https://github.com/fantinodavide/squad-js-map-vote),
  auto-installed), AutoKickUnassigned, SeedingMode, TeamRandomizer,
  Community Ban List warnings, Discord chat/admin/killfeed/RCON bridges,
  per-player welcome popups, rotating broadcasts, and custom knife-kill /
  teamkill / helicopter-shootdown announcements
- **Hard-won correctness baked in**

## Quick start

1. Copy `squad-servers.nix`, `squadjs.nix`, and `mods/` into `/etc/nixos/`,
   plus `examples/squad-fleet.example.nix` as `/etc/nixos/squad-fleet.nix`.
2. Edit `squad-fleet.nix`: RCON passwords (`openssl rand -hex 24`), your
   SteamID64, server names, which instances are enabled.
3. Wire it up and go:

```nix
# /etc/nixos/configuration.nix
imports = [ ./hardware-configuration.nix ./squad-fleet.nix ];
```

```bash
nixos-rebuild switch
systemctl start squad-download     # ~30 GB base game + your mods
journalctl -fu squad-download      # watch; retry loop on big items is normal
journalctl -fu squad-<instance>    # then watch the server boot
```

Flake users:

```nix
inputs.squad-nixos.url = "github:YOURNAME/squad-nixos";
# in your nixosSystem modules:
inputs.squad-nixos.nixosModules.default
```

## Architecture

```
/var/lib/squad/
├── shared/server/            # ONE SteamCMD install + workshop store
└── instances/<name>/
    ├── farm/                 # disposable symlink farm (rebuilt each start)
    │   └── SquadGame/{ServerConfig,Plugins/Mods,Binaries/Linux}
    └── persist/Saved/        # logs, ban lists, ModLoader config — survives
```

A `prepare` unit rebuilds each farm on every service start: symlinks the
shared install, **materializes the launcher + `Binaries/Linux` as real
files/hardlinks**, links enabled mods into `Plugins/Mods`,
and generates `Server.cfg` / `Rcon.cfg` / `Admins.cfg` / rotations / MOTD
from your Nix options.

SquadJS (`services.squadjs.instances.<name>`) runs one process per game
server: clones/updates SquadJS + third-party plugins at service start,
generates `config.json` from Nix options, reads game logs directly from the
instance's persist dir, and talks RCON over loopback.

## Map voting with modded layers

SquadJS only knows vanilla layers. For MapVote to offer modded ones, host a
layer list JSON publicly (a gist works) and set per instance:

```nix
services.squadjs.instances.<name>.layerListUrl =
  "https://raw.githubusercontent.com/.../layers.old.json";
```

`data/merged-layers.old.json` (854 layers: vanilla + Steel Division +
SuperMod + ICM) is included, generated from
[fantinodavide/SquadLayerList](https://github.com/fantinodavide/SquadLayerList).
Layer names come from SDK exports and can lag mod updates — verify with
`ListLayers` in-game (or `!rcon ListLayers` via the Discord bridge; note
plain Source-RCON clients like mcrcon often return empty for large Squad
responses).

## Discord bot

Create an application + bot at <https://discord.com/developers/applications>,
enable the **Message Content intent**, invite it to your guild, copy channel
IDs (Discord Developer Mode), then fill `discord.token` and the channel IDs
in your fleet file. Each bridge activates only when its channel ID is set.

## Sizing & operations

- RAM: ~5 GB per vanilla instance, 6–12 GB per heavily-modded one. Scale
  instances one at a time and watch `free -h`.
- Disk: base game ~30 GB + mods (SuperMod-class mods are tens of GB).
  The downloader fetches the mod union across **all defined instances**.
- Unlicensed servers list in the **Custom** browser tab (OWI policy).
  VPS hardware is ineligible for an OWI license; main-tab listing requires
  licensed dedicated hardware.
- Clients download server mods on join — an all-mods server can mean a
  60+ GB first join. Say so in your server name/Discord.

## Security note

RCON passwords and Discord tokens set via Nix options end up
world-readable in `/nix/store`. Acceptable for a single-admin box; for
shared machines use [sops-nix](https://github.com/Mic92/sops-nix) or
[agenix](https://github.com/ryantm/agenix) and feed secrets via files.

## Credits

[SquadJS](https://github.com/Team-Silver-Sphere/SquadJS) ·
[squad-js-map-vote](https://github.com/fantinodavide/squad-js-map-vote) ·
[SquadLayerList](https://github.com/fantinodavide/SquadLayerList) ·
the [Squad Wiki](https://squad.fandom.com/wiki/Server_Installation) ·
and the mod authors: Steel Division, SuperMod (Tactical Collective), ICM,
Warzone, Chornivsk, ModLoader, Dynamic Weather System.

## License

MIT — see [LICENSE](LICENSE).
