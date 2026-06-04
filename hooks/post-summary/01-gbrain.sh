#!/usr/bin/env bash
# 01-gbrain.sh — ingest session memory into GBrain as a TYPED, LINKED page.
#
# GBrain (https://github.com/garrytan/gbrain) is a self-wiring knowledge graph.
# This hook writes each rotated session as a `note` page linked to its agent
# (performed_by) and to any entities it mentions, so the brain is queryable by
# agent and by entity — not a flat orphan dump.
#
# Env vars set by summarize.sh:
#   WARDEN_AGENT, WARDEN_CHANNEL_KEY, WARDEN_SESSION_ID,
#   WARDEN_MEMORY_FILE, WARDEN_TRANSCRIPT_FILE, WARDEN_ARCHIVED_JSONL
#
# Install GBrain: https://github.com/garrytan/gbrain

WARDEN_HOME="${WARDEN_HOME:-$HOME/session-warden}"
source "${WARDEN_HOME}/lib/gbrain.sh"

gbrain_ingest_session \
  "$WARDEN_AGENT" \
  "$WARDEN_CHANNEL_KEY" \
  "$WARDEN_SESSION_ID" \
  "$WARDEN_MEMORY_FILE" \
  "rotation" \
  | while IFS= read -r line; do echo "[$(date -Iseconds)] $line"; done
