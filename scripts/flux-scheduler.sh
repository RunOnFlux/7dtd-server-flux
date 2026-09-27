#!/bin/bash
# The scheduled restart, one per day, started by the supervisor for each generation.
#
#   FLUX_RESTART_TIME          HH:MM, 24 hour, in the container's TZ. Empty = no scheduled restart.
#   FLUX_RESTART_WARN_MINUTES  how long before it players are warned (0..30, default 5)
#
# A restart is also when the server updates (SteamCMD runs before every start) and when the world
# is backed up, so a daily one keeps a server current and its backups fresh.
#
# Players are warned in chat over the telnet console, at the start of the warning and again one
# minute before. The restart itself is the same save-and-shutdown as a stop; the supervisor then
# starts the next generation. Without the console the restart still happens, just unannounced.

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

target="$(flux_restart_minute_of_day "${FLUX_RESTART_TIME:-}")" || {
  [ -n "${FLUX_RESTART_TIME:-}" ] && flux_log "WARN FLUX_RESTART_TIME='${FLUX_RESTART_TIME}' is not HH:MM; no scheduled restart"
  exit 0
}
warn="$(flux_warn_minutes "${FLUX_RESTART_WARN_MINUTES:-5}")"

# The restart as an absolute time, computed once, so the countdown cannot roll over to tomorrow
# halfway through.
now_h=0 now_m=0 now_s=0
IFS=: read -r now_h now_m now_s <<<"$(date +%H:%M:%S)"
due=$(($(date +%s) + $(flux_seconds_until "${target}" $((10#${now_h} * 60 + 10#${now_m})) $((10#${now_s})))))

flux_log "scheduled restart at ${FLUX_RESTART_TIME} (${TZ:-UTC}), in $(((due - $(date +%s)) / 60)) minutes, with a ${warn} minute warning"

announce() {
  local minutes="$1" unit="minutes"
  [ "${minutes}" = "1" ] && unit="minute"
  if flux_telnet --wait 0.2 "say \"Server restart in ${minutes} ${unit}\"" >/dev/null; then
    flux_log "players warned: restart in ${minutes} ${unit}"
  else
    flux_log "WARN could not warn players over the console"
  fi
}

# Sleeps until $1 seconds before the restart, in steps of at most five minutes so a clock that
# moves is noticed.
sleep_until_before() {
  local left
  while :; do
    left=$((due - $1 - $(date +%s)))
    [ "${left}" -le 0 ] && return 0
    sleep $((left > 300 ? 300 : left))
  done
}

sleep_until_before $((warn * 60))
if [ "${warn}" -gt 0 ]; then
  announce $(((due - $(date +%s) + 59) / 60))
  if [ $((due - $(date +%s))) -gt 90 ]; then
    sleep_until_before 60
    announce 1
  fi
fi
sleep_until_before 0

pid="$(flux_game_pid)"
if [ -z "${pid}" ]; then
  flux_log "scheduled restart due, but the server is not running; nothing to restart"
  exit 0
fi
printf 'scheduled restart at %s' "${FLUX_RESTART_TIME}" >"${FLUX_RESTART_MARKER}"
flux_log "scheduled restart: saving the world and shutting down"
if ! flux_telnet --wait 0.2 saveworld shutdown >/dev/null; then
  flux_log "WARN the console did not answer; stopping the server with a signal"
  kill -TERM "${pid}" 2>/dev/null
fi
