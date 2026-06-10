#!/usr/bin/env bash
# test-cleanup.sh — tests for bin/cleanup-archives.sh

echo "  cleanup: old archives deleted"

# ─── Old archives get deleted ─────────────────────────────

archive_dir="$SANDBOX/claude-projects/-home-$(whoami)--openclaw-agents-test-agent"
mkdir -p "$archive_dir"

# Create old archived file (>7 days)
old_archive="$archive_dir/sess-old.jsonl.archived-20260101-000000"
echo '{"old":"data"}' > "$old_archive"
touch -d "10 days ago" "$old_archive"

# Create recent archived file (<7 days)
recent_archive="$archive_dir/sess-recent.jsonl.archived-20260520-000000"
echo '{"recent":"data"}' > "$recent_archive"
touch -d "2 days ago" "$recent_archive"

# Create old sessions.json backup
backup_dir="$SANDBOX/openclaw/agents/test-agent/sessions"
mkdir -p "$backup_dir"
old_backup="$backup_dir/sessions.json.pre-rotate-20260101-000000"
echo '{}' > "$old_backup"
touch -d "10 days ago" "$old_backup"

# Run cleanup
"$WARDEN_HOME/bin/cleanup-archives.sh" 2>/dev/null

assert_file_not_exists "$old_archive" "old archived JSONL deleted"
assert_file_exists "$recent_archive" "recent archived JSONL kept"
assert_file_not_exists "$old_backup" "old sessions.json backup deleted"

echo "  cleanup: empty directory"

# ─── No archives to clean ────────────────────────────────

rm -f "$archive_dir"/*.archived-*

: > "$WARDEN_LOG_FILE"
"$WARDEN_HOME/bin/cleanup-archives.sh" 2>/dev/null
exit_code=$?

# Should complete without error
assert_eq "0" "$exit_code" "cleanup exits 0 with no archives"

echo "  cleanup: retention days config"

# ─── Custom retention days ────────────────────────────────

# Create file that's 3 days old
three_day="$archive_dir/sess-three.jsonl.archived-20260519-000000"
echo '{"data":"three"}' > "$three_day"
touch -d "3 days ago" "$three_day"

# Set retention to 2 days
export WARDEN_ARCHIVE_RETENTION_DAYS=2
"$WARDEN_HOME/bin/cleanup-archives.sh" 2>/dev/null

assert_file_not_exists "$three_day" "3-day file deleted with 2-day retention"

# Reset
export WARDEN_ARCHIVE_RETENTION_DAYS=7

echo "  cleanup: stale queue items purged"

# ─── Stale pending-recoveries / pending-summaries ─────────

rec_dir="$WARDEN_HOME/state/pending-recoveries"
sum_dir="$WARDEN_HOME/state/pending-summaries"
mkdir -p "$rec_dir/.sending" "$sum_dir"

old_rec="$rec_dir/old-recovery.json"
echo '{}' > "$old_rec"; touch -d "10 days ago" "$old_rec"
old_sending="$rec_dir/.sending/old-sending.json"
echo '{}' > "$old_sending"; touch -d "10 days ago" "$old_sending"
fresh_rec="$rec_dir/fresh-recovery.json"
echo '{}' > "$fresh_rec"
old_sum="$sum_dir/old-summary.json"
echo '{}' > "$old_sum"; touch -d "10 days ago" "$old_sum"

"$WARDEN_HOME/bin/cleanup-archives.sh" 2>/dev/null

assert_file_not_exists "$old_rec" "stale pending recovery purged"
assert_file_not_exists "$old_sending" "stale .sending item purged"
assert_file_exists "$fresh_rec" "fresh pending recovery kept"
assert_file_not_exists "$old_sum" "stale pending summary purged"
rm -f "$fresh_rec"

echo "  cleanup: expired cooldown markers"

# ─── Cooldown marker expiry ───────────────────────────────

cd_dir="$WARDEN_HOME/state/cooldowns"
mkdir -p "$cd_dir"

old_recovered="$cd_dir/agent-chan.recovered"
date +%s > "$old_recovered"; touch -d "2 days ago" "$old_recovered"
fresh_recovered="$cd_dir/agent-chan2.recovered"
date +%s > "$fresh_recovered"
old_failures="$cd_dir/agent-chan.failures"
echo 3 > "$old_failures"; touch -d "10 days ago" "$old_failures"
fresh_failures="$cd_dir/agent-chan2.failures"
echo 1 > "$fresh_failures"

"$WARDEN_HOME/bin/cleanup-archives.sh" 2>/dev/null

assert_file_not_exists "$old_recovered" "expired .recovered marker removed"
assert_file_exists "$fresh_recovered" "fresh .recovered marker kept"
assert_file_not_exists "$old_failures" "stale .failures counter removed (resets dead backoff)"
assert_file_exists "$fresh_failures" "fresh .failures counter kept"

echo "  cleanup: scan.log rotation"

# ─── Size-based log rotation ──────────────────────────────

export WARDEN_LOG_MAX_BYTES=1024
head -c 2048 /dev/zero | tr '\0' 'x' > "$WARDEN_LOG_FILE"
echo "preexisting-gen1" > "${WARDEN_LOG_FILE}.1"

"$WARDEN_HOME/bin/cleanup-archives.sh" 2>/dev/null

assert_file_exists "${WARDEN_LOG_FILE}.1" "oversized scan.log rotated to .1"
assert_file_exists "${WARDEN_LOG_FILE}.2" "previous .1 shifted to .2"
rotated_size=$(stat -c%s "${WARDEN_LOG_FILE}.1" 2>/dev/null || echo 0)
assert_gt "$rotated_size" "2000" "rotated .1 contains the oversized log"
log_contents=$(cat "${WARDEN_LOG_FILE}" 2>/dev/null)
assert_contains "$log_contents" "rotated scan.log" "rotation logged to fresh scan.log"

# Under the limit: no rotation
rm -f "${WARDEN_LOG_FILE}".1 "${WARDEN_LOG_FILE}".2
echo "small" > "$WARDEN_LOG_FILE"
"$WARDEN_HOME/bin/cleanup-archives.sh" 2>/dev/null
assert_file_not_exists "${WARDEN_LOG_FILE}.1" "small scan.log not rotated"

unset WARDEN_LOG_MAX_BYTES
