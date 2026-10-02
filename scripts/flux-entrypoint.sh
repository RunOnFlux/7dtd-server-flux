#!/bin/bash
# PID 1, and the supervisor of the 7 Days to Die server.
#
# The game runs as a CHILD, never exec, so a stop reaches us first and becomes a save, and a
# finished server is followed by the next one in place:
#
#   - every start: SteamCMD update, serverconfig.xml from the environment (flux-serverconfig.py),
#     a backup of the world, the owner's mods, then the server
#   - SIGTERM/SIGINT from Docker: the world is saved and the server shut down (see stop_server)
#   - the server ending on its own, or the daily restart (flux-scheduler.sh): a new generation
#     in the same container, updated from Steam first
#   - FLUX_RESTART_MAX_ATTEMPTS unplanned restarts inside FLUX_RESTART_WINDOW seconds: the
#     container ends with 42, a server that cannot stay up is the platform's to rebuild or move
#
# Same shape as runonflux/vrising-server-flux and runonflux/palworld-server-flux.

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

FLUX_RESTART_MAX_ATTEMPTS="${FLUX_RESTART_MAX_ATTEMPTS:-5}"
FLUX_RESTART_WINDOW="${FLUX_RESTART_WINDOW:-3600}"
FLUX_RESTART_BACKOFF="${FLUX_RESTART_BACKOFF:-10}"
# How long a server asked to stop may take before it is killed. Docker's own deadline on Flux is
# ten seconds, so this only matters for a restart, where nobody is waiting on us.
FLUX_STOP_GRACE="${FLUX_STOP_GRACE:-60}"
FLUX_CROSSPLAY="${FLUX_CROSSPLAY:-false}"
STEAM_BRANCH="${STEAM_BRANCH:-public}"
MODS_URLS="${MODS_URLS:-}"

s="${FLUX_SERVER_DIR}"
d="${FLUX_DATA_DIR}"
m="${FLUX_MODS_DIR}"

rm -f "${FLUX_RESTART_MARKER}"
mkdir -p "${s}" "${d}" "${m}" "$(dirname "${FLUX_LOG}")" "${FLUX_GAME_LOG_DIR}"

if ! branch="$(flux_effective_branch "${STEAM_BRANCH}" "${FLUX_CROSSPLAY}")"; then
  flux_log "ERROR STEAM_BRANCH='${STEAM_BRANCH}' is not a branch name; refusing to start"
  exit 42
fi
flux_log "flux-entrypoint starting (image ${FLUX_IMAGE_VERSION:-dev}, branch ${branch}, crossplay ${FLUX_CROSSPLAY})"
if flux_truthy "${FLUX_CROSSPLAY}" && [ "${branch}" != "${STEAM_BRANCH}" ] && [ "${STEAM_BRANCH,,}" != "stable" ]; then
  flux_log "WARN STEAM_BRANCH='${STEAM_BRANCH}' ignored: a crossplay server must run the stable build consoles run"
fi

game_pid=""
tail_pid=""
scheduler_pid=""
terminating=0
generation=0
restart_history=()

# Asks the running server to save and exit. The console's `shutdown` saves the world and quits
# cleanly; the signal is the fallback for a console that does not answer.
stop_server() {
  [ -n "${game_pid}" ] || return 0
  if ! flux_telnet --wait 0.2 saveworld shutdown >/dev/null; then
    flux_log "WARN the console did not answer; stopping the server with a signal"
    kill -TERM "${game_pid}" 2>/dev/null
  fi
}

# shellcheck disable=SC2329  # invoked by the trap below
term_handler() {
  terminating=1
  flux_log "stop requested: saving the world and shutting down, no restart will follow"
  stop_server
}
trap term_handler TERM INT

# ---------------------------------------------------------------------------------------------
# One generation's preparation.
# ---------------------------------------------------------------------------------------------

update_server() {
  local attempt validate branch_args
  if flux_truthy "${SKIP_UPDATE:-}" && [ -x "${s}/${FLUX_GAME_PROCESS}" ]; then
    flux_log "SKIP_UPDATE is set: not updating the server files"
    return 0
  fi
  branch_args="$(flux_steam_branch_args "${branch}")"
  flux_log "updating the server from Steam (app ${FLUX_STEAM_APP}, branch ${branch})"
  # No `validate` on the first attempt: it re-hashes the whole install (about 15 GB) on every
  # start, daily restarts included. An install that is actually broken fails the first attempt,
  # and every retry validates.
  validate=""
  for attempt in 1 2 3 4 5; do
    # shellcheck disable=SC2086  # branch_args is "" or "-beta <name>", validate "" or "validate"
    if steamcmd +force_install_dir "${s}" +login anonymous \
      +app_update "${FLUX_STEAM_APP}" ${branch_args} ${validate} +quit; then
      return 0
    fi
    [ "${terminating}" = "1" ] && return 1
    validate="validate"
    flux_log "WARN steamcmd failed (attempt ${attempt}/5); retrying in 5s with validate"
    sleep 5
  done
  # A server that already has its files can still run the build it has.
  if [ -x "${s}/${FLUX_GAME_PROCESS}" ]; then
    flux_log "WARN could not update from Steam; starting the build already installed"
    return 0
  fi
  flux_log "ERROR could not install the server from Steam"
  return 1
}

