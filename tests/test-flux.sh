#!/bin/bash
# Unit tests: the pure decisions in flux-lib.sh, the serverconfig.xml editor, the mod unpacker
# and the telnet client against a fake console. No Docker, no Steam, no game. Run from the
# repository root.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# shellcheck source=scripts/flux-lib.sh
FLUX_LOG="" source scripts/flux-lib.sh

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
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# --- Steam branch ------------------------------------------------------------------------------
check "empty is the stable build" "public" "$(flux_effective_branch '')"
check "stable is public" "public" "$(flux_effective_branch stable)"
check "Stable in any case" "public" "$(flux_effective_branch Stable)"
check "experimental" "latest_experimental" "$(flux_effective_branch latest_experimental)"
check "an old build's branch" "v2.6" "$(flux_effective_branch v2.6)"
check "crossplay forces stable" "public" "$(flux_effective_branch latest_experimental true)"
check "crossplay off keeps experimental" "latest_experimental" "$(flux_effective_branch latest_experimental false)"
check "a branch with a space is refused" "1" "$(status flux_effective_branch 'public +quit')"
check "a branch with a quote is refused" "1" "$(status flux_effective_branch "a'b")"
check "public adds no arguments" "" "$(flux_steam_branch_args public)"
check "a beta adds -beta" "-beta latest_experimental" "$(flux_steam_branch_args latest_experimental)"

# --- Restart time ------------------------------------------------------------------------------
check "05:00 is minute 300" "300" "$(flux_restart_minute_of_day 05:00)"
check "5:07 is minute 307" "307" "$(flux_restart_minute_of_day 5:07)"
check "00:08 is not octal" "8" "$(flux_restart_minute_of_day 00:08)"
check "24:00 is refused" "1" "$(status flux_restart_minute_of_day 24:00)"
check "empty means no restart" "1" "$(status flux_restart_minute_of_day '')"
check "a cron line is refused" "1" "$(status flux_restart_minute_of_day '0 5 * * *')"
check "an hour ahead" "3600" "$(flux_seconds_until 300 240 0)"
check "the seconds already past count" "3570" "$(flux_seconds_until 300 240 30)"
check "earlier today means tomorrow" "82800" "$(flux_seconds_until 300 360 0)"
check "due this very minute means tomorrow" "86370" "$(flux_seconds_until 300 300 30)"
check "warning defaults to 5" "5" "$(flux_warn_minutes '')"
check "warning is capped at 30" "30" "$(flux_warn_minutes 90)"
check "warning 08 is not octal" "8" "$(flux_warn_minutes 08)"
check "a non-number warning is 5" "5" "$(flux_warn_minutes soon)"

# --- Restart budget ----------------------------------------------------------------------------
check "old restarts age out" "900 950" "$(flux_restarts_in_window 1000 200 100 700 900 950)"
check "a scheduled restart is not counted" "1" "$(status flux_restart_counts 'scheduled restart at 05:00')"
check "a crash is counted" "0" "$(status flux_restart_counts 'the server ended on its own (exit 139)')"

# --- Rotation ----------------------------------------------------------------------------------
check "keeps the newest" $'c\nd' "$(flux_files_to_prune 2 a b c d)"
check "nothing to prune" "" "$(flux_files_to_prune 5 a b c)"
check "backups default to 2" "2" "$(flux_backup_keep '')"
check "backups off" "0" "$(flux_backup_keep 0)"
check "backups capped at 10" "10" "$(flux_backup_keep 50)"
check "backups: junk is 2" "2" "$(flux_backup_keep lots)"
# A snapshot is due when none exists or the newest is at least FLUX_BACKUP_MIN_MINUTES old
check "snapshot due: none yet" "0" "$(status flux_backup_due 0 10000 30)"
check "snapshot due: 29 min old, not due" "1" "$(status flux_backup_due 8260 10000 30)"
check "snapshot due: 30 min old" "0" "$(status flux_backup_due 8200 10000 30)"
check "snapshot due: default is 30" "1" "$(status flux_backup_due 8260 10000 '')"
check "snapshot due: junk is 30" "1" "$(status flux_backup_due 8260 10000 soon)"
check "snapshot due: 0 means always" "0" "$(status flux_backup_due 9999 10000 0)"
# Which snapshot holds the settings file: the newest one that does
mkdir -p "${tmp}/snaps/src/Saves"
echo old >"${tmp}/snaps/src/serverconfig.xml"
tar -C "${tmp}/snaps/src" -czf "${tmp}/snaps/20260101-000000-world.tar.gz" Saves serverconfig.xml
tar -C "${tmp}/snaps/src" -czf "${tmp}/snaps/20260102-000000-world.tar.gz" Saves
touch -d '2026-01-01' "${tmp}/snaps/20260101-000000-world.tar.gz"
touch -d '2026-01-02' "${tmp}/snaps/20260102-000000-world.tar.gz"
check "settings come from the newest snapshot that holds them" "${tmp}/snaps/20260101-000000-world.tar.gz" "$(flux_snapshot_with "${tmp}/snaps" serverconfig.xml)"
check "no snapshot holds them" "1" "$(status flux_snapshot_with "${tmp}/snaps" nothing.xml)"
mkdir -p "${tmp}/rot"
for n in 1 2 3 4; do touch -d "2026-01-0${n}" "${tmp}/rot/2026010${n}-world.tar.gz"; done
touch "${tmp}/rot/keep-me.txt"
flux_prune "${tmp}/rot" '*-world.tar.gz' 2
check "prune keeps the two newest and ignores other files" \
  "20260103-world.tar.gz 20260104-world.tar.gz keep-me.txt" "$(cd "${tmp}/rot" && echo *)"

