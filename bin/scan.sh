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

# Scan agents (allowlist or all)
for sjson in "${WARDEN_OPENCLAW_HOME}"/agents/*/sessions/sessions.json; do
  [ -f "$sjson" ] || continue
  agent=$(agent_from_sessions_path "$sjson")

  if [ -n "${WARDEN_SCAN_AGENTS:-}" ]; then
    echo " ${WARDEN_SCAN_AGENTS} " | grep -q " ${agent} " || continue
  fi

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

# Send recovery messages for FAILED sessions (in background, non-blocking)
# Uses a lock so only one recovery batch runs at a time — prevents process pile-up.
recovery_dir="${WARDEN_HOME}/state/pending-recoveries"
recovery_lock="/tmp/session-warden-recovery.lock"
if [ -d "$recovery_dir" ] && ls "${recovery_dir}"/*.json 1>/dev/null 2>&1; then
  if ! flock -n 198 198>"$recovery_lock" 2>/dev/null; then
    log "RECOVERY: skipping — previous batch still running"
  else
    sending_dir="${recovery_dir}/.sending"
    mkdir -p "$sending_dir"
    for rfile in "${recovery_dir}"/*.json; do
      [ -f "$rfile" ] || continue
      mv "$rfile" "$sending_dir/" 2>/dev/null
    done
    (
      flock 198
      for rfile in "${sending_dir}"/*.json; do
        [ -f "$rfile" ] || continue
        ragent=$(jq -r '.agent' "$rfile")
        rchannel=$(jq -r '.channel_key' "$rfile")

        timeout 180 openclaw agent \
          --agent "$ragent" \
          --session-id "$rchannel" \
          --message "Well, that was embarrassing — your previous session segfaulted into the void. The good news: session-warden saved your memory before the lights went out. Read your session_*.md files to see what past-you was up to. Then tell this channel what happened in your own words — be honest, be brief, be a little self-deprecating about it. No corporate crisis comms, just explain what you were doing, what blew up, and what you'd try differently. Then get back to work." \
          --timeout 120 \
          --deliver \
          >/dev/null 2>&1 && \
          echo "[$(date -Iseconds)] RECOVERY: sent to $ragent/$rchannel" >> "$LOG_FILE" || \
          echo "[$(date -Iseconds)] RECOVERY: failed to send to $ragent/$rchannel (non-fatal)" >> "$LOG_FILE"
        rm -f "$rfile"
      done
      flock -u 198
    ) 198>"$recovery_lock" &
  fi
fi

if [ "$rotated" -gt 0 ]; then
  log "SCAN complete: rotated $rotated sessions (summarized before restart)"
fi

flock -u 199