prepare_config() {
  local line
  if [ ! -f "${FLUX_SERVERCONFIG}" ]; then
    flux_log "$(basename "${FLUX_SERVERCONFIG}") not found: copying the server's defaults"
    cp "${s}/serverconfig.xml" "${FLUX_SERVERCONFIG}" || return 1
  fi
  while IFS= read -r line; do
    flux_log "serverconfig: ${line}"
  done < <(FLUX_DATA_DIR="${d}" FLUX_CROSSPLAY="${FLUX_CROSSPLAY}" \
    python3 /opt/flux/flux-serverconfig.py apply "${FLUX_SERVERCONFIG}" 2>&1)
  # A file the edit could not parse is still the owner's: the server gets it as it is.
  return 0
}

# MODS_URLS: archives downloaded into the mods volume, once per list. Changing the list downloads
# it again; files already on the volume are replaced, others are left alone.
download_mods() {
  local urls url stamp tmp
  [ -n "${MODS_URLS}" ] || return 0
  if ! urls="$(flux_mod_urls "${MODS_URLS}")"; then
    flux_log "WARN MODS_URLS has an entry that is not an http(s) URL; not downloading mods"
    return 0
  fi
  stamp="${d}/flux/mods-urls"
  if [ -f "${stamp}" ] && [ "$(cat "${stamp}")" = "${urls}" ]; then
    return 0
  fi
  tmp="$(mktemp -d)"
  while IFS= read -r url; do
    [ -n "${url}" ] || continue
    flux_log "downloading mod ${url}"
    if curl -fsSL --max-time 600 -o "${tmp}/mod" "${url}" &&
      python3 /opt/flux/flux-unpack.py "${tmp}/mod" "${m}"; then
      flux_log "mod installed on the mods volume: ${url}"
    else
      flux_log "WARN could not download or unpack ${url}"
      rm -rf "${tmp}"
      return 0
    fi
  done <<<"${urls}"
  rm -rf "${tmp}"
  printf '%s' "${urls}" >"${stamp}"
}

