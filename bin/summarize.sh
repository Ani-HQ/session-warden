#!/usr/bin/env bash
# summarize.sh — post-rotation summarization (runs synchronously before gateway restart)
# Processes pending summary jobs: extract transcript, summarize with Haiku,
# write to Claude Code's native memory system.
# Called by scan.sh BEFORE gateway restart so agents boot with full context.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
source "${WARDEN_HOME}/config/thresholds.env"
source "${WARDEN_HOME}/lib/extract.sh"
source "${WARDEN_HOME}/lib/memory.sh"
source "${WARDEN_HOME}/lib/gbrain.sh"   # gbrain_available, gbrain_slugify (GBrain refs)

log() {
  echo "[$(date -Iseconds)] $*" >> "${WARDEN_LOG_FILE}"
}

PENDING_DIR="${WARDEN_HOME}/state/pending-summaries"
mkdir -p "$PENDING_DIR"

SUMMARIZE_LOCK="${WARDEN_HOME}/state/summarize.lock"
exec 198>"$SUMMARIZE_LOCK"
if ! flock -w 120 198; then
  log "SUMMARY: timed out waiting for lock (120s) — proceeding without summary"
  exit 1
fi

for job_file in "$PENDING_DIR"/*.json; do
  [ -f "$job_file" ] || continue

  agent=$(jq -r '.agent' "$job_file")
  channel_key=$(jq -r '.channel_key' "$job_file")
  cli_session_id=$(jq -r '.cli_session_id' "$job_file")
  archived_jsonl=$(jq -r '.archived_jsonl' "$job_file")

  if [ ! -f "$archived_jsonl" ]; then
    log "SUMMARY: archived JSONL missing for $agent/$cli_session_id — skipping"
    rm -f "$job_file"
    continue
  fi

  log "SUMMARY: processing $agent/$cli_session_id"

  # Extract full transcript (text + tool actions)
  transcript_file="${WARDEN_HOME}/state/${agent}-${cli_session_id}.transcript"
  extract_session_transcript "$archived_jsonl" > "$transcript_file"

  transcript_lines=$(wc -l < "$transcript_file")
  transcript_bytes=$(stat -c%s "$transcript_file")
  log "SUMMARY: extracted ${transcript_lines} lines, ${transcript_bytes} bytes"

  if [ "$transcript_bytes" -lt 10 ]; then
    log "SUMMARY: transcript too small — skipping"
    rm -f "$job_file" "$transcript_file"
    continue
  fi

  local_mem_dir=$(claude_memory_dir "$agent")
  safe_channel=$(echo "$channel_key" | sed 's/[^a-zA-Z0-9_-]/_/g')
  mem_file="${local_mem_dir}/session_${safe_channel}.md"

  # Summarize and write to Claude Code memory
  if write_session_memory "$agent" "$channel_key" "$cli_session_id" "$transcript_file"; then
    log "SUMMARY: memory written for $agent/$channel_key"
    # GBrain refs: the post-summary gbrain hook writes this session's typed
    # page at a deterministic slug, and context-sync keeps a rolling live
    # page per session. Point at them instead of restating their facts.
    if [ -f "$mem_file" ] && gbrain_available; then
      {
        echo ""
        echo "## GBrain refs"
        echo "- Rotation page: \`gbrain get session-warden/$(date +%Y-%m-%d)/${agent}-${cli_session_id:0:8}\`"
        echo "- Live page: \`gbrain get session-warden/live/${agent}-$(gbrain_slugify "$channel_key")\`"
      } >> "$mem_file"
    fi
  else
    log "SUMMARY: memory write failed for $agent/$channel_key"
  fi

  # Run hooks in BACKGROUND — memory is written, don't block gateway restart

  (
    exec 198>&-
    for hook in "${WARDEN_HOME}/hooks/post-summary/"*.sh; do
      [ -x "$hook" ] || continue
      echo "[$(date -Iseconds)] HOOK: running $(basename "$hook")" >> "${WARDEN_LOG_FILE}"
      WARDEN_AGENT="$agent" \
      WARDEN_CHANNEL_KEY="$channel_key" \
      WARDEN_SESSION_ID="$cli_session_id" \
      WARDEN_MEMORY_FILE="$mem_file" \
      WARDEN_TRANSCRIPT_FILE="$transcript_file" \
      WARDEN_ARCHIVED_JSONL="$archived_jsonl" \
        "$hook" >> "${WARDEN_LOG_FILE}" 2>&1 || \
        echo "[$(date -Iseconds)] HOOK: $(basename "$hook") failed — non-fatal" >> "${WARDEN_LOG_FILE}"
    done

    rm -f "$transcript_file"
  ) &

  # Cleanup job file immediately — memory is written, hooks are async
  rm -f "$job_file"
  log "SUMMARY: done for $agent/$cli_session_id (hooks deferred to background)"
done
