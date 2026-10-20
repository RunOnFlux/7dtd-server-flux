# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **Docker image repo**, not an application: the 7 Days to Die dedicated server for Flux,
`runonflux/7dtd-server-flux`. steamcmd/steamcmd:ubuntu-24, the game's native Linux server, and a
supervisor in bash. Same family as `~/work/vrising-server-flux` and `~/work/palworld-server-flux`;
read them for the patterns this one follows.

The rule that shapes everything: **the container supervises its own server.** PID 1 is
`flux-entrypoint.sh`, never the game. The game runs as a child so a stop becomes a save, and a
finished generation is followed by the next one in place.

## Commands

```bash
./tests/test-flux.sh
docker build -t 7dtd-server-flux:local .
./tests/test-image.sh                    # the scripts INSIDE the built image; CI gates the publish on it
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh tests/image/*.sh
```

A change to what the image does bumps `VERSION` (the `:<version>` tag and `FLUX_IMAGE_VERSION`)
and gets a line under "Versions" in the README.

## The files

- `scripts/flux-entrypoint.sh`: PID 1. Per generation: SteamCMD update, serverconfig.xml, mods,
  backup, then the server in the background, the log tail and the scheduler. SIGTERM/SIGINT become
  `saveworld` + `shutdown` on the console.
- `scripts/flux-serverconfig.py`: writes `SDTD_*`, the image's own needs and the crossplay rules
  into serverconfig.xml. The one place those rules live.
- `scripts/flux-telnet.py`: console client, `flux-telnet` on the PATH. Reads port and password
  from the same serverconfig.xml.
- `scripts/flux-unpack.py`: one MODS_URLS archive onto the mods volume.
- `scripts/flux-scheduler.sh`: the daily restart (`FLUX_RESTART_TIME`).
- `scripts/flux-lib.sh`: shared helpers. **Sourcing it must stay side-effect free**: the tests
  source it directly. Every decision takes its inputs as arguments.

## Things that will bite you

- **The game ships three mods of its own** in `Mods/` (0_TFP_Harmony, TFP_CommandExtensions,
  Xample_MarkersMod in V3). They are vanilla, consoles run them too. The owner's mods are tracked
  in `Mods/.flux-owner-mods` and only those are ever removed. Never clean `Mods/` by name pattern.
- **The real serverconfig.xml is tab-aligned with trailing comments** (`name="X"\t\t\tvalue="8"/>`),
  and ships `UserDataFolder` commented out. `tests/fixtures/serverconfig.xml` is the V3.2 original;
  test against it, not a hand-written one.
- **Crossplay rules are applied last**, after `SDTD_*`, on purpose. A tier that sets 16 players
  with crossplay on must still end at 8, or the server silently disappears from consoles.
- **`FLUX_CROSSPLAY=false` does not turn crossplay off**, it only stops enforcing it. A PC tier
  that must not advertise crossplay sets `SDTD_ServerAllowCrossplay=false`.
- **Flux stops a container with Docker's default 10 seconds.** Console shutdown measured 3.5 s.
  Anything added to the stop path has to fit in that margin.
- **The unit tests run with the machine's Python, not the image's.** A module or tool the image
  lacks passes them and fails in production (1.0.0: `python3-minimal`, no `zipfile`). Anything a
  script newly needs gets a check in `tests/image/in-container.sh`.
- **`flux.log` is local** (`$FLUX_SERVER_DIR/flux-logs/flux.log`, 5 MB then one `.1`), never on the synced data volume: a constantly written file there is constant Syncthing traffic. `flux_log_migrate` moves an old one off the data volume at start. `flux_banner` prints the FluxCloud banner at container start and every generation; its text is tested.
- **The scheduled CI run publishes only with something to apply** (`.github/ci/needs-rebuild.sh`): urgent security updates, or commits on main since the published `:latest` (label `org.opencontainers.image.revision`) that touch the image inputs.
