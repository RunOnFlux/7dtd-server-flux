#!/bin/bash
# Runs INSIDE the image (tests/test-image.sh). The repository's tests/ folder is mounted at /t.
set -uo pipefail
# Globs below are compared as text: one order everywhere.
export LC_ALL=C

pass=0
fail=0
check() { # description, expected, actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"
  fi
}
status() { "$@" >/dev/null 2>&1; echo $?; }

# --- What the scripts need is in the image -----------------------------------------------------
for tool in steamcmd python3 pgrep pkill curl tar gzip setsid nohup; do
  check "${tool} is installed" "0" "$(status command -v "${tool}")"
done
check "flux-telnet is on the PATH" "0" "$(status command -v flux-telnet)"
# Every script, run for real with no arguments: 64 is its usage exit, anything else is an import
# or a syntax error. flux-unpack.py was the one that failed here.
for script in flux-serverconfig.py flux-telnet.py flux-unpack.py; do
  check "${script} starts" "64" "$(status python3 "/opt/flux/${script}")"
done
for script in flux-entrypoint.sh flux-scheduler.sh flux-lib.sh; do
  check "${script} parses" "0" "$(status bash -n "/opt/flux/${script}")"
done

# --- The unpacker, on real archives -------------------------------------------------------------
www=/tmp/www
mkdir -p "${www}" /tmp/src/ZipMod/Config /tmp/src/Mods/TarMod
printf '<xml>\n<Name value="ZipMod" />\n<Version value="1.0" />\n</xml>\n' >/tmp/src/ZipMod/ModInfo.xml
echo '<configs/>' >/tmp/src/ZipMod/Config/items.xml
: >/tmp/src/ZipMod/empty.txt
printf '<xml>\n<Name value="TarMod" />\n</xml>\n' >/tmp/src/Mods/TarMod/ModInfo.xml
(cd /tmp/src && python3 -m zipfile -c "${www}/zipmod.zip" ZipMod && tar -czf "${www}/tarmod.tar.gz" Mods)
echo 'not an archive' >"${www}/junk.zip"

check "a .zip unpacks" "ZipMod" "$(python3 /opt/flux/flux-unpack.py "${www}/zipmod.zip" /tmp/unpacked 2>&1)"
check "a .tar.gz unpacks" "TarMod" "$(python3 /opt/flux/flux-unpack.py "${www}/tarmod.tar.gz" /tmp/unpacked 2>&1)"
check "the files are there, an empty one included" "Config ModInfo.xml empty.txt" "$(cd /tmp/unpacked/ZipMod && echo *)"
check "junk is refused" "1" "$(status python3 /opt/flux/flux-unpack.py "${www}/junk.zip" /tmp/unpacked)"

