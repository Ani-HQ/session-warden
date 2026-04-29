#!/usr/bin/env bash
# 01-gbrain.sh — ingest session memory into GBrain for cross-agent access
# Env vars set by summarize.sh:
#   WARDEN_AGENT, WARDEN_CHANNEL_KEY, WARDEN_SESSION_ID,
#   WARDEN_MEMORY_FILE, WARDEN_TRANSCRIPT_FILE, WARDEN_ARCHIVED_JSONL

export PATH="$HOME/.bun/bin:$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"

command -v gbrain >/dev/null 2>&1 || { echo "[$(date -Iseconds)] GBRAIN: gbrain not found even after PATH fix"; exit 0; }

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
