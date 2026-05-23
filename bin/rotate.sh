#!/usr/bin/env bash
# rotate.sh — fast-path rotation: archive + delete, queue async summary
# Called by scan.sh for each problematic session
# Args: $1=agent $2=channel-key $3=cli-session-id $4=reason $5=detail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
source "${WARDEN_HOME}/config/thresholds.env"
source "${WARDEN_HOME}/lib/notify.sh"
source "${WARDEN_HOME}/lib/channel-history.sh"

log() {
  echo "[$(date -Iseconds)] $*" >> "${WARDEN_LOG_FILE}"
}

agent="$1"
channel_key="$2"
cli_session_id="$3"
reason="$4"
detail="${5:-}"

sessions_json="${WARDEN_OPENCLAW_HOME}/agents/${agent}/sessions/sessions.json"
jsonl_dir="${WARDEN_CLAUDE_PROJECTS}/-home-$(whoami)--openclaw-agents-${agent}"
if [ -n "$cli_session_id" ]; then
  jsonl_file="${jsonl_dir}/${cli_session_id}.jsonl"
  jsonl_subdir="${jsonl_dir}/${cli_session_id}"
else
  jsonl_file=""
  jsonl_subdir=""
fi
ts=$(date +%Y%m%d-%H%M%S)

LOCK_DIR="${WARDEN_HOME}/state/locks"
mkdir -p "$LOCK_DIR"
lock_file="${LOCK_DIR}/${agent}.lock"

exec 200>"$lock_file"
if ! flock -w 30 200; then
  log "ERROR: could not acquire lock for $agent"
  exit 1
fi

COOLDOWN_DIR="${WARDEN_HOME}/state/cooldowns"
mkdir -p "$COOLDOWN_DIR"
cooldown_file="${COOLDOWN_DIR}/${agent}-$(echo "$channel_key" | sed 's/[^a-zA-Z0-9_-]/_/g')"
COOLDOWN_SECONDS="${WARDEN_COOLDOWN_SECONDS:-600}"

if [ -f "$cooldown_file" ]; then
  last_rotate=$(cat "$cooldown_file" 2>/dev/null || echo 0)
  now=$(date +%s)
  elapsed=$((now - last_rotate))
  if [ "$elapsed" -lt "$COOLDOWN_SECONDS" ]; then
    log "COOLDOWN: skipping $agent/$channel_key (rotated ${elapsed}s ago, cooldown=${COOLDOWN_SECONDS}s)"
    flock -u 200
    exit 2
  fi
fi

# Consecutive failure limit: stop rotating after N failures to prevent crash loops
WARDEN_MAX_CONSECUTIVE_FAILURES="${WARDEN_MAX_CONSECUTIVE_FAILURES:-3}"
fail_counter_file="${COOLDOWN_DIR}/${agent}-$(echo "$channel_key" | sed 's/[^a-zA-Z0-9_-]/_/g').failures"
if [ "$reason" = "FAILED" ] || [ "$reason" = "ZOMBIE" ]; then
  fail_count=$(cat "$fail_counter_file" 2>/dev/null || echo 0)
  if [ "$fail_count" -ge "$WARDEN_MAX_CONSECUTIVE_FAILURES" ]; then
    log "BACKOFF: $agent/$channel_key has failed $fail_count consecutive times — manual intervention needed"
    flock -u 200
    exit 2
  fi
fi

