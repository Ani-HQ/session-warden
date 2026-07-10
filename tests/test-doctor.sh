#!/usr/bin/env bash
# test-doctor.sh — tests for bin/doctor.sh (warden self-health)

echo "  doctor: healthy system"

# ─── Mock crontab with full wiring ───────────────────────

mock_crontab="$SANDBOX/mock-crontab-full"
cat > "$mock_crontab" <<EOF
#!/usr/bin/env bash
cat <<'CRON'
* * * * * /bin/bash $WARDEN_HOME/bin/scan.sh # session-warden
* * * * * sleep 30 && /bin/bash $WARDEN_HOME/bin/scan.sh # session-warden-30s
* * * * * /bin/bash $WARDEN_HOME/bin/reap-stalls.sh # session-warden-reap
* * * * * sleep 30 && /bin/bash $WARDEN_HOME/bin/reap-stalls.sh # session-warden-reap-30s
*/5 * * * * /bin/bash $WARDEN_HOME/bin/doctor.sh --alert # session-warden-doctor
CRON
EOF
chmod +x "$mock_crontab"

export WARDEN_CRONTAB_CMD="$mock_crontab"
export WARDEN_DOCTOR_SKIP_GATEWAY=1
export WARDEN_DOCTOR_CHECK_PATCHES=0

# Fresh heartbeats
touch "$WARDEN_HOME/state/.last-scan-ts" "$WARDEN_HOME/state/.last-reap-ts"

output=$("$WARDEN_HOME/bin/doctor.sh" 2>&1)
exit_code=$?

assert_eq "0" "$exit_code" "doctor exits 0 when healthy"
assert_contains "$output" "HEALTHY" "doctor reports HEALTHY"
assert_contains "$output" "scan loop alive" "scan heartbeat recognized"
assert_contains "$output" "reaper alive" "reap heartbeat recognized"

echo "  doctor: unwired core loop"

# ─── Crontab missing scan/reap entries ───────────────────

mock_crontab_empty="$SANDBOX/mock-crontab-empty"
printf '#!/usr/bin/env bash\necho ""\n' > "$mock_crontab_empty"
chmod +x "$mock_crontab_empty"
export WARDEN_CRONTAB_CMD="$mock_crontab_empty"

output=$("$WARDEN_HOME/bin/doctor.sh" 2>&1)
exit_code=$?

assert_eq "1" "$exit_code" "doctor exits 1 when core loop unwired"
assert_contains "$output" "scan.sh NOT in crontab" "missing scan entry is a FAIL"
assert_contains "$output" "reap-stalls.sh NOT in crontab" "missing reap entry is a FAIL"
assert_contains "$output" "UNHEALTHY" "doctor reports UNHEALTHY"

echo "  doctor: stale heartbeat"

# ─── Heartbeat older than threshold ──────────────────────

export WARDEN_CRONTAB_CMD="$mock_crontab"
touch_relative "10 minutes ago" "$WARDEN_HOME/state/.last-scan-ts"
touch "$WARDEN_HOME/state/.last-reap-ts"

output=$("$WARDEN_HOME/bin/doctor.sh" 2>&1)
exit_code=$?

assert_eq "1" "$exit_code" "doctor exits 1 on stale scan heartbeat"
assert_contains "$output" "scan heartbeat stale" "stale heartbeat is a FAIL"

echo "  doctor: missing heartbeat"

# ─── Heartbeat file absent entirely ──────────────────────

rm -f "$WARDEN_HOME/state/.last-scan-ts"

output=$("$WARDEN_HOME/bin/doctor.sh" 2>&1)
exit_code=$?

assert_eq "1" "$exit_code" "doctor exits 1 on missing heartbeat"
assert_contains "$output" "scan heartbeat missing" "missing heartbeat is a FAIL"

echo "  doctor: alert throttle"

# ─── --alert writes throttle timestamp on failure ────────

rm -f "$WARDEN_HOME/state/.doctor-alert-ts"
"$WARDEN_HOME/bin/doctor.sh" --alert >/dev/null 2>&1

assert_file_exists "$WARDEN_HOME/state/.doctor-alert-ts" "alert timestamp written on unhealthy --alert run"

# Second run within cooldown must not refresh the timestamp
ts_before=$(cat "$WARDEN_HOME/state/.doctor-alert-ts")
sleep 1
"$WARDEN_HOME/bin/doctor.sh" --alert >/dev/null 2>&1
ts_after=$(cat "$WARDEN_HOME/state/.doctor-alert-ts")

assert_eq "$ts_before" "$ts_after" "alert throttled within cooldown window"

# ─── Reset env for subsequent test files ─────────────────
touch "$WARDEN_HOME/state/.last-scan-ts" "$WARDEN_HOME/state/.last-reap-ts"
unset WARDEN_CRONTAB_CMD WARDEN_DOCTOR_SKIP_GATEWAY WARDEN_DOCTOR_CHECK_PATCHES
