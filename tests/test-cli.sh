#!/usr/bin/env bash
# test-cli.sh — tests for bin/session-warden CLI entrypoint

CLI="$WARDEN_HOME/bin/session-warden"

echo "  cli: help output"

# ─── Help command ─────────────────────────────────────────

output=$("$CLI" help 2>/dev/null)
assert_contains "$output" "session-warden" "help shows tool name"
assert_contains "$output" "scan" "help lists scan command"
assert_contains "$output" "status" "help lists status command"
assert_contains "$output" "rotate" "help lists rotate command"
assert_contains "$output" "install" "help lists install command"
assert_contains "$output" "logs" "help lists logs command"
assert_contains "$output" "version" "help lists version command"

echo "  cli: help flags"

# ─── Help flags ───────────────────────────────────────────

output_h=$("$CLI" -h 2>/dev/null)
assert_contains "$output_h" "session-warden" "-h shows help"

output_help=$("$CLI" --help 2>/dev/null)
assert_contains "$output_help" "session-warden" "--help shows help"

echo "  cli: version"

# ─── Version command ──────────────────────────────────────

output=$("$CLI" version 2>/dev/null)
assert_contains "$output" "session-warden" "version shows tool name"
assert_matches "$output" "[0-9]+\.[0-9]+\.[0-9]+" "version contains semver"

output_v=$("$CLI" -v 2>/dev/null)
assert_contains "$output_v" "session-warden" "-v shows version"

output_version=$("$CLI" --version 2>/dev/null)
assert_contains "$output_version" "session-warden" "--version shows version"

echo "  cli: unknown command"

# ─── Unknown command ──────────────────────────────────────

output=$("$CLI" nonexistent 2>/dev/null)
exit_code=$?
assert_eq "1" "$exit_code" "unknown command exits 1"
assert_contains "$output" "Unknown command" "unknown command shows error"

echo "  cli: rotate missing args"

# ─── Rotate with missing args ────────────────────────────

output=$("$CLI" rotate 2>/dev/null)
exit_code=$?
assert_eq "1" "$exit_code" "rotate without args exits 1"
assert_contains "$output" "Usage:" "rotate shows usage"

echo "  cli: rotate with invalid agent"

# ─── Rotate with nonexistent agent ────────────────────────

output=$("$CLI" rotate "nonexistent-agent" "some-channel" 2>/dev/null)
exit_code=$?
assert_eq "1" "$exit_code" "rotate with invalid agent exits 1"
assert_contains "$output" "ERROR" "rotate shows error for invalid agent"

echo "  cli: rotate with invalid channel"

# ─── Rotate with nonexistent channel ─────────────────────

create_sessions_json "test-agent" '{
  "discord-general": {
    "totalTokens": 100000,
    "numTurns": 50,
    "compactionCount": 1,
    "status": "idle",
    "updatedAt": '"$(now_ms)"',
    "cliSessionIds": {"claude-cli": "sess-cli-001"}
  }
}'

output=$("$CLI" rotate "test-agent" "nonexistent-channel" 2>/dev/null)
exit_code=$?
assert_eq "1" "$exit_code" "rotate with invalid channel exits 1"
assert_contains "$output" "Available channels" "shows available channels on error"
assert_contains "$output" "discord-general" "lists valid channels"

echo "  cli: no-arg shows help"

# ─── No arguments ────────────────────────────────────────

output=$("$CLI" 2>/dev/null)
assert_contains "$output" "session-warden" "no args shows help"
assert_contains "$output" "scan" "no args lists commands"

echo "  cli: uninstall"

# ─── Uninstall (safe: test won't actually modify real crontab) ──

# This test just verifies the function exists and runs
# We don't actually test crontab modification to avoid side effects
output=$("$CLI" uninstall 2>/dev/null)
assert_contains "$output" "session-warden" "uninstall mentions session-warden"
