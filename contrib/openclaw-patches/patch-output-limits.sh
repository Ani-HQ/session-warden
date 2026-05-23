#!/usr/bin/env bash
# patch-output-limits.sh — bump OpenClaw's turn output limits in compiled JS
# MUST be re-run after every `npm update openclaw` or `npm install -g openclaw`
# Upstream feature request needed to move these into openclaw.json

set -euo pipefail

OPENCLAW_DIST="${HOME}/.npm-global/lib/node_modules/openclaw/dist"
TARGET_BUFFER="8 * 1024 * 1024"   # 8MB per-line buffer (default: 256KB, kills image messages)
TARGET_CHARS="32 * 1024 * 1024"   # 32MB per-turn total (default: 1MB)
TARGET_LINES="20e3"               # 20K lines (default: 2000)

RUNTIME_FILE=$(ls "${OPENCLAW_DIST}"/execute.runtime-*.js 2>/dev/null | head -1)

if [ -z "$RUNTIME_FILE" ]; then
  echo "ERROR: openclaw runtime file not found in $OPENCLAW_DIST" >&2
  exit 1
fi

current_buffer=$(grep -oP 'CLAUDE_LIVE_MAX_STDOUT_BUFFER_CHARS = \K[^;]+' "$RUNTIME_FILE")
current_chars=$(grep -oP 'CLAUDE_LIVE_MAX_TURN_RAW_CHARS = \K[^;]+' "$RUNTIME_FILE")
current_lines=$(grep -oP 'CLAUDE_LIVE_MAX_TURN_LINES = \K[^;]+' "$RUNTIME_FILE")

echo "Current: BUFFER=$current_buffer, CHARS=$current_chars, LINES=$current_lines"

if [ "$current_buffer" = "$TARGET_BUFFER" ] && [ "$current_chars" = "$TARGET_CHARS" ] && [ "$current_lines" = "$TARGET_LINES" ]; then
  echo "Already patched. No changes needed."
  exit 0
fi

cp "$RUNTIME_FILE" "${RUNTIME_FILE}.pre-patch-$(date +%Y%m%d-%H%M%S)"

sed -i "s/CLAUDE_LIVE_MAX_STDOUT_BUFFER_CHARS = [^;]*/CLAUDE_LIVE_MAX_STDOUT_BUFFER_CHARS = ${TARGET_BUFFER}/" "$RUNTIME_FILE"
sed -i "s/CLAUDE_LIVE_MAX_TURN_RAW_CHARS = [^;]*/CLAUDE_LIVE_MAX_TURN_RAW_CHARS = ${TARGET_CHARS}/" "$RUNTIME_FILE"
sed -i "s/CLAUDE_LIVE_MAX_TURN_LINES = [^;]*/CLAUDE_LIVE_MAX_TURN_LINES = ${TARGET_LINES}/" "$RUNTIME_FILE"

new_buffer=$(grep -oP 'CLAUDE_LIVE_MAX_STDOUT_BUFFER_CHARS = \K[^;]+' "$RUNTIME_FILE")
new_chars=$(grep -oP 'CLAUDE_LIVE_MAX_TURN_RAW_CHARS = \K[^;]+' "$RUNTIME_FILE")
new_lines=$(grep -oP 'CLAUDE_LIVE_MAX_TURN_LINES = \K[^;]+' "$RUNTIME_FILE")

echo "Patched: BUFFER=$new_buffer, CHARS=$new_chars, LINES=$new_lines"
echo "Restart gateway to apply: openclaw gateway restart"
