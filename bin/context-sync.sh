#!/usr/bin/env bash
# context-sync.sh — periodic context capture for active sessions
# Snapshots JSONL transcripts from active CLI sessions into MEMORY.md/CONTEXT.md
# so agents always have fresh context on restart. Runs every 5 minutes via cron.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
source "${WARDEN_HOME}/config/thresholds.env"
source "${WARDEN_HOME}/lib/portable.sh"   # stat_mtime / stat_size
source "${WARDEN_HOME}/lib/extract.sh"
source "${WARDEN_HOME}/lib/memory.sh"
source "${WARDEN_HOME}/lib/gbrain.sh"

LOG_FILE="${WARDEN_LOG_FILE}"
LOCKFILE="${WARDEN_HOME}/state/context-sync.lock"

log() {
  echo "[$(date -Iseconds)] $*" >> "$LOG_FILE"
}

exec 197>"$LOCKFILE"
if ! flock -n 197; then
  exit 0
fi

synced=0

for sjson in "${WARDEN_OPENCLAW_HOME}"/agents/*/sessions/sessions.json; do
  [ -f "$sjson" ] || continue
  agent=$(echo "$sjson" | sed -E 's|.*/agents/([^/]+)/sessions/.*|\1|')

  if [ -n "${WARDEN_SCAN_AGENTS:-}" ]; then
    echo " ${WARDEN_SCAN_AGENTS} " | grep -q " ${agent} " || continue
  fi

  jsonl_base="${WARDEN_CLAUDE_PROJECTS}/-home-$(whoami)--openclaw-agents-${agent}"

  while IFS='|' read -r channel_key cli_session_id status; do
    [ -z "$cli_session_id" ] && continue

    jsonl_file="${jsonl_base}/${cli_session_id}.jsonl"
    [ -f "$jsonl_file" ] || continue

    # Only sync if JSONL has been modified since last sync
    state_file="${WARDEN_HOME}/state/context-sync/${agent}-$(echo "$channel_key" | sed 's/[^a-zA-Z0-9_-]/_/g').mtime"
    mkdir -p "${WARDEN_HOME}/state/context-sync"

    jsonl_mtime=$(stat_mtime "$jsonl_file")
    last_sync_mtime=$(cat "$state_file" 2>/dev/null || echo 0)

    if [ "$jsonl_mtime" -le "$last_sync_mtime" ]; then
      continue
    fi

    jsonl_bytes=$(stat_size "$jsonl_file")
    if [ "$jsonl_bytes" -lt 100 ]; then
      continue
    fi

    log "CONTEXT-SYNC: capturing $agent/$channel_key (JSONL ${jsonl_bytes}B, modified since last sync)"

    transcript_file="${WARDEN_HOME}/state/${agent}-context-sync.transcript"
    extract_session_transcript "$jsonl_file" > "$transcript_file"

    transcript_bytes=$(stat_size "$transcript_file")
    if [ "$transcript_bytes" -lt 20 ]; then
      rm -f "$transcript_file"
      continue
    fi

    if write_session_memory "$agent" "$channel_key" "$cli_session_id" "$transcript_file"; then
      echo "$jsonl_mtime" > "$state_file"
      synced=$((synced + 1))
      log "CONTEXT-SYNC: updated $agent/$channel_key"

      # Push live context to GBrain so healthy long-running sessions are in the
      # graph too — not just rotated ones. Upserts a single live page per
      # session (mode=live). Embedding is deferred to the nightly dream-cycle.
      mem_dir=$(claude_memory_dir "$agent")
      live_mem_file="${mem_dir}/session_$(echo "$channel_key" | sed 's/[^a-zA-Z0-9_-]/_/g').md"
      gbrain_ingest_session "$agent" "$channel_key" "$cli_session_id" "$live_mem_file" "live" \
        >> "$LOG_FILE" 2>&1 || log "CONTEXT-SYNC: gbrain ingest failed for $agent/$channel_key (non-fatal)"
    else
      log "CONTEXT-SYNC: write failed for $agent/$channel_key"
    fi

    rm -f "$transcript_file"
  done < <(jq -r '
    to_entries[] |
    select(.value.cliSessionIds["claude-cli"] // "" | length > 0) |
    "\(.key)|\(.value.cliSessionIds["claude-cli"])|\(.value.status // "active")"
  ' "$sjson" 2>/dev/null)
done

if [ "$synced" -gt 0 ]; then
  log "CONTEXT-SYNC: synced $synced sessions"
fi

flock -u 197
