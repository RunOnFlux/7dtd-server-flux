#!/bin/bash
# Shared helpers for the 7 Days to Die image.
#
# SOURCING THIS FILE MUST STAY SIDE-EFFECT FREE: tests/test-flux.sh sources it directly and
# calls the functions with made-up inputs. Everything that decides something takes its inputs
# as arguments, so the decision can be tested without a server, Steam or Docker.

# ---------------------------------------------------------------------------------------------
# Paths. Three volumes: the install (SteamCMD's, disposable), the data (config, saves, generated
# worlds, backups, logs: the only thing that has to survive), and the mods the owner uploads.
# ---------------------------------------------------------------------------------------------
FLUX_SERVER_DIR="${FLUX_SERVER_DIR:-/mnt/7dtd/server}"
FLUX_DATA_DIR="${FLUX_DATA_DIR:-/mnt/7dtd/data}"
FLUX_MODS_DIR="${FLUX_MODS_DIR:-/mnt/7dtd/mods}"
FLUX_SERVERCONFIG="${FLUX_SERVERCONFIG:-${FLUX_DATA_DIR}/serverconfig.xml}"
# flux.log is on the INSTALL volume (local, never synced): it is written on every line, and on the
# synced data volume that would be constant Syncthing traffic. One rotated copy (flux.log.1).
FLUX_LOG_DIR="${FLUX_LOG_DIR:-${FLUX_SERVER_DIR}/flux-logs}"
FLUX_LOG="${FLUX_LOG-${FLUX_LOG_DIR}/flux.log}"
FLUX_LOG_MAX_BYTES="${FLUX_LOG_MAX_BYTES:-5242880}"
FLUX_GAME_LOG_DIR="${FLUX_GAME_LOG_DIR:-${FLUX_DATA_DIR}/logs}"
FLUX_GAME_LOG_KEEP="${FLUX_GAME_LOG_KEEP:-10}"
FLUX_BACKUP_DIR="${FLUX_BACKUP_DIR:-${FLUX_DATA_DIR}/backups}"
FLUX_GAME_PROCESS="${FLUX_GAME_PROCESS:-7DaysToDieServer.x86_64}"
FLUX_STEAM_APP="${FLUX_STEAM_APP:-294420}"
FLUX_TELNET="${FLUX_TELNET:-/opt/flux/flux-telnet.py}"
FLUX_RESTART_MARKER="${FLUX_RESTART_MARKER:-/tmp/flux-restart-requested}"

# One line, to the container's output and (when FLUX_LOG is set) to flux.log, rotated at
# FLUX_LOG_MAX_BYTES (the old file becomes flux.log.1).
flux_log_raw() {
  printf '%s\n' "$1"
  if [ -n "${FLUX_LOG}" ] && mkdir -p "$(dirname "${FLUX_LOG}")" 2>/dev/null; then
    printf '%s\n' "$1" >>"${FLUX_LOG}" 2>/dev/null || return 0
    flux_rotate_log "${FLUX_LOG}" "${FLUX_LOG_MAX_BYTES}"
  fi
  return 0
}

flux_log() {
  flux_log_raw "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [flux] $*"
}

# Moves $1 to $1.1 (replacing the previous one) once it is larger than $2 bytes.
flux_rotate_log() {
  local size
  size="$(stat -c %s "$1" 2>/dev/null || echo 0)"
  if [ "${size}" -gt "$2" ] 2>/dev/null; then
    mv -f "$1" "$1.1" 2>/dev/null
  fi
  return 0
}

# The start-up banner, through the normal log path (docker logs, the panel's log). ASCII only.
# $1 = the game's name.
flux_banner() {
  local rule='====================================================================='
  flux_log_raw "${rule}"
  flux_log_raw " $1 server image by FluxCloud - https://runonflux.com"
  flux_log_raw " Host this and 30+ other games in one click: https://runonflux.com/games"
  flux_log_raw "${rule}"
}