# --- The supervisor, around a stand-in Steam and a stand-in server -----------------------------
# steamcmd: "installs" a server that does nothing but wait and end on a signal, with the game's
# own default serverconfig.xml beside it. /usr/local/bin is ahead of the real one on the PATH.
cat >/usr/local/bin/steamcmd <<'STUB'
#!/bin/bash
dir=""
while [ $# -gt 0 ]; do
  [ "$1" = "+force_install_dir" ] && dir="$2"
  shift
done
[ -n "${dir}" ] || exit 0
# A slow update, for the tests of a restart asked for while the server is still being prepared.
[ -f /tmp/steam-slow ] && sleep 4
mkdir -p "${dir}/Mods/0_TFP_Harmony"
cp /t/fixtures/serverconfig.xml "${dir}/serverconfig.xml"
cat >"${dir}/7DaysToDieServer.x86_64" <<'GAME'
#!/bin/bash
trap 'exit 0' TERM INT
while :; do sleep 1 & wait $!; done
GAME
chmod +x "${dir}/7DaysToDieServer.x86_64"
STUB
chmod +x /usr/local/bin/steamcmd

(cd "${www}" && exec python3 -m http.server 8000 --bind 127.0.0.1 >/dev/null 2>&1) &
www_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -fs -o /dev/null http://127.0.0.1:8000/zipmod.zip && break
  sleep 0.5
done

# $1 = FLUX_CROSSPLAY. Starts the supervisor, waits for the server, stops it as Docker would.
# Prints the supervisor's exit code; its output is left in /tmp/supervisor.log.
supervise() {
  local pid rc i
  FLUX_CROSSPLAY="$1" FLUX_RESTART_BACKOFF=1 \
    MODS_URLS='http://127.0.0.1:8000/zipmod.zip, http://127.0.0.1:8000/tarmod.tar.gz' \
    /opt/flux/flux-entrypoint.sh >/tmp/supervisor.log 2>&1 &
  pid=$!
  for ((i = 0; i < 60; i++)); do
    grep -q 'starting the server' /tmp/supervisor.log && break
    sleep 0.5
  done
  sleep 1
  kill -TERM "${pid}"
  wait "${pid}"
  rc=$?
  printf '%s' "${rc}"
}

check "PC server: the supervisor stops with 0" "0" "$(supervise false)"
check "MODS_URLS: both archives landed on the mods volume" "TarMod ZipMod" "$(cd /mnt/7dtd/mods && echo *)"
check "MODS_URLS: the log says installed, twice" "2" "$(grep -c 'mod installed on the mods volume' /tmp/supervisor.log)"
check "the mods were copied into the game" "0_TFP_Harmony TarMod ZipMod" "$(cd /mnt/7dtd/server/Mods && echo *)"
check "and recorded as the owner's" $'TarMod\nZipMod' "$(sort /mnt/7dtd/server/Mods/.flux-owner-mods)"
check "serverconfig.xml was written on the data volume" "/mnt/7dtd/data" \
  "$(python3 /opt/flux/flux-serverconfig.py get /mnt/7dtd/data/serverconfig.xml UserDataFolder)"
check "the stop was a requested one" "1" "$(grep -c 'stopped on request' /tmp/supervisor.log)"

check "crossplay server: the supervisor stops with 0" "0" "$(supervise true)"
check "crossplay: the owner's mods are taken back out of the game" "0_TFP_Harmony" "$(cd /mnt/7dtd/server/Mods && echo *)"
check "crossplay: and the log says why" "1" "$(grep -c 'NOT loaded: consoles cannot join' /tmp/supervisor.log)"
check "crossplay: the list was not downloaded again" "0" "$(grep -c 'downloading mod' /tmp/supervisor.log)"

# --- The restart marker and the stop grace ------------------------------------------------------
# The stand-in server has no console, so a restart request (the marker) is never honoured on its
# own: what happens to it is the supervisor's grace alone. Short grace, to keep the test quick.
marker=/tmp/flux-restart-requested
game_pid() { pgrep -f '7DaysToDieServer[.]x86_64' | head -1; }
wait_log() { # pattern, half-seconds
  local i
  for ((i = 0; i < $2; i++)); do
    grep -q "$1" /tmp/supervisor.log && return 0
    sleep 0.5
  done
  return 1
}
start_supervisor() {
  FLUX_CROSSPLAY=false FLUX_RESTART_BACKOFF=1 FLUX_STOP_GRACE=3 \
    /opt/flux/flux-entrypoint.sh >/tmp/supervisor.log 2>&1 &
  sup_pid=$!
}
stop_supervisor() {
  kill -TERM "${sup_pid}" 2>/dev/null
  wait "${sup_pid}" 2>/dev/null
  rm -f "${marker}"
}

# A request that went away must not shorten the next one's grace. The supervisor kept the time it
# first saw a marker for the whole generation, so the next request (the daily restart) was
# SIGKILLed the moment it was made, before the save it asks for.
start_supervisor
wait_log 'starting the server' 60
sleep 1
game="$(game_pid)"
echo 'scheduled first' >"${marker}"
sleep 2
rm -f "${marker}"
sleep 3
echo 'scheduled second' >"${marker}"
sleep 1.5
check "a second restart request gets a full grace of its own" "0" "$(status kill -0 "${game}")"
check "and nothing was ended by force yet" "0" "$(grep -c 'ending it' /tmp/supervisor.log)"
wait_log 'scheduled second: restarting the server in place' 10
check "a request still not honoured after the grace is forced" "1" "$(grep -c 'ending it' /tmp/supervisor.log)"
check "and counted as the restart it was" "1" "$(grep -c 'scheduled second: restarting the server in place' /tmp/supervisor.log)"
stop_supervisor

# A restart asked for while the server was still being prepared (here: a slow Steam update) is
# not carried into the server that then starts: it killed that one FLUX_STOP_GRACE seconds in.
touch /tmp/steam-slow
start_supervisor
wait_log 'updating the server from Steam' 20
echo 'scheduled early' >"${marker}"
wait_log 'starting the server' 60
rm -f /tmp/steam-slow
sleep 1
game="$(game_pid)"
sleep 4
check "a restart asked for before the start does not kill the new server" "0" "$(status kill -0 "${game}")"
check "nothing was ended by force" "0" "$(grep -c 'ending it' /tmp/supervisor.log)"
check "and the log says what happened to it" "1" "$(grep -c 'asked for before the server started (scheduled early)' /tmp/supervisor.log)"
stop_supervisor

kill "${www_pid}" 2>/dev/null

# --- flux.log is local; the banner ----------------------------------------------------------------
fl_srv=/mnt/7dtd/server
check "flux.log is on the install volume" "0" "$(status test -s "${fl_srv}/flux-logs/flux.log")"
check "and not on the synced data volume" "1" "$(status test -e "/mnt/7dtd/data/flux/flux.log")"
check "the banner is in the container output" "0" "$(status grep -q '7 Days to Die server image by FluxCloud - https://runonflux.com' /tmp/supervisor.log)"
check "and in flux.log" "0" "$(status grep -q 'Host this and 30+ other games in one click: https://runonflux.com/games' "${fl_srv}/flux-logs/flux.log")"
check "at the container start and again for each generation" "1" "$([ "$(grep -c 'server image by FluxCloud' /tmp/supervisor.log)" -ge 2 ] && echo 1 || echo 0)"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
if [ "${fail}" != "0" ]; then
  echo '--- last supervisor log ---'
  cat /tmp/supervisor.log
  exit 1
fi
