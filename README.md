# 7dtd-server-flux

The 7 Days to Die dedicated server image the [Flux](https://runonflux.io/) marketplace deploys:
`runonflux/7dtd-server-flux`.

It runs the game's native Linux server (Steam app 294420), installed and updated with SteamCMD on
every start, under a small supervisor. Written from scratch; same family as
`runonflux/vrising-server-flux` and `runonflux/palworld-server-flux`.

## Why it exists

The image the marketplace staged before (vinanrra/7dtd-server, LinuxGSM) could not do what the
marketplace sells:

| | Previous image | This image |
|---|---|---|
| Per-tier settings | None from the environment: `serverconfig.xml` only, so every tier ran 8 players and crossplay off until the buyer edited the file. On Flux a config's `commands` never deploy, only its environment does | `SDTD_<Property>=<value>` sets any serverconfig property, every start |
| Console crossplay | Off (the game ships it off) | `FLUX_CROSSPLAY=true` enforces the rules consoles need, and nothing else can undo them |
| `docker stop` | LinuxGSM's stop | World saved and server shut down over the console: 3.5 s, exit 0, measured twice (2026-09-27), inside Flux's 10 s |
| Server crashes | The container ends | Restarted in place; the container only ends after 5 crashes in an hour (exit 42) |
| Daily restart | None | `FLUX_RESTART_TIME`, with in-game chat warnings first |
| Backups | Cron on a running server | Taken before every start, with nothing running, so always consistent |
| Mods | Installed into the install and left there | Copied from the mods volume every start; a crossplay server loads none |

## Configuration

| Variable | Default | |
|---|---|---|
| `SDTD_<Property>` | | Sets `<property name="<Property>">` in `serverconfig.xml`. `SDTD_ServerMaxPlayerCount=16`, `SDTD_ServerName=My server`, `SDTD_GameDifficulty=3` ... A property the file lacks is added. |
| `FLUX_CROSSPLAY` | `false` | `true`: PS5 and Xbox players can see and join (see below) |
| `STEAM_BRANCH` | `public` | `public`/`stable`, `latest_experimental`, or an old build's branch (`v2.6`). Ignored with `FLUX_CROSSPLAY` |
| `FLUX_RESTART_TIME` | empty (off) | Daily restart, `HH:MM`, 24 hour, in `TZ`. Also when the server updates and is backed up |
| `FLUX_RESTART_WARN_MINUTES` | `5` | Chat warning before it, 0 to 30, repeated at one minute |
| `TZ` | UTC | Timezone of `FLUX_RESTART_TIME` |
| `FLUX_BACKUP_KEEP` | `2` | World backups kept (0 turns them off, 10 at most) |
| `MODS_URLS` | empty | Comma-separated `.zip`/`.tar.gz` mod archives, downloaded onto the mods volume once per list |
| `SKIP_UPDATE` | empty | `true`: start the installed build without asking Steam |
| `FLUX_STOP_GRACE` | `60` | Seconds a restart may take to save before it is forced |
| `FLUX_RESTART_MAX_ATTEMPTS` / `FLUX_RESTART_WINDOW` | `5` / `3600` | Unplanned restarts allowed per window before the container ends with 42 |
| `FLUX_GAME_LOG_KEEP` | `10` | Game logs kept |

**The environment wins, for the properties it names.** Every start writes the `SDTD_` values into
the file; any other property keeps whatever the owner set in the file. Only `value="..."` is
replaced in place, so comments and layout survive.

### Crossplay

With `FLUX_CROSSPLAY=true`, applied after everything else so no `SDTD_` value can undo it:

- `ServerAllowCrossplay=true`, `EACEnabled=true`, `IgnoreEOSSanctions=false`, `ServerVisibility=2`
- `ServerMaxPlayerCount` at most 8, `WorldGenSize` at most 8192
- the stable build, whatever `STEAM_BRANCH` says
- no mods from the mods volume (the game's own `TFP_*` mods stay: they are part of the vanilla game)

These are The Fun Pimps' rules (V3). Break one and the game gives no error: the server just stops
being listed on consoles.

## Volumes

| Path | What | On Flux |
|---|---|---|
| `/mnt/7dtd/server` | The install, about 17 GB. Disposable: SteamCMD rebuilds it | `ml:` (local, never synced) |
| `/mnt/7dtd/data` | `serverconfig.xml`, `Saves/`, `GeneratedWorlds/`, `backups/`, `logs/`, `flux/flux.log` | primary, `g:` |
| `/mnt/7dtd/mods` | The owner's mods, one folder per mod | `m:` |

Ports: 26900 TCP/UDP, 26901-26902 UDP. The telnet console (8081) is for the supervisor; with no
`TelnetPassword` the game only listens on the loopback. `flux-telnet <command>` runs a console
command from inside the container.

## Measured (2026-09-27, V 3.2.0 b10, 3 CPU / 8 GB)

- first start with the files present: world loaded in 30 s; 2.2 GB of memory idle on Navezgane
- a start with nothing to update: SteamCMD 5 to 9 s
- `docker stop`: 3.5 s to exit 0, `SaveAndCleanupWorld` in the log (twice)
- SIGTERM straight to the game also saves (`SaveAndCleanupWorld`, exit 0), so the fallback when the
  console does not answer is safe
- scheduled restart: warnings at 2 and 1 minute in chat, save, update, next generation up, in the
  same container

## Development

```bash
./tests/test-flux.sh
docker build -t 7dtd-server-flux:local .
./tests/test-image.sh
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh tests/image/*.sh
```

`tests/test-flux.sh` tests the scripts with the machine's own tools. `tests/test-image.sh` runs
them INSIDE the built image, with a stand-in SteamCMD and server under the real supervisor: it is
what catches a package the image lacks. 1.0.0 passed the first and could not unpack a mod
(`python3-minimal` has no `zipfile`).

CI (`.github/workflows/build.yml`) runs the unit tests on every push and pull request. On every
push to `main`, and weekly, it builds the image, runs `tests/test-image.sh` in it, and only then
publishes `:latest`, `:<version>` and `:<commit>`. The version is the `VERSION` file; bump it with
any change to what the image does. It needs `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`.

## Versions

- **1.0.2**: a restart is never forced early. The stop grace (`FLUX_STOP_GRACE`) counted from the
  first restart request of the whole generation, so once one had come and gone the next, the
  daily restart included, was SIGKILLed the moment it was asked for, before its save. And a
  request made while the server was still being prepared (the Steam update, the backup) was
  carried into the server that then started, which was killed a minute in. Now each request gets
  its own full grace, one made before the start is dropped (and logged), and a forced stop is
  sent once.
- **1.0.1**: `MODS_URLS` works. The image installed `python3-minimal`, which lacks `shutil`,
  `zipfile` and `tarfile`, so `flux-unpack.py` failed on its imports and no mod archive was ever
  unpacked. Now full `python3`, and CI tests the built image before publishing it.
- **1.0.0**: first image.
