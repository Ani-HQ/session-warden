#!/usr/bin/env bash
# summarize.sh — async post-rotation summarization
# Processes pending summary jobs: extract transcript, summarize with Haiku,
# write to Claude Code's native memory system.
# Called by scan.sh after all rotations are done.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="$(dirname "$SCRIPT_DIR")"
source "${WARDEN_HOME}/config/thresholds.env"
source "${WARDEN_HOME}/lib/extract.sh"
source "${WARDEN_HOME}/lib/memory.sh"

log() {
  echo "[$(date -Iseconds)] $*" >> "${WARDEN_LOG_FILE}"
}

PENDING_DIR="${WARDEN_HOME}/state/pending-summaries"
mkdir -p "$PENDING_DIR"

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

  # Summarize and write to Claude Code memory
  if write_session_memory "$agent" "$channel_key" "$cli_session_id" "$transcript_file"; then
    log "SUMMARY: memory written for $agent/$channel_key"
  else
    log "SUMMARY: memory write failed for $agent/$channel_key"
  fi

  # Run snapshotter if available (GBrain backup)
  if [ -x "${WARDEN_SNAPSHOTTER:-}" ]; then
    "${WARDEN_SNAPSHOTTER}" >> "${WARDEN_LOG_FILE}" 2>&1 || \
      log "SUMMARY: snapshotter failed — non-fatal"
  fi

  # Run post-summary hooks
  local_mem_dir=$(claude_memory_dir "$agent")
  safe_channel=$(echo "$channel_key" | sed 's/[^a-zA-Z0-9_-]/_/g')
  mem_file="${local_mem_dir}/session_${safe_channel}.md"

  for hook in "${WARDEN_HOME}/hooks/post-summary/"*.sh; do
    [ -x "$hook" ] || continue
    log "HOOK: running $(basename "$hook")"
    WARDEN_AGENT="$agent" \
    WARDEN_CHANNEL_KEY="$channel_key" \
    WARDEN_SESSION_ID="$cli_session_id" \
    WARDEN_MEMORY_FILE="$mem_file" \
    WARDEN_TRANSCRIPT_FILE="$transcript_file" \
    WARDEN_ARCHIVED_JSONL="$archived_jsonl" \
      "$hook" >> "${WARDEN_LOG_FILE}" 2>&1 || \
      log "HOOK: $(basename "$hook") failed — non-fatal"
  done

  # Cleanup
  rm -f "$job_file" "$transcript_file"
  log "SUMMARY: done for $agent/$cli_session_id"
done