# --- Mods --------------------------------------------------------------------------------------
printf 'MyMod\n../../etc\nOther Mod\n.\n/abs\n' >"${tmp}/manifest"
check "manifest: only plain folder names" $'MyMod\nOther Mod' "$(flux_manifest_names "${tmp}/manifest")"
check "manifest: none yet" "" "$(flux_manifest_names "${tmp}/missing")"
check "urls are split and trimmed" $'https://a/x.zip\nhttp://b/y.zip' "$(flux_mod_urls ' https://a/x.zip , http://b/y.zip,')"
check "a non-http url is refused" "1" "$(status flux_mod_urls 'https://a/x.zip,file:///etc/passwd')"

mk_modinfo() { mkdir -p "$1" && printf '<xml>\n<Name value="%s" />\n</xml>\n' "$2" >"$1/ModInfo.xml"; }
(cd "${tmp}" && rm -rf a && mk_modinfo a/MyMod MyMod && (cd a && python3 -m zipfile -c ../folder.zip MyMod))
(cd "${tmp}" && rm -rf b && mk_modinfo b/Mods/Other Other && tar -C b -czf nested.tar.gz Mods)
(cd "${tmp}" && rm -rf c && mk_modinfo c "Bare Mod!" && (cd c && python3 -m zipfile -c ../bare.zip ModInfo.xml))
(cd "${tmp}" && rm -rf e && mkdir e && echo hi >e/readme.txt && (cd e && python3 -m zipfile -c ../empty.zip readme.txt))
python3 - "${tmp}/evil.zip" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("../escape/ModInfo.xml", "x")
EOF
check "a mod in a folder" "MyMod" "$(python3 scripts/flux-unpack.py "${tmp}/folder.zip" "${tmp}/mods")"
check "a mod under Mods/" "Other" "$(python3 scripts/flux-unpack.py "${tmp}/nested.tar.gz" "${tmp}/mods")"
check "a bare mod is named after <Name>" "Bare_Mod_" "$(python3 scripts/flux-unpack.py "${tmp}/bare.zip" "${tmp}/mods")"
check "all three on the volume" "Bare_Mod_ MyMod Other" "$(cd "${tmp}/mods" && echo *)"
check "no ModInfo.xml is refused" "1" "$(status python3 scripts/flux-unpack.py "${tmp}/empty.zip" "${tmp}/mods")"
check "a path outside is refused" "1" "$(status python3 scripts/flux-unpack.py "${tmp}/evil.zip" "${tmp}/mods")"
check "nothing escaped" "1" "$(status test -e "${tmp}/escape")"
# A zip made on Windows keeps "\\" in its entry names (Tier 7 Expansion's releases): same mod, same folder
python3 - "${tmp}/win.zip" "${tmp}/winevil.zip" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("WinMod\\ModInfo.xml", '<xml><Name value="WinMod" /></xml>')
    z.writestr("WinMod\\Config\\items.xml", "<configs/>")
with zipfile.ZipFile(sys.argv[2], "w") as z:
    z.writestr("..\\escape2\\ModInfo.xml", "x")