# The owner's mods: the ones copied last time are removed from the install and copied again from
# the mods volume, so the volume is the one place they live. A crossplay server gets none:
# consoles cannot join a server with mods, and the game gives no error, it just is not listed.
install_mods() {
  local dir name count=0 manifest="${s}/Mods/.flux-owner-mods"
  mkdir -p "${s}/Mods"
  while IFS= read -r name; do
    rm -rf "${s:?}/Mods/${name}"
  done < <(flux_manifest_names "${manifest}")
  : >"${manifest}"
  for dir in "${m}"/*/; do
    [ -d "${dir}" ] || continue
    name="$(basename "${dir}")"
    if [ -e "${s}/Mods/${name}" ]; then
      flux_log "WARN mod ${name} has the name of one the game ships; not installed"
      continue
    fi
    count=$((count + 1))
    flux_truthy "${FLUX_CROSSPLAY}" && continue
    cp -r "${dir}" "${s}/Mods/${name}" && printf '%s\n' "${name}" >>"${manifest}"
  done
  if [ "${count}" -gt 0 ] && flux_truthy "${FLUX_CROSSPLAY}"; then
    flux_log "WARN ${count} mod(s) on the mods volume NOT loaded: consoles cannot join a server with mods (FLUX_CROSSPLAY)"
  elif [ "${count}" -gt 0 ]; then
    flux_log "${count} mod(s) installed from the mods volume"
  fi
}

# A backup of the world while nothing is running, so it is always consistent: before every
# start, which with a daily restart is a daily backup.
backup_world() {
  local keep file parts=()
  keep="$(flux_backup_keep "${FLUX_BACKUP_KEEP:-2}")"
  [ "${keep}" -gt 0 ] || return 0
  [ -d "${d}/Saves" ] && parts+=(Saves)
  [ -d "${d}/GeneratedWorlds" ] && parts+=(GeneratedWorlds)
  [ "${#parts[@]}" -gt 0 ] || return 0
  mkdir -p "${FLUX_BACKUP_DIR}"
  file="${FLUX_BACKUP_DIR}/$(date +%Y%m%d-%H%M%S)-world.tar.gz"
  if tar -C "${d}" -cf - "${parts[@]}" 2>/dev/null | gzip -1 >"${file}.part" && mv "${file}.part" "${file}"; then
    flux_log "world backed up to ${file} ($(du -h "${file}" | cut -f1)), keeping the newest ${keep}"
    flux_prune "${FLUX_BACKUP_DIR}" '*-world.tar.gz' "${keep}"
  else
    rm -f "${file}.part"
    flux_log "WARN the world backup failed; starting anyway"
  fi
}

start_generation() {
  local log_file
  generation=$((generation + 1))
  rm -f "${FLUX_RESTART_MARKER}"

  update_server || return 1
  # A stop that arrived during the Steam update: there is no world running to save, and
  # starting one now would only be killed mid-load.
  [ "${terminating}" = "1" ] && return 2
  prepare_config || return 1
  download_mods
  install_mods
  backup_world
  flux_prune "${FLUX_GAME_LOG_DIR}" '*-server.log' "${FLUX_GAME_LOG_KEEP}"
  [ "${terminating}" = "1" ] && return 2

  # A restart asked for while this generation was still being prepared (the Steam update, the
  # backup) has nothing to restart: the server about to start IS the new one. Left in place, the
  # marker read as a request to THIS server, and wait_for_generation killed it FLUX_STOP_GRACE
  # seconds into its start, unsaved, often while it was generating a world.
  if [ -f "${FLUX_RESTART_MARKER}" ]; then
    flux_log "a restart was asked for before the server started ($(cat "${FLUX_RESTART_MARKER}" 2>/dev/null)); starting it fresh instead"
    rm -f "${FLUX_RESTART_MARKER}"
  fi

  log_file="${FLUX_GAME_LOG_DIR}/$(date +%Y%m%d-%H%M%S)-server.log"
  : >"${log_file}"
  flux_log "starting the server (generation ${generation}), log ${log_file}"
  (
    cd "${s}" || exit 1
    export LD_LIBRARY_PATH="${s}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    exec "./${FLUX_GAME_PROCESS}" -logfile "${log_file}" -quit -batchmode -nographics \
      -dedicated -configfile="${FLUX_SERVERCONFIG}"
  ) &
  game_pid=$!

  # The game's log on the container's output, so the platform's app log shows the server.
  tail -n +1 -F "${log_file}" 2>/dev/null &
  tail_pid=$!

  /opt/flux/flux-scheduler.sh &
  scheduler_pid=$!
  return 0
}

sweep_generation() {
  local pid
  for pid in "${scheduler_pid}" "${tail_pid}"; do
    [ -n "${pid}" ] && kill "${pid}" 2>/dev/null
  done
  scheduler_pid="" tail_pid=""
  pkill -KILL -f "${FLUX_GAME_PROCESS}" 2>/dev/null
  game_pid=""
}

# Waits for the game to end. A requested stop or restart that is not honoured within
# FLUX_STOP_GRACE ends it by force.
#
# The grace runs from when THIS request was first seen, and a request that goes away (its marker
# removed) ends it: a later one gets a full grace of its own. The clock used to be kept for the
# rest of the generation, so once any marker had come and gone, the next restart, the daily one
# included, was SIGKILLed the second it was asked for, before its save.
wait_for_generation() {
  local asked_at=0 now
  while kill -0 "${game_pid}" 2>/dev/null; do
    # In the background and waited on, so a signal interrupts the wait at once.
    sleep 1 &
    wait $!
    if [ "${terminating}" = "1" ] || [ -f "${FLUX_RESTART_MARKER}" ]; then
      now="$(date -u +%s)"
      [ "${asked_at}" = "0" ] && asked_at="${now}"
      if [ $((now - asked_at)) -ge "${FLUX_STOP_GRACE}" ]; then
        flux_log "WARN the server was asked to stop ${FLUX_STOP_GRACE}s ago and has not; ending it"
        kill -KILL "${game_pid}" 2>/dev/null
        # Out at once: until `wait` reaps it, the killed process still answers `kill -0`, and the
        # loop logged (and sent) the kill again every second.
        break
      fi
    else
      asked_at=0
    fi
  done
  wait "${game_pid}" 2>/dev/null
}

while true; do
  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request before the server started"
    exit 0
  fi
  start_generation
  started=$?
  if [ "${started}" = "2" ]; then
    flux_log "stopped on request before the server started"
    exit 0
  elif [ "${started}" != "0" ]; then
    flux_log "ERROR the server could not be prepared; ending the container (42)"
    exit 42
  fi
  wait_for_generation
  rc=$?

  reason=""
  if [ -f "${FLUX_RESTART_MARKER}" ]; then
    reason="$(cat "${FLUX_RESTART_MARKER}" 2>/dev/null)"
  fi
  sweep_generation
  rm -f "${FLUX_RESTART_MARKER}"

  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request (server exited ${rc})"
    exit 0
  fi

  [ -z "${reason}" ] && reason="the server ended on its own (exit ${rc})"

  if flux_restart_counts "${reason}"; then
    now="$(date -u +%s)"
    read -r -a restart_history <<<"$(flux_restarts_in_window "${now}" "${FLUX_RESTART_WINDOW}" "${restart_history[@]}")"
    restart_history+=("${now}")
    if [ "${#restart_history[@]}" -gt "${FLUX_RESTART_MAX_ATTEMPTS}" ]; then
      flux_log "${reason}: ${#restart_history[@]} restarts within ${FLUX_RESTART_WINDOW}s, so restarting it here is not working. Ending the container so the platform can rebuild or move it (42)."
      exit 42
    fi
  fi

  flux_log "${reason}: restarting the server in place in ${FLUX_RESTART_BACKOFF}s"
  sleep "${FLUX_RESTART_BACKOFF}" &
  wait $!
done
