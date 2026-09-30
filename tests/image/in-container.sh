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

kill "${www_pid}" 2>/dev/null

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
if [ "${fail}" != "0" ]; then
  echo '--- last supervisor log ---'
  cat /tmp/supervisor.log
  exit 1
fi