EOF
mkdir -p "${tmp}/mods2"
check "backslash entry names still unpack as a folder" "WinMod" "$(python3 scripts/flux-unpack.py "${tmp}/win.zip" "${tmp}/mods2")"
check "and the files are in their sub-folders" "items.xml" "$(ls "${tmp}/mods2/WinMod/Config")"
check "a backslash path outside is refused" "1" "$(status python3 scripts/flux-unpack.py "${tmp}/winevil.zip" "${tmp}/mods2")"
check "nothing escaped that way either" "1" "$(status test -e "${tmp}/escape2")"

# --- serverconfig.xml --------------------------------------------------------------------------
cfg="${tmp}/serverconfig.xml"
fixture=tests/fixtures/serverconfig.xml
sc() { env -i FLUX_DATA_DIR=/mnt/7dtd/data "$@" python3 scripts/flux-serverconfig.py apply "${cfg}"; }
get() { python3 scripts/flux-serverconfig.py get "${cfg}" "$1"; }

cp "${fixture}" "${cfg}"
sc >/dev/null
check "UserDataFolder goes to the data volume" "/mnt/7dtd/data" "$(get UserDataFolder)"
check "telnet on" "true" "$(get TelnetEnabled)"
check "the shipped commented-out UserDataFolder is left as a comment" "1" \
  "$(grep -c '<!-- <property name="UserDataFolder"' "${cfg}")"
check "a second run changes nothing" "" "$(sc)"

cp "${fixture}" "${cfg}"
sc SDTD_ServerMaxPlayerCount=16 'SDTD_ServerName=Bob & "Co" <EU>' SDTD_ServerPassword=hunter2 >"${tmp}/out"
check "players from the environment" "16" "$(get ServerMaxPlayerCount)"
check "a name with XML characters round-trips" 'Bob & "Co" <EU>' "$(get ServerName)"
check "it is escaped in the file" "1" "$(grep -c 'value="Bob &amp; &quot;Co&quot; &lt;EU&gt;"' "${cfg}")"
check "passwords are not logged" "0" "$(grep -c hunter2 "${tmp}/out")"
check "the file is still XML" "0" "$(status python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])" "${cfg}")"

cp "${fixture}" "${cfg}"
sed -i -E 's|(name="ServerDescription"[[:space:]]+value=)"[^"]*"|\1"edited by the owner"|' "${cfg}"
sc SDTD_ServerMaxPlayerCount=12 >/dev/null
check "an owner's edit the environment does not name survives" "edited by the owner" "$(get ServerDescription)"

cp "${fixture}" "${cfg}"
sc SDTD_BrandNewProperty=42 'SDTD_bad-name=1' >"${tmp}/out"
check "an unknown property is added" "42" "$(get BrandNewProperty)"
check "a bad name is reported" "1" "$(grep -c 'WARN skipped: SDTD_bad-name' "${tmp}/out")"
check "an added line keeps the file's CRLF" "1" "$(grep -c $'BrandNewProperty.*\r$' "${cfg}")"
check "and still XML" "0" "$(status python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])" "${cfg}")"

cp "${fixture}" "${cfg}"
sc FLUX_CROSSPLAY=true SDTD_ServerMaxPlayerCount=16 SDTD_EACEnabled=false SDTD_WorldGenSize=10240 SDTD_ServerVisibility=1 >"${tmp}/out"
check "crossplay: on" "true" "$(get ServerAllowCrossplay)"
check "crossplay: EAC can't be turned off" "true" "$(get EACEnabled)"
check "crossplay: EOS sanctions honoured" "false" "$(get IgnoreEOSSanctions)"
check "crossplay: public" "2" "$(get ServerVisibility)"
check "crossplay: 16 players is clamped to 8" "8" "$(get ServerMaxPlayerCount)"
check "crossplay: world clamped to 8192" "8192" "$(get WorldGenSize)"
check "crossplay: the log shows only the final player count" "0" "$(grep -c 'ServerMaxPlayerCount=16' "${tmp}/out")"

cp "${fixture}" "${cfg}"
sc FLUX_CROSSPLAY=true SDTD_ServerMaxPlayerCount=4 SDTD_WorldGenSize=6144 >/dev/null
check "crossplay: fewer players is fine" "4" "$(get ServerMaxPlayerCount)"
check "crossplay: a smaller world is fine" "6144" "$(get WorldGenSize)"

printf '\xef\xbb\xbf' >"${cfg}"
cat "${fixture}" >>"${cfg}"
sc SDTD_ServerPort=26900 >/dev/null
check "a BOM is kept" "efbbbf" "$(head -c 3 "${cfg}" | od -An -tx1 | tr -d ' \n')"

