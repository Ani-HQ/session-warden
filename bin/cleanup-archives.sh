#!/usr/bin/env bash
# cleanup-archives.sh — delete archived JSONL files older than N days
# Prevents unbounded disk growth from session rotations.
# Run via cron: 30 3 * * * /path/to/session-warden/bin/cleanup-archives.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
source "${WARDEN_HOME}/config/thresholds.env"

RETENTION_DAYS="${WARDEN_ARCHIVE_RETENTION_DAYS:-7}"
CLAUDE_PROJECTS="${WARDEN_CLAUDE_PROJECTS:-$HOME/.claude/projects}"
LOG_FILE="${WARDEN_LOG_FILE:-$HOME/session-warden/state/scan.log}"

log() {
  echo "[$(date -Iseconds)] $*" >> "$LOG_FILE"
}

deleted=0
freed_bytes=0

while IFS= read -r -d '' file; do
  size=$(stat -c%s "$file" 2>/dev/null || echo 0)
  rm -f "$file"
  deleted=$((deleted + 1))
  freed_bytes=$((freed_bytes + size))
done < <(find "$CLAUDE_PROJECTS" -name "*.jsonl.archived-*" -mtime +"$RETENTION_DAYS" -print0 2>/dev/null)

# Also clean up old sessions.json backups
while IFS= read -r -d '' file; do
  rm -f "$file"
  deleted=$((deleted + 1))
done < <(find "${WARDEN_OPENCLAW_HOME}/agents" -name "sessions.json.pre-rotate-*" -mtime +"$RETENTION_DAYS" -print0 2>/dev/null)

if [ "$deleted" -gt 0 ]; then
  freed_mb=$((freed_bytes / 1048576))
  log "CLEANUP: deleted $deleted archived files older than ${RETENTION_DAYS}d (freed ~${freed_mb}MB)"
fi
