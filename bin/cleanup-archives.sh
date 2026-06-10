#!/usr/bin/env bash
# cleanup-archives.sh — bounded growth for everything the warden writes:
# archived JSONLs, scan.log (size-based rotation), stale queue items, and
# expired cooldown markers.
# Run via cron: 30 3 * * * /path/to/session-warden/bin/cleanup-archives.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
source "${WARDEN_HOME}/config/thresholds.env"

RETENTION_DAYS="${WARDEN_ARCHIVE_RETENTION_DAYS:-7}"
QUEUE_RETENTION_DAYS="${WARDEN_QUEUE_RETENTION_DAYS:-7}"
COOLDOWN_RETENTION_DAYS="${WARDEN_COOLDOWN_RETENTION_DAYS:-7}"
LOG_MAX_BYTES="${WARDEN_LOG_MAX_BYTES:-10485760}"
LOG_KEEP="${WARDEN_LOG_KEEP:-3}"
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

# ─── Stale queue items ────────────────────────────────────
# pending-recoveries (incl. the .sending sub-queue) and pending-summaries that
# nothing consumed within the retention window are dead — re-delivering a
# week-old recovery message would confuse the agent, not help it.
queue_purged=0
for qdir in "${WARDEN_HOME}/state/pending-recoveries" \
            "${WARDEN_HOME}/state/pending-recoveries/.sending" \
            "${WARDEN_HOME}/state/pending-summaries"; do
  [ -d "$qdir" ] || continue
  while IFS= read -r -d '' file; do
    rm -f "$file"
    queue_purged=$((queue_purged + 1))
  done < <(find "$qdir" -maxdepth 1 -name "*.json" -mtime +"$QUEUE_RETENTION_DAYS" -print0 2>/dev/null)
done
[ "$queue_purged" -gt 0 ] && log "CLEANUP: purged $queue_purged stale queue items older than ${QUEUE_RETENTION_DAYS}d"

# ─── Expired cooldown markers ─────────────────────────────
# .recovered markers only matter for 2h (scan.sh skip window); anything older
# than a day is dead weight. .failures counters untouched for the retention
# window are stale backoff state — deleting them lets recovery retry channels
# that got stuck in "manual intervention needed" during an outage.
cooldown_purged=0
if [ -d "${WARDEN_HOME}/state/cooldowns" ]; then
  while IFS= read -r -d '' file; do
    rm -f "$file"
    cooldown_purged=$((cooldown_purged + 1))
  done < <(find "${WARDEN_HOME}/state/cooldowns" -name "*.recovered" -mtime +1 -print0 2>/dev/null)
  while IFS= read -r -d '' file; do
    rm -f "$file"
    cooldown_purged=$((cooldown_purged + 1))
  done < <(find "${WARDEN_HOME}/state/cooldowns" -name "*.failures" -mtime +"$COOLDOWN_RETENTION_DAYS" -print0 2>/dev/null)
fi
[ "$cooldown_purged" -gt 0 ] && log "CLEANUP: removed $cooldown_purged expired cooldown markers"

# ─── scan.log rotation ────────────────────────────────────
# Size-based, self-contained (no logrotate dependency). scan.log -> .1 -> .2 ...
log_bytes=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
if [ "$log_bytes" -gt "$LOG_MAX_BYTES" ]; then
  i=$((LOG_KEEP - 1))
  while [ "$i" -ge 1 ]; do
    # mv overwrites .(i+1), so the oldest generation falls off naturally
    [ -f "${LOG_FILE}.${i}" ] && mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
    i=$((i - 1))
  done
  mv "$LOG_FILE" "${LOG_FILE}.1"
  log "CLEANUP: rotated scan.log ($((log_bytes / 1048576))MB > $((LOG_MAX_BYTES / 1048576))MB), keeping ${LOG_KEEP} generations"
fi
