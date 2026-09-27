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
FLUX_LOG="${FLUX_LOG:-${FLUX_DATA_DIR}/flux/flux.log}"
FLUX_LOG_MAX_LINES="${FLUX_LOG_MAX_LINES:-2000}"
FLUX_GAME_LOG_DIR="${FLUX_GAME_LOG_DIR:-${FLUX_DATA_DIR}/logs}"
FLUX_GAME_LOG_KEEP="${FLUX_GAME_LOG_KEEP:-10}"
FLUX_BACKUP_DIR="${FLUX_BACKUP_DIR:-${FLUX_DATA_DIR}/backups}"
FLUX_GAME_PROCESS="${FLUX_GAME_PROCESS:-7DaysToDieServer.x86_64}"
FLUX_STEAM_APP="${FLUX_STEAM_APP:-294420}"
FLUX_TELNET="${FLUX_TELNET:-/opt/flux/flux-telnet.py}"
FLUX_RESTART_MARKER="${FLUX_RESTART_MARKER:-/tmp/flux-restart-requested}"

flux_log() {
  local line
  line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') [flux] $*"
  printf '%s\n' "${line}"
  if [ -n "${FLUX_LOG}" ] && mkdir -p "$(dirname "${FLUX_LOG}")" 2>/dev/null; then
    printf '%s\n' "${line}" >>"${FLUX_LOG}" 2>/dev/null || return 0
    flux_trim_file "${FLUX_LOG}" "${FLUX_LOG_MAX_LINES}"
  fi
}

# Keeps the last $2 lines of $1. Checked cheaply first: most calls change nothing.
flux_trim_file() {
  local file="$1" max="$2" lines
  lines="$(wc -l <"${file}" 2>/dev/null || echo 0)"
  if [ "${lines}" -gt $((max + max / 10)) ]; then
    tail -n "${max}" "${file}" >"${file}.tmp" 2>/dev/null && mv "${file}.tmp" "${file}"
  fi
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