# --- Telnet client against a fake console ------------------------------------------------------
fake_console() { # port, password (empty = none)
  python3 - "$1" "$2" <<'EOF' &
import socket, sys
port, password = int(sys.argv[1]), sys.argv[2]
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port)); s.listen(1)
c, _ = s.accept(); f = c.makefile("rwb", buffering=0)
if password:
    c.sendall(b"Please enter password:\r\n")
    if f.readline().strip().decode() != password:
        c.sendall(b"Password incorrect, please enter password:\r\n"); sys.exit(0)
    c.sendall(b"Logon successful.\r\n")
c.sendall(b"*** Connected with 7DTD server.\r\nPress 'help' to get a list of all commands.\r\n")
for line in f:
    cmd = line.strip().decode()
    if cmd == "exit": break
    c.sendall(("got: %s\r\n" % cmd).encode())
EOF
  sleep 0.5
}
tcfg() { printf '<ServerSettings>\n<property name="TelnetEnabled" value="%s" />\n<property name="TelnetPort" value="%s" />\n<property name="TelnetPassword" value="%s" />\n</ServerSettings>\n' "$1" "$2" "$3" >"${tmp}/t.xml"; }
tel() { FLUX_SERVERCONFIG="${tmp}/t.xml" FLUX_TELNET_TIMEOUT=2 python3 scripts/flux-telnet.py --wait 0.3 "$@"; }

tcfg true 18181 ""
fake_console 18181 ""
check "no password: commands delivered" $'got: saveworld\ngot: say "hi"' "$(tel saveworld 'say "hi"' | grep '^got:')"
wait
tcfg true 18182 s3cret
fake_console 18182 s3cret
check "password: logs in" "got: version" "$(tel version | grep '^got:')"
wait
tcfg true 18183 wrong
fake_console 18183 s3cret
check "a wrong password is 3" "3" "$(status tel version)"
wait
tcfg true 18184 ""
check "nobody listening is 4" "4" "$(status tel version)"
tcfg false 18184 ""
check "telnet off is 2" "2" "$(status tel version)"

# --- flux.log: local, rotated, migrated; the start-up banner -------------------------------------
lt="$(mktemp -d)"
rule='====================================================================='
want="$(printf '%s\n %s server image by FluxCloud - https://runonflux.com\n Host this and 30+ other games in one click: https://runonflux.com/games\n%s' "${rule}" "Test Game" "${rule}")"
banner_out="$(FLUX_LOG="${lt}/logs/flux.log" flux_banner "Test Game")"
check "the banner is exactly the FluxCloud text" "${want}" "${banner_out}"
check "the banner is ASCII only" "0" "$(printf '%s' "${banner_out}" | LC_ALL=C grep -c -P '[^\x00-\x7F]')"
check "the banner goes to flux.log too" "${want}" "$(cat "${lt}/logs/flux.log")"
# shellcheck source=scripts/flux-lib.sh
check "flux.log lives in flux-logs on the install volume by default" "/x/flux-logs/flux.log" "$(unset FLUX_LOG FLUX_LOG_DIR; FLUX_SERVER_DIR=/x; source scripts/flux-lib.sh; echo "${FLUX_LOG}")"
check "an empty FLUX_LOG writes no file" "" "$(FLUX_LOG="" flux_log hello >/dev/null; ls "${lt}/none" 2>/dev/null)"
for i in $(seq 1 40); do FLUX_LOG="${lt}/logs/flux.log" FLUX_LOG_MAX_BYTES=500 flux_log "line number ${i} padding padding padding" >/dev/null; done
check "flux.log rotates to one .1" "1" "$([ -s "${lt}/logs/flux.log.1" ] && echo 1 || echo 0)"
check "and the live file stays under the cap" "1" "$([ "$(stat -c %s "${lt}/logs/flux.log")" -le 600 ] && echo 1 || echo 0)"
check "no second rotated copy" "1" "$(status test -e "${lt}/logs/flux.log.2")"
printf 'old 1\nold 2\n' >"${lt}/old.log"
printf 'new 1\n' >"${lt}/mig.log"
FLUX_LOG="${lt}/mig.log" flux_log_migrate "${lt}/old.log" "${lt}/absent.log"
check "an old flux.log is appended to the new one" "new 1 old 1 old 2" "$(tr '\n' ' ' <"${lt}/mig.log" | sed 's/ $//')"
check "and deleted from the data volume" "1" "$(status test -e "${lt}/old.log")"
check "migrating with nothing to migrate is harmless" "0" "$(FLUX_LOG="${lt}/mig.log" status flux_log_migrate "${lt}/old.log")"
rm -rf "${lt}"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
