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

# ─── Uninstall against a MOCK crontab ─────────────────────
# This test previously ran `uninstall` against the REAL crontab, stripping the
# live scan/reap entries on every suite run — the warden's own tests unwired
# the warden (the suspected cause of the May 22 silent outage). Never invoke
# uninstall/install here without WARDEN_CRONTAB_CMD pointing at a mock.

mock_cron_state="$SANDBOX/mock-crontab-state"
cat > "$mock_cron_state" <<EOF
0 0 * * * /some/other/job
* * * * * /bin/bash $WARDEN_HOME/bin/scan.sh # session-warden
* * * * * /bin/bash $WARDEN_HOME/bin/reap-stalls.sh # session-warden-reap
EOF

mock_crontab_bin="$SANDBOX/mock-crontab-rw"
cat > "$mock_crontab_bin" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-l" ]; then
  cat "$mock_cron_state"
elif [ "\${1:-}" = "-" ] || [ \$# -eq 0 ]; then
  # Buffer then move: in 'crontab -l | grep | crontab -' both ends run
  # concurrently — truncating the state file directly would race the reader.
  cat > "$mock_cron_state.tmp" && mv "$mock_cron_state.tmp" "$mock_cron_state"
fi
EOF
chmod +x "$mock_crontab_bin"

real_cron_before=$(crontab -l 2>/dev/null)

output=$(WARDEN_CRONTAB_CMD="$mock_crontab_bin" "$CLI" uninstall 2>/dev/null)
assert_contains "$output" "Removed 2 cron entries" "uninstall strips tagged entries"
remaining=$(cat "$mock_cron_state")
assert_contains "$remaining" "/some/other/job" "uninstall keeps untagged entries"
assert_not_contains "$remaining" "session-warden" "uninstall removes all tagged entries"

# Real crontab must be byte-identical before and after this test
real_cron_after=$(crontab -l 2>/dev/null)
assert_eq "$real_cron_before" "$real_cron_after" "real crontab untouched by uninstall test (guard)"
