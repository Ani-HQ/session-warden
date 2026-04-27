#!/usr/bin/env bash
# scan.sh — cron entry point, runs every 2 minutes
# Scans all OpenClaw sessions for problems, rotates fast, then summarizes async.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="$(dirname "$SCRIPT_DIR")"
export WARDEN_HOME

source "${WARDEN_HOME}/config/thresholds.env"
export WARDEN_DRY_RUN
source "${WARDEN_HOME}/lib/detect.sh"

LOG_FILE="${WARDEN_LOG_FILE}"
LOCKFILE="/tmp/session-warden-scan.lock"

log() {
  echo "[$(date -Iseconds)] $*" >> "$LOG_FILE"
}

# Prevent overlapping scans
exec 199>"$LOCKFILE"
if ! flock -n 199; then
  exit 0  # another scan is running, skip silently
fi

mkdir -p "$(dirname "$LOG_FILE")"

rotated=0

# Scan all agents
for sjson in "${WARDEN_OPENCLAW_HOME}"/agents/*/sessions/sessions.json; do
  [ -f "$sjson" ] || continue
  agent=$(agent_from_sessions_path "$sjson")

  while IFS='|' read -r reason channel_key cli_session_id detail; do
    [ -z "$reason" ] && continue

    "${SCRIPT_DIR}/rotate.sh" "$agent" "$channel_key" "$cli_session_id" "$reason" "$detail"
    rotated=$((rotated + 1))
  done < <(detect_sessions_problems "$sjson")
done

# Restart gateway once if any rotations happened
if [ -f "${WARDEN_HOME}/state/.gateway-restart-pending" ]; then
  last_restart_file="${WARDEN_HOME}/state/.last-gateway-restart"
  now=$(date +%s)
  last=0
  [ -f "$last_restart_file" ] && last=$(cat "$last_restart_file")
  cooldown="${WARDEN_GATEWAY_RESTART_COOLDOWN_SECONDS:-60}"

  if [ $((now - last)) -ge "$cooldown" ]; then
    log "GATEWAY restart triggered ($rotated rotations)"
    if [ "${WARDEN_DRY_RUN:-0}" != "1" ]; then
      openclaw gateway restart >> "$LOG_FILE" 2>&1 || log "WARN: gateway restart non-zero"
    fi
    echo "$now" > "$last_restart_file"
    rm -f "${WARDEN_HOME}/state/.gateway-restart-pending"
  fi
fi

# Process pending summaries async (don't block the scan)
if ls "${WARDEN_HOME}/state/pending-summaries/"*.json 1>/dev/null 2>&1; then
  nohup "${SCRIPT_DIR}/summarize.sh" >> "$LOG_FILE" 2>&1 &
  log "SUMMARY: background processing started (pid=$!)"
fi

if [ "$rotated" -gt 0 ]; then
  log "SCAN complete: rotated $rotated sessions"
fi

flock -u 199
