#!/usr/bin/env bash
# test-cache-report.sh — tests for lib/cache-report.py + bin/cache-report.sh

echo "  cache: prompt-cache hit rate"

setup_sandbox

iso_now=$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"))')
iso_old=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=10)).strftime("%Y-%m-%dT%H:%M:%S.000Z"))')

sessions="$SANDBOX/openclaw/agents/test-agent/sessions"

# Two in-window assistant rows (input 100, cacheRead 1300, cacheWrite 100 →
# hit 1300/1500 = 86.7%), one out-of-window row that must be excluded, one
# all-zero delivery-mirror row, a user row, and a torn line.
cat > "$sessions/cache-a.jsonl" <<EOF
{"type":"session","version":3,"id":"cache-a","timestamp":"$iso_now"}
{"type":"message","timestamp":"$iso_now","message":{"role":"assistant","usage":{"input":100,"output":50,"cacheRead":900,"cacheWrite":0,"totalTokens":1050}}}
{"type":"message","timestamp":"$iso_now","message":{"role":"assistant","usage":{"input":0,"output":10,"cacheRead":400,"cacheWrite":100,"totalTokens":510}}}
{"type":"message","timestamp":"$iso_old","message":{"role":"assistant","usage":{"input":99999,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":100000}}}
{"type":"message","timestamp":"$iso_now","message":{"role":"assistant","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0}}}
{"type":"message","timestamp":"$iso_now","message":{"role":"user","content":"hi"}}
this line is not json
EOF

# Trajectory sibling must be ignored entirely.
cat > "$sessions/cache-a.trajectory.jsonl" <<EOF
{"type":"message","timestamp":"$iso_now","message":{"role":"assistant","usage":{"input":555555,"output":1,"cacheRead":0,"cacheWrite":0}}}
EOF

# ─── python reporter ──────────────────────────────────────
out=$(python3 "$REAL_WARDEN_HOME/lib/cache-report.py" "$SANDBOX/openclaw/agents" \
  --days 7 --agents test-agent,second-agent)
row=$(printf '%s\n' "$out" | grep '^test-agent')
assert_contains "$row" "86.7" "hit rate is cacheRead over all prompt tokens"
assert_contains "$row" "1300" "cacheRead summed across in-window rows"
assert_not_contains "$row" "99999" "out-of-window rows excluded"
assert_not_contains "$row" "555555" "trajectory files excluded"
IFS=$'\t' read -r _ _ _ _ _ _ calls _ <<< "$row"
assert_eq "2" "$calls" "all-zero and user rows do not count as calls"
row2=$(printf '%s\n' "$out" | grep '^second-agent')
assert_contains "$row2" "-" "idle agent reports '-' not a number"

json=$(python3 "$REAL_WARDEN_HOME/lib/cache-report.py" "$SANDBOX/openclaw/agents" \
  --days 7 --agents test-agent,second-agent --json)
assert_eq "86.7" "$(printf '%s' "$json" | jq -r '.fleet.hit_pct')" "fleet rollup matches"
assert_eq "null" "$(printf '%s' "$json" | jq -r '.agents[] | select(.agent=="second-agent") | .hit_pct')" \
  "idle agent hit_pct is null in json"

# ─── shell wrapper: table + roster ────────────────────────
roster="$SANDBOX/cache-roster.tsv"
printf '# comment\ntest-agent\tteam\tchan\trole\nsecond-agent\tteam\tchan\trole\n' > "$roster"
export WARDEN_FLEET_ROSTER="$roster"

out=$("$WARDEN_HOME/bin/cache-report.sh")
assert_contains "$out" "test-agent" "table lists roster agents"
assert_contains "$out" "86.7" "table shows hit rate"
assert_contains "$out" "fleet hit rate" "table ends with fleet summary"

out=$("$WARDEN_HOME/bin/cache-report.sh" --json)
assert_eq "86.7" "$(printf '%s' "$out" | jq -r '.fleet.hit_pct')" "--json passes reporter output through"

# ─── check mode: floor alert + throttle ───────────────────
export WARDEN_CACHE_MIN_TOKENS=100
export WARDEN_CACHE_WARN_PCT=90
export WARDEN_CACHE_DROP_PCT=20

out=$("$WARDEN_HOME/bin/cache-report.sh" --check)
assert_contains "$out" "ALERT" "hit rate below floor triggers alert"
assert_contains "$out" "below the 90% floor" "alert names the floor"
assert_file_exists "$WARDEN_HOME/state/cache/alert-test-agent.stamp" "alert stamp written"
assert_file_exists "$WARDEN_HOME/state/cache/last-check.json" "snapshot written for drop detection"

out=$("$WARDEN_HOME/bin/cache-report.sh" --check)
assert_eq "OK" "$out" "second check inside cooldown is throttled"

# ─── check mode: drop detection ───────────────────────────
rm -f "$WARDEN_HOME/state/cache/alert-"*.stamp
printf '{"agents":[{"agent":"test-agent","hit_pct":95}]}\n' > "$WARDEN_HOME/state/cache/last-check.json"
export WARDEN_CACHE_WARN_PCT=10
export WARDEN_CACHE_DROP_PCT=5

out=$("$WARDEN_HOME/bin/cache-report.sh" --check)
assert_contains "$out" "dropped" "drop vs previous snapshot triggers alert"

# ─── check mode: min-tokens gate + kill switch ────────────
rm -f "$WARDEN_HOME/state/cache/alert-"*.stamp
export WARDEN_CACHE_WARN_PCT=99
export WARDEN_CACHE_MIN_TOKENS=99999999

out=$("$WARDEN_HOME/bin/cache-report.sh" --check)
assert_eq "OK" "$out" "agents under the min-token floor never alert"

export WARDEN_CACHE_ENABLED=0
out=$("$WARDEN_HOME/bin/cache-report.sh")
assert_contains "$out" "disabled" "WARDEN_CACHE_ENABLED=0 disables the report"

unset WARDEN_CACHE_ENABLED WARDEN_CACHE_MIN_TOKENS WARDEN_CACHE_WARN_PCT \
      WARDEN_CACHE_DROP_PCT WARDEN_FLEET_ROSTER

teardown_sandbox