# Mid-turn protection: if the JSONL was modified in the last 60s, the agent is
# actively working. Defer rotation to avoid killing it mid-response.
WARDEN_ACTIVE_THRESHOLD_SECS="${WARDEN_ACTIVE_THRESHOLD_SECS:-60}"
if [ -n "$jsonl_file" ] && [ -f "$jsonl_file" ]; then
  jsonl_mtime=$(stat -c%Y "$jsonl_file" 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  age=$((now_epoch - jsonl_mtime))
  if [ "$age" -lt "$WARDEN_ACTIVE_THRESHOLD_SECS" ]; then
    log "DEFERRED: $agent/$channel_key — JSONL modified ${age}s ago (threshold=${WARDEN_ACTIVE_THRESHOLD_SECS}s), agent likely mid-turn"
    flock -u 200
    exit 2
  fi
fi

log "ROTATE start agent=$agent channel=$channel_key reason=$reason"

if [ "${WARDEN_DRY_RUN:-0}" = "1" ]; then
  log "DRY-RUN: would rotate $agent/$channel_key (session=$cli_session_id)"
  flock -u 200
  exit 0
fi

# Graceful shutdown: ask agent to save state before we kill it.
# Only for threshold-based rotations (agent is likely alive and can respond).
WARDEN_GRACEFUL_TIMEOUT="${WARDEN_GRACEFUL_TIMEOUT:-20}"
if [[ "$reason" =~ ^(TOKENS|TURNS|COMPACTIONS)$ ]] && command -v openclaw >/dev/null 2>&1; then
  log "GRACEFUL: asking $agent to save state (${WARDEN_GRACEFUL_TIMEOUT}s timeout)"
  timeout "$WARDEN_GRACEFUL_TIMEOUT" openclaw agent \
    --agent "$agent" \
    --session-id "$channel_key" \
    --message "SESSION ROTATION IMMINENT: Your session will be rotated in ${WARDEN_GRACEFUL_TIMEOUT} seconds due to ${reason} threshold. Write all pending work, decisions, and context to your memory files NOW. Be specific: file paths, branch names, what you were doing, what's left to do." \
    --timeout "$((WARDEN_GRACEFUL_TIMEOUT - 5))" \
    --json >/dev/null 2>&1 && \
    log "GRACEFUL: $agent acknowledged rotation" || \
    log "GRACEFUL: $agent did not respond (non-fatal, proceeding)"
fi

# Step 1: backup sessions.json
cp "$sessions_json" "${sessions_json}.pre-rotate-${ts}" || {
  log "ERROR: backup failed for $sessions_json"
  exit 1
}

# Step 2: archive JSONL (move, don't delete — it's our memory source)
archived_jsonl=""
if [ -n "$jsonl_file" ] && [ -f "$jsonl_file" ]; then
  archived_jsonl="${jsonl_file}.archived-${ts}"
  mv "$jsonl_file" "$archived_jsonl" || log "WARN: archive failed for $jsonl_file"
fi
if [ -n "$jsonl_subdir" ] && [ -d "$jsonl_subdir" ]; then
  mv "$jsonl_subdir" "${jsonl_subdir}.archived-${ts}" || log "WARN: subdir archive failed"
fi

# Step 3: remove the session via OpenClaw's native cleanup
if command -v openclaw >/dev/null 2>&1; then
  openclaw sessions cleanup --agent "$agent" --enforce --fix-missing >> "${WARDEN_LOG_FILE}" 2>&1 || \
    log "WARN: openclaw sessions cleanup returned non-zero"
fi

# Always null out cliSessionIds for the rotated channel so zombie detection
# won't re-trigger. The gateway may overwrite this, but gateway restart
# (which follows in scan.sh) will read the cleaned state.
if [ -f "$sessions_json" ]; then
  jq --arg key "$channel_key" '
    if has($key) then
      .[$key].cliSessionIds = null |
      .[$key].claudeCliSessionId = null |
      .[$key].cliSessionBindings = null
    else . end
  ' "$sessions_json" > "${sessions_json}.tmp" && \
    mv "${sessions_json}.tmp" "$sessions_json" || \
    log "WARN: jq session cleanup failed for $channel_key"
fi

date +%s > "$cooldown_file"

# Track consecutive failures; reset on successful non-failure rotations
if [ "$reason" = "FAILED" ] || [ "$reason" = "ZOMBIE" ]; then
  echo $(( $(cat "$fail_counter_file" 2>/dev/null || echo 0) + 1 )) > "$fail_counter_file"
else
  rm -f "$fail_counter_file"
fi

log "ROTATE complete agent=$agent channel=$channel_key (fast path done)"

# Step 3.5: capture crash buffer for ALL rotations (not just failures).
# Fetches recent Discord/Telegram messages so the agent boots knowing what
# the user said right before rotation. Must run BEFORE summary.
if true; then
  log "CRASH-BUFFER: capturing for $agent/$channel_key (reason=$reason)"
  _cb_updated_at=$(jq -r --arg key "$channel_key" '.[$key].updatedAt // 0' "$sessions_json" 2>/dev/null)
  if capture_crash_buffer "$agent" "$channel_key" "${_cb_updated_at:-0}"; then
    log "CRASH-BUFFER: captured successfully"
  else
    log "CRASH-BUFFER: nothing to capture (no unprocessed messages or channel not supported)"
  fi
fi

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

# Queue recovery message for ALL rotated sessions — sent after gateway restart
if true; then
  recovery_dir="${WARDEN_HOME}/state/pending-recoveries"
  mkdir -p "$recovery_dir"
  cat > "${recovery_dir}/${agent}-${ts}.json" << REOF
{
  "agent": "${agent}",
  "channel_key": "${channel_key}",
  "reason": "${reason}",
  "timestamp": "${ts}"
}
REOF
  log "RECOVERY: queued post-restart message for $agent/$channel_key"
fi

# Notify
notify_rotation "$agent" "$channel_key" "$reason" "$detail"


flock -u 200
