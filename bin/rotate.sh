#!/usr/bin/env bash
# rotate.sh — fast-path rotation: archive + delete, queue async summary
# Called by scan.sh for each problematic session
# Args: $1=agent $2=channel-key $3=cli-session-id $4=reason $5=detail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="$(dirname "$SCRIPT_DIR")"
source "${WARDEN_HOME}/config/thresholds.env"
source "${WARDEN_HOME}/lib/notify.sh"

log() {
  echo "[$(date -Iseconds)] $*" >> "${WARDEN_LOG_FILE}"
}

agent="$1"
channel_key="$2"
cli_session_id="$3"
reason="$4"
detail="${5:-}"

sessions_json="${WARDEN_OPENCLAW_HOME}/agents/${agent}/sessions/sessions.json"
jsonl_dir="${WARDEN_CLAUDE_PROJECTS}/-home-${USER}--openclaw-agents-${agent}"
jsonl_file="${jsonl_dir}/${cli_session_id}.jsonl"
jsonl_subdir="${jsonl_dir}/${cli_session_id}"
ts=$(date +%Y%m%d-%H%M%S)

LOCK_DIR=/tmp/session-warden-locks
mkdir -p "$LOCK_DIR"
lock_file="${LOCK_DIR}/${agent}.lock"

exec 200>"$lock_file"
if ! flock -w 30 200; then
  log "ERROR: could not acquire lock for $agent"
  exit 1
fi

log "ROTATE start agent=$agent channel=$channel_key reason=$reason"

if [ "${WARDEN_DRY_RUN:-0}" = "1" ]; then
  log "DRY-RUN: would rotate $agent/$channel_key (session=$cli_session_id)"
  flock -u 200
  exit 0
fi

# Step 1: backup sessions.json
cp "$sessions_json" "${sessions_json}.pre-rotate-${ts}" || {
  log "ERROR: backup failed for $sessions_json"
  exit 1
}

# Step 2: archive JSONL (move, don't delete — it's our memory source)
archived_jsonl=""
if [ -f "$jsonl_file" ]; then
  archived_jsonl="${jsonl_file}.archived-${ts}"
  mv "$jsonl_file" "$archived_jsonl" || log "WARN: archive failed for $jsonl_file"
fi
if [ -d "$jsonl_subdir" ]; then
  mv "$jsonl_subdir" "${jsonl_subdir}.archived-${ts}" || log "WARN: subdir archive failed"
fi

# Step 3: remove the session via OpenClaw's native cleanup
# (editing sessions.json directly doesn't stick — gateway overwrites it)
if command -v openclaw >/dev/null 2>&1; then
  openclaw sessions cleanup --agent "$agent" --enforce --fix-missing >> "${WARDEN_LOG_FILE}" 2>&1 || \
    log "WARN: openclaw sessions cleanup returned non-zero"
else
  # Fallback: direct jq edit (works for non-OpenClaw setups)
  jq --arg key "$channel_key" 'del(.[$key])' "$sessions_json" > "${sessions_json}.tmp" && \
    mv "${sessions_json}.tmp" "$sessions_json" || {
    log "ERROR: jq delete failed for $channel_key"
    exit 1
  }
fi

log "ROTATE complete agent=$agent channel=$channel_key (fast path done)"

# Step 4: queue async summary (non-blocking)
if [ -n "$archived_jsonl" ] && [ -f "$archived_jsonl" ]; then
  pending_dir="${WARDEN_HOME}/state/pending-summaries"
  mkdir -p "$pending_dir"
  cat > "${pending_dir}/${agent}-${ts}.json" << EOF
{
  "agent": "${agent}",
  "channel_key": "${channel_key}",
  "cli_session_id": "${cli_session_id}",
  "archived_jsonl": "${archived_jsonl}",
  "timestamp": "${ts}",
  "reason": "${reason}"
}
EOF
  log "SUMMARY queued for async processing"
fi

# Notify
notify_rotation "$agent" "$channel_key" "$reason" "$detail"

# Signal gateway restart needed
touch "${WARDEN_HOME}/state/.gateway-restart-pending"

flock -u 200
