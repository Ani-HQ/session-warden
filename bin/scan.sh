#!/usr/bin/env bash
# scan.sh — cron entry point, runs every 30 seconds
# Scans all OpenClaw sessions for problems, rotates, summarizes to memory,
# THEN restarts gateway so agents boot with full context.

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

    if "${SCRIPT_DIR}/rotate.sh" "$agent" "$channel_key" "$cli_session_id" "$reason" "$detail"; then
      rotated=$((rotated + 1))
    fi
  done < <(detect_sessions_problems "$sjson")
done

# Summarize SYNCHRONOUSLY before gateway restart — agents must boot with memory
# Timeout at 90s to prevent a hung API call from blocking all scans
if ls "${WARDEN_HOME}/state/pending-summaries/"*.json 1>/dev/null 2>&1; then
  log "SUMMARY: processing synchronously before gateway restart"
  if timeout 90 "${SCRIPT_DIR}/summarize.sh" >> "$LOG_FILE" 2>&1; then
    log "SUMMARY: synchronous processing complete"
  else
    exit_code=$?
    if [ "$exit_code" -eq 124 ]; then
      log "WARN: summarize.sh timed out after 90s — gateway restart will proceed anyway"
    else
      log "WARN: summarize.sh exited with code $exit_code — gateway restart will proceed anyway"
    fi
  fi
fi

# Restart gateway AFTER memory is written so agents boot with full context
if [ "$rotated" -gt 0 ] && command -v openclaw >/dev/null 2>&1; then
  restart_cooldown="${WARDEN_HOME}/state/.gateway-restart-ts"
  now=$(date +%s)
  last_restart=$(cat "$restart_cooldown" 2>/dev/null || echo 0)
  if [ $((now - last_restart)) -ge "${WARDEN_GATEWAY_RESTART_COOLDOWN_SECONDS:-60}" ]; then
    openclaw gateway restart >> "$LOG_FILE" 2>&1 && \
      date +%s > "$restart_cooldown" && \
      log "GATEWAY restarted after memory sync — agents will resume with context" || \
      log "WARN: gateway restart failed"
  fi
fi

if [ "$rotated" -gt 0 ]; then
  log "SCAN complete: rotated $rotated sessions (summarized before restart)"
fi

flock -u 199
