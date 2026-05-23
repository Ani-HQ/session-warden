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