# Once per start: a flux.log an older image left on the synced data volume ($@) is appended to
# the new one and deleted there, so Syncthing stops carrying it.
flux_log_migrate() {
  local old
  [ -n "${FLUX_LOG}" ] || return 0
  for old in "$@"; do
    [ -f "${old}" ] && [ "${old}" != "${FLUX_LOG}" ] || continue
    mkdir -p "$(dirname "${FLUX_LOG}")" 2>/dev/null
    if [ -s "${old}" ]; then
      cat "${old}" >>"${FLUX_LOG}" 2>/dev/null || continue
    fi
    rm -f "${old}" "${old}.tmp"
  done
  return 0
}

flux_truthy() {
  case "${1,,}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# Steam branch. `public` (or empty, `stable`, `default`) is the stable build, the one PS5 and
# Xbox run. `latest_experimental` is the experimental build; older builds have their own
# branches (v2.6 ...). Anything that is not a branch name is refused rather than passed to
# SteamCMD.
# ---------------------------------------------------------------------------------------------

# $1 = the requested branch, $2 = "true" for a crossplay server. Prints the branch to install.
# A crossplay server always gets the stable build: consoles only run that one, and a server on
# any other build is invisible to them. Returns 1 for a value that is not a branch name.
flux_effective_branch() {
  local branch="${1:-public}" crossplay="${2:-}"
  case "${branch,,}" in
    '' | public | stable | default) branch=public ;;
  esac
  if [[ ! "${branch}" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
    return 1
  fi
  if flux_truthy "${crossplay}"; then
    branch=public
  fi
  printf '%s' "${branch}"
}

# $1 = the branch from flux_effective_branch. Prints the SteamCMD arguments for it.
flux_steam_branch_args() {
  [ "$1" = "public" ] && return 0
  printf -- '-beta %s' "$1"
}

# ---------------------------------------------------------------------------------------------
# The scheduled restart.
# ---------------------------------------------------------------------------------------------

# $1 = "HH:MM" (24 hour). Prints the minutes after midnight. Returns 1 for anything else,
# including an empty value, which means "no scheduled restart".
flux_restart_minute_of_day() {
  local value="$1" h m
  [[ "${value}" =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || return 1
  h=$((10#${BASH_REMATCH[1]}))
  m=$((10#${BASH_REMATCH[2]}))
  [ "${h}" -le 23 ] && [ "${m}" -le 59 ] || return 1
  printf '%s' $((h * 60 + m))
}

# $1 = minute of the day the restart is set for, $2 = the current minute of the day,
# $3 = the current second of that minute. Prints how many seconds until the next restart. A
# restart due this very minute is tomorrow's: otherwise a server that restarts at 05:00 and is
# back up at 05:00:40 restarts again.
flux_seconds_until() {
  local target="$1" now_min="$2" now_sec="${3:-0}" delta
  delta=$(((target - now_min) * 60 - now_sec))
  [ "${delta}" -le 0 ] && delta=$((delta + 86400))
  printf '%s' "${delta}"
}

# $1 = the warning the owner asked for, in minutes. Prints it clamped to 0..30.
flux_warn_minutes() {
  local value="${1:-5}"
  [[ "${value}" =~ ^[0-9]+$ ]] || value=5
  value=$((10#${value}))
  [ "${value}" -gt 30 ] && value=30
  printf '%s' "${value}"
}

# ---------------------------------------------------------------------------------------------
# The supervisor's restart budget: a server that keeps dying is not fixed by restarting it in
# the same container forever.
# ---------------------------------------------------------------------------------------------

# $1 = now (epoch seconds), $2 = window in seconds, $3.. = the times of earlier restarts.
# Prints the restarts that are still inside the window, space separated.
flux_restarts_in_window() {
  local now="$1" window="$2" t kept=()
  shift 2
  for t in "$@"; do
    [ "${t}" -gt $((now - window)) ] && kept+=("${t}")
  done
  printf '%s' "${kept[*]}"
}

# $1 = why the last generation ended. Only a server that ended on its own counts against the
# budget: a scheduled restart is the plan working.
flux_restart_counts() {
  case "$1" in
    scheduled*) return 1 ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# Rotation: game logs, and the world backups taken before each start.
# ---------------------------------------------------------------------------------------------

# $1 = number to keep, then the files NEWEST FIRST. Prints the ones to delete.
flux_files_to_prune() {
  local keep="$1" i=0 f
  shift
  for f in "$@"; do
    i=$((i + 1))
    [ "${i}" -gt "${keep}" ] && printf '%s\n' "${f}"
  done
  return 0
}

# $1 = directory, $2 = glob, $3 = number to keep.
flux_prune() {
  local f files=()
  # shellcheck disable=SC2012,SC2086  # $2 is a glob on purpose; names are ours, no spaces
  mapfile -t files < <(ls -t "$1"/$2 2>/dev/null)
  while IFS= read -r f; do
    [ -n "${f}" ] && rm -f "${f}"
  done < <(flux_files_to_prune "$3" "${files[@]}")
}

# $1 = FLUX_BACKUP_KEEP as given. Prints how many backups to keep, 0 (off) to 10.
flux_backup_keep() {
  local value="${1:-2}"
  [[ "${value}" =~ ^[0-9]+$ ]] || value=2
  value=$((10#${value}))
  [ "${value}" -gt 10 ] && value=10
  printf '%s' "${value}"
}

# $1 = mtime (epoch) of the newest snapshot, 0 for none; $2 = now (epoch); $3 = FLUX_BACKUP_MIN_MINUTES
# as given. Succeeds when a new pre-start snapshot is due. A restart loop (a crash, a customer
# restarting ten times in a morning) must not rotate the good snapshots away with copies of the
# same world: the newest one stays until it is at least this old. Default 30, junk is 30, 0 = always.
flux_backup_due() {
  local newest="${1:-0}" now="${2:-0}" min="${3:-30}"
  [[ "${newest}" =~ ^[0-9]+$ ]] || newest=0
  [[ "${now}" =~ ^[0-9]+$ ]] || now=0
  [[ "${min}" =~ ^[0-9]+$ ]] || min=30
  newest=$((10#${newest}))
  now=$((10#${now}))
  min=$((10#${min}))
  [ "${newest}" -gt 0 ] || return 0
  [ $((now - newest)) -ge $((min * 60)) ]
}

# $1 = backup dir, $2 = a path inside the archives. Prints the newest world snapshot that holds
# it, or nothing. Used to get a serverconfig.xml back when the file is gone but the world is not.
flux_snapshot_with() {
  local f files=()
  # shellcheck disable=SC2012  # names are ours, no spaces
  mapfile -t files < <(ls -t "$1"/*-world.tar.gz 2>/dev/null)
  for f in "${files[@]}"; do
    if tar -tzf "${f}" "$2" >/dev/null 2>&1; then
      printf '%s' "${f}"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------------------------
# Mods. The install's Mods folder already holds the game's own (0_TFP_Harmony,
# TFP_CommandExtensions, Xample_MarkersMod in V3: shipped by The Fun Pimps, part of the vanilla
# game consoles run). The owner's are copied in next to them from the mods volume, and a manifest
# of what was copied is what gets removed again, so the game's own are never touched.
# ---------------------------------------------------------------------------------------------

# $1 = the manifest (one folder name per line). Prints the names in it that are safe to delete:
# plain folder names only, so a damaged manifest cannot reach outside Mods.
flux_manifest_names() {
  local name
  [ -f "$1" ] || return 0
  while IFS= read -r name; do
    [[ "${name}" =~ ^[A-Za-z0-9._\ -]+$ ]] && [ "${name}" != "." ] && [ "${name}" != ".." ] &&
      printf '%s\n' "${name}"
  done <"$1"
  return 0
}

# $1 = MODS_URLS. Prints the URLs one per line, trimmed. Returns 1 if one is not http(s).
flux_mod_urls() {
  local url list
  IFS=',' read -r -a list <<<"$1"
  for url in "${list[@]}"; do
    url="${url#"${url%%[![:space:]]*}"}"
    url="${url%"${url##*[![:space:]]}"}"
    [ -z "${url}" ] && continue
    [[ "${url}" =~ ^https?://[^[:space:]]+$ ]] || return 1
    printf '%s\n' "${url}"
  done
}

# ---------------------------------------------------------------------------------------------
# The running server.
# ---------------------------------------------------------------------------------------------

flux_game_pid() {
  pgrep -f "${FLUX_GAME_PROCESS}" 2>/dev/null | head -1
}

# Console commands over telnet, quietly. Prints what the server wrote back.
flux_telnet() {
  python3 "${FLUX_TELNET}" "$@" 2>/dev/null
}
