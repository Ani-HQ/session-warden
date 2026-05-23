#!/usr/bin/env bash
# 01-gbrain.sh — ingest session memory into GBrain after rotation
#
# GBrain is session-warden's recommended knowledge base for cross-agent memory.
# After each rotation, this hook pushes the summarized memory into GBrain so
# other agents (or humans) can query what happened across all sessions.
#
# Install GBrain: https://github.com/garrytan/gbrain
#
# Env vars set by summarize.sh:
#   WARDEN_AGENT           — agent name
#   WARDEN_CHANNEL_KEY     — full channel key
#   WARDEN_SESSION_ID      — Claude CLI session ID
#   WARDEN_MEMORY_FILE     — path to the generated memory file
#   WARDEN_TRANSCRIPT_FILE — path to the extracted transcript
#   WARDEN_ARCHIVED_JSONL  — path to the archived JSONL

export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:/usr/local/bin:$PATH"

command -v gbrain >/dev/null 2>&1 || {
  echo "[$(date -Iseconds)] GBRAIN: gbrain CLI not found in PATH — skipping"
  exit 0
}

[ -f "$WARDEN_MEMORY_FILE" ] || exit 0

short_id="${WARDEN_SESSION_ID:0:8}"
date_str=$(date +%Y-%m-%d)
slug="session-warden/${date_str}/${WARDEN_AGENT}-${short_id}"

content=$(cat "$WARDEN_MEMORY_FILE")

if echo "$content" | gbrain put "$slug" 2>&1; then
  gbrain tag "$slug" "session-warden" 2>&1
  gbrain tag "$slug" "$WARDEN_AGENT" 2>&1
  gbrain tag "$slug" "rotation" 2>&1
  gbrain timeline-add "$slug" "$date_str" "Session rotated: ${WARDEN_AGENT} (${WARDEN_CHANNEL_KEY})" 2>&1
  echo "[$(date -Iseconds)] GBRAIN: ingested $slug"
else
  echo "[$(date -Iseconds)] GBRAIN: failed to ingest $slug"
fi
