#!/usr/bin/env bash
# test-burn-solo.sh - tests for standalone Claude Code burn sampling

# shellcheck disable=SC1090,SC2154  # Test harness provides WARDEN_HOME, helpers, and sandbox vars.
source "$WARDEN_HOME/lib/burn-solo.sh"

write_solo_jsonl() {
  local project="$1" sid="$2"
  local dir file
  shift 2

  dir="$WARDEN_CLAUDE_PROJECTS/$project"
  mkdir -p "$dir"
  file="$dir/${sid}.jsonl"
  : > "$file"
  while [ "$#" -gt 0 ]; do
    printf '%s\n' "$1" >> "$file"
    shift
  done
  echo "$file"
}

append_solo_line() {
  local file="$1" line="$2"
  printf '%s\n' "$line" >> "$file"
}

echo "  burn-solo: sampling"

# --- basic sampling + offset dedup + append ----------------
setup_sandbox

solo_file=$(write_solo_jsonl "standalone-project" "solo-session-1" \
  '{"type":"user","message":{"content":[{"type":"text","text":"historical prompt"}]}}')

burn_solo_sample
ledger="$WARDEN_HOME/state/burn/solo.jsonl"
state="$WARDEN_HOME/state/burn/solo-state.json"
baseline_size=$(stat_size "$solo_file")

assert_file_exists "$ledger" "first encounter writes baseline ledger record"
assert_file_exists "$state" "solo state created on first encounter"
assert_eq "1" "$(wc -l < "$ledger" | tr -d ' ')" "first encounter appends exactly one baseline record"
assert_eq "0" "$(jq -r '.tokens' "$ledger")" "first encounter baseline has zero tokens"
assert_eq "0" "$(jq -r '.turns' "$ledger")" "first encounter baseline has zero turns"
assert_eq "$baseline_size" "$(jq -r '.["standalone-project/solo-session-1"].off' "$state")" "first encounter stores current offset"
assert_not_empty "$(jq -r '.["standalone-project/solo-session-1"].ts' "$state")" "state entry records timestamp"

append_solo_line "$solo_file" \
  '{"type":"assistant","message":{"usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":3,"cache_read_input_tokens":4},"content":[{"type":"text","text":"hi"}]}}'
append_solo_line "$solo_file" \
  '{"type":"assistant","message":{"usage":{"input_tokens":5,"output_tokens":7,"cache_creation_input_tokens":1,"cache_read_input_tokens":2},"content":[{"type":"text","text":"done"}]}}'
burn_solo_sample

assert_eq "2" "$(wc -l < "$ledger" | tr -d ' ')" "first metered sample appends one cumulative record after baseline"
assert_eq "standalone-project:solo-session-1" "$(jq -r '.channel' "$ledger" | tail -1)" "project and sid recorded as channel"
assert_eq "solo-session-1" "$(jq -r '.sid' "$ledger" | tail -1)" "session basename recorded as sid"
assert_eq "42" "$(jq -r '.tokens' "$ledger" | tail -1)" "input + output tokens recorded cumulatively"
assert_eq "2" "$(jq -r '.turns' "$ledger" | tail -1)" "assistant messages counted as turns"
assert_eq "15" "$(jq -r '."in"' "$ledger" | tail -1)" "input token detail recorded"
assert_eq "27" "$(jq -r '.out' "$ledger" | tail -1)" "output token detail recorded"
assert_eq "4" "$(jq -r '.cc' "$ledger" | tail -1)" "cache creation detail recorded"
assert_eq "6" "$(jq -r '.cr' "$ledger" | tail -1)" "cache read detail recorded"

burn_solo_sample
assert_eq "2" "$(wc -l < "$ledger" | tr -d ' ')" "unchanged solo transcript appends nothing"

sleep 1
append_solo_line "$solo_file" \
  '{"type":"assistant","message":{"usage":{"input_tokens":3,"output_tokens":4,"cache_creation_input_tokens":0,"cache_read_input_tokens":1},"content":[{"type":"text","text":"again"}]}}'
burn_solo_sample
assert_eq "3" "$(wc -l < "$ledger" | tr -d ' ')" "new solo lines append one new record"
assert_eq "49" "$(jq -r '.tokens' "$ledger" | tail -1)" "latest solo record has increased cumulative tokens"
assert_eq "3" "$(jq -r '.turns' "$ledger" | tail -1)" "latest solo record has increased cumulative turns"

write_solo_jsonl "-home-user--openclaw-agents-test-agent" "fleet-session" \
  '{"type":"assistant","message":{"usage":{"input_tokens":1000,"output_tokens":1000}}}' >/dev/null
write_solo_jsonl "openclaw-agents-fork" "fork-session" \
  '{"type":"assistant","message":{"usage":{"input_tokens":1,"output_tokens":1}}}' >/dev/null
burn_solo_sample
assert_eq "4" "$(wc -l < "$ledger" | tr -d ' ')" "single-dash openclaw-agents project is sampled while real agent dir is excluded"
assert_empty "$(jq -r 'select(.channel | contains("--openclaw-agents")) | .channel' "$ledger")" "real OpenClaw agent project dirs are excluded"
assert_contains "$(jq -r '.channel' "$ledger")" "openclaw-agents-fork:fork-session" "single-dash openclaw-agents fork project is sampled"

now=$(date +%s)
report=$(burn_channel_report "$ledger" $(( now - 3600 )))
assert_eq "49" "$(printf '%s\n' "$report" | awk -F'|' '$1 == "standalone-project:solo-session-1" {print $2}')" "burn report consumes solo cumulative total from baseline"
assert_eq "3" "$(printf '%s\n' "$report" | awk -F'|' '$1 == "standalone-project:solo-session-1" {print $3}')" "burn report consumes solo turn total from baseline"

echo "  burn-solo: report integration"

# --- burn-report includes solo + budget semantics -----------
setup_sandbox

dir="$WARDEN_HOME/state/burn"
mkdir -p "$dir"
now=$(date +%s)
cat > "$dir/test-agent.jsonl" <<LEDGER
{"ts":$(( now - 2000 )),"channel":"agent:test-agent:main","sid":"agent-sid","tokens":100,"turns":1}
{"ts":$(( now - 1000 )),"channel":"agent:test-agent:main","sid":"agent-sid","tokens":250,"turns":3}
LEDGER
cat > "$dir/solo.jsonl" <<LEDGER
{"ts":$(( now - 2000 )),"channel":"solo-project:solo-sid","sid":"solo-sid","tokens":20,"turns":1}
{"ts":$(( now - 1000 )),"channel":"solo-project:solo-sid","sid":"solo-sid","tokens":70,"turns":2}
LEDGER

table=$(bash "$REAL_WARDEN_HOME/bin/burn-report.sh" --window 3600)
assert_contains "$table" "test-agent" "default report includes agent rows"
assert_contains "$table" "solo" "default report includes solo rows"
assert_contains "$table" "solo-project:solo-sid" "default report includes solo channel"
assert_not_contains "$table" "PLAN WINDOW USED" "plan budget 0 shows no plan line"

json_out=$(bash "$REAL_WARDEN_HOME/bin/burn-report.sh" --window 3600 --json)
assert_eq "200" "$(echo "$json_out" | jq -r '.total_consumed')" "default JSON total includes agent and solo consumption"
assert_eq "50" "$(echo "$json_out" | jq -r '.channels[] | select(.agent == "solo") | .consumed')" "default JSON includes solo consumption"
assert_eq "150" "$(echo "$json_out" | jq -r '.channels[] | select(.agent == "test-agent") | .consumed')" "default JSON includes agent consumption"

solo_json=$(bash "$REAL_WARDEN_HOME/bin/burn-report.sh" --window 3600 --solo --json)
assert_eq "50" "$(echo "$solo_json" | jq -r '.total_consumed')" "--solo filters displayed total to solo"
assert_eq "1" "$(echo "$solo_json" | jq -r '.channels | length')" "--solo returns only solo channel rows"
assert_eq "solo" "$(echo "$solo_json" | jq -r '.channels[0].agent')" "--solo rows use agent solo"

budget_table=$(WARDEN_BURN_WINDOW_BUDGET=300 bash "$REAL_WARDEN_HOME/bin/burn-report.sh" --window 3600)
assert_contains "$budget_table" "WINDOW BUDGET USED (300 tokens)" "window budget table line is shown"
assert_contains "$budget_table" "50%" "window budget excludes solo from numerator"

solo_budget_table=$(WARDEN_BURN_WINDOW_BUDGET=300 bash "$REAL_WARDEN_HOME/bin/burn-report.sh" --window 3600 --solo)
assert_contains "$solo_budget_table" "WINDOW BUDGET USED (300 tokens)" "--solo still shows window budget line when configured"
assert_contains "$solo_budget_table" "0%" "--solo window budget numerator excludes solo rows"

budget_json=$(WARDEN_BURN_WINDOW_BUDGET=300 bash "$REAL_WARDEN_HOME/bin/burn-report.sh" --window 3600 --json)
assert_eq "50" "$(echo "$budget_json" | jq -r '.budget_pct')" "JSON window budget percent excludes solo"

solo_budget_json=$(WARDEN_BURN_WINDOW_BUDGET=300 bash "$REAL_WARDEN_HOME/bin/burn-report.sh" --window 3600 --solo --json)
assert_eq "0" "$(echo "$solo_budget_json" | jq -r '.budget_pct')" "--solo JSON budget percent excludes solo"

plan_table=$(WARDEN_BURN_PLAN_BUDGET=400 bash "$REAL_WARDEN_HOME/bin/burn-report.sh" --window 3600)
assert_contains "$plan_table" "PLAN WINDOW USED (400 tokens)" "plan budget table line is shown"
assert_contains "$plan_table" "50%" "plan budget table percentage is computed over all rows"

plan_json=$(WARDEN_BURN_PLAN_BUDGET=400 bash "$REAL_WARDEN_HOME/bin/burn-report.sh" --window 3600 --json)
assert_eq "400" "$(echo "$plan_json" | jq -r '.plan_budget')" "JSON includes plan budget"
assert_eq "50" "$(echo "$plan_json" | jq -r '.plan_pct')" "JSON includes plan percentage"
assert_eq "200" "$(echo "$plan_json" | jq -r '.total_consumed')" "plan JSON total remains mixed agent plus solo"

solo_plan_json=$(WARDEN_BURN_PLAN_BUDGET=400 bash "$REAL_WARDEN_HOME/bin/burn-report.sh" --window 3600 --solo --json)
assert_eq "50" "$(echo "$solo_plan_json" | jq -r '.total_consumed')" "--solo plan JSON displays solo total"
assert_eq "50" "$(echo "$solo_plan_json" | jq -r '.plan_pct')" "--solo plan percent still uses all unfiltered rows"

echo "  burn-solo: alerts"

# --- single post-gap record never spikes -------------------
setup_sandbox

dir="$WARDEN_HOME/state/burn"
mkdir -p "$dir"
now=$(date +%s)
cat > "$dir/solo.jsonl" <<LEDGER
{"ts":$(( now - 400 )),"channel":"post-gap-project:post-gap-sid","sid":"post-gap-sid","tokens":100,"turns":1}
{"ts":$(( now - 100 )),"channel":"post-gap-project:post-gap-sid","sid":"post-gap-sid","tokens":9000,"turns":2}
LEDGER

WARDEN_BURN_SPIKE_TOKENS_5M=5000 burn_solo_check
events="$dir/events.jsonl"
assert_file_not_exists "$events" "single in-window post-gap record never alerts"

# --- two in-window records can spike and are throttled ------
setup_sandbox

dir="$WARDEN_HOME/state/burn"
mkdir -p "$dir"
now=$(date +%s)
cat > "$dir/solo.jsonl" <<LEDGER
{"ts":$(( now - 250 )),"channel":"spike-project:spike-sid","sid":"spike-sid","tokens":100,"turns":1}
{"ts":$(( now - 100 )),"channel":"spike-project:spike-sid","sid":"spike-sid","tokens":9000,"turns":2}
LEDGER

WARDEN_BURN_SPIKE_TOKENS_5M=5000 WARDEN_BURN_DESKTOP_NOTIFY=0 burn_solo_check
events="$dir/events.jsonl"

assert_file_exists "$events" "two-record solo spike writes burn event"
assert_eq "BURN" "$(jq -r '.kind' "$events" | tail -1)" "solo spike event kind is BURN"
assert_eq "solo" "$(jq -r '.agent' "$events" | tail -1)" "solo spike event agent is solo"
assert_eq "spike-project:spike-sid" "$(jq -r '.channel' "$events" | tail -1)" "solo spike event channel is project sid"

count_before=$(jq -r 'select(.kind == "BURN")' "$events" | grep -c kind)
WARDEN_BURN_SPIKE_TOKENS_5M=5000 WARDEN_BURN_DESKTOP_NOTIFY=0 burn_solo_check
count_after=$(jq -r 'select(.kind == "BURN")' "$events" | grep -c kind)
assert_eq "$count_before" "$count_after" "solo spike alert is throttled"

# --- under-threshold solo activity is quiet -----------------
setup_sandbox

dir="$WARDEN_HOME/state/burn"
mkdir -p "$dir"
now=$(date +%s)
cat > "$dir/solo.jsonl" <<LEDGER
{"ts":$(( now - 250 )),"channel":"quiet-project:quiet-sid","sid":"quiet-sid","tokens":100,"turns":1}
{"ts":$(( now - 100 )),"channel":"quiet-project:quiet-sid","sid":"quiet-sid","tokens":200,"turns":2}
LEDGER

WARDEN_BURN_SPIKE_TOKENS_5M=5000 burn_solo_check
events="$dir/events.jsonl"
if [ -f "$events" ]; then
  assert_empty "$(jq -r 'select(.kind == "BURN") | .kind' "$events")" "under-threshold solo activity writes no BURN event"
else
  assert_file_not_exists "$events" "under-threshold solo activity writes no events"
fi

# --- desktop notifier no-ops when osascript is absent -------
setup_sandbox

mock_bin="$SANDBOX/no-osascript-bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/uname" <<'SH'
#!/bin/sh
echo Darwin
SH
chmod +x "$mock_bin/uname"

( PATH="$mock_bin"; notify_desktop "desktop title" "desktop detail" )
rc=$?
assert_exit_code "0" "$rc" "notify_desktop exits 0 without osascript"

# --- desktop notifier is called for solo spikes -------------
setup_sandbox

dir="$WARDEN_HOME/state/burn"
mkdir -p "$dir"
now=$(date +%s)
cat > "$dir/solo.jsonl" <<LEDGER
{"ts":$(( now - 250 )),"channel":"desktop-project:desktop-sid","sid":"desktop-sid","tokens":100,"turns":1}
{"ts":$(( now - 100 )),"channel":"desktop-project:desktop-sid","sid":"desktop-sid","tokens":9000,"turns":2}
LEDGER
mock_bin="$SANDBOX/desktop-bin"
osascript_log="$SANDBOX/osascript.log"
mkdir -p "$mock_bin"
cat > "$mock_bin/uname" <<'SH'
#!/bin/sh
echo Darwin
SH
cat > "$mock_bin/osascript" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$osascript_log"
SH
chmod +x "$mock_bin/uname" "$mock_bin/osascript"

( PATH="$mock_bin:$PATH" WARDEN_BURN_SPIKE_TOKENS_5M=5000 WARDEN_BURN_DESKTOP_NOTIFY=1 burn_solo_check )
assert_file_exists "$osascript_log" "desktop notify calls osascript for solo spike"
assert_contains "$(cat "$osascript_log")" "display notification" "desktop notify sends display notification script"

# --- desktop notifier can be disabled -----------------------
setup_sandbox

dir="$WARDEN_HOME/state/burn"
mkdir -p "$dir"
now=$(date +%s)
cat > "$dir/solo.jsonl" <<LEDGER
{"ts":$(( now - 250 )),"channel":"disabled-desktop-project:disabled-sid","sid":"disabled-sid","tokens":100,"turns":1}
{"ts":$(( now - 100 )),"channel":"disabled-desktop-project:disabled-sid","sid":"disabled-sid","tokens":9000,"turns":2}
LEDGER
mock_bin="$SANDBOX/desktop-disabled-bin"
osascript_log="$SANDBOX/osascript-disabled.log"
mkdir -p "$mock_bin"
cat > "$mock_bin/uname" <<'SH'
#!/bin/sh
echo Darwin
SH
cat > "$mock_bin/osascript" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$osascript_log"
SH
chmod +x "$mock_bin/uname" "$mock_bin/osascript"

( PATH="$mock_bin:$PATH" WARDEN_BURN_SPIKE_TOKENS_5M=5000 WARDEN_BURN_DESKTOP_NOTIFY=0 burn_solo_check )
events="$dir/events.jsonl"
assert_file_exists "$events" "desktop-disabled solo spike still writes burn event"
assert_file_not_exists "$osascript_log" "desktop-disabled solo spike skips osascript"

# --- malformed JSONL lines are tolerated -------------------
setup_sandbox

bad_file=$(write_solo_jsonl "malformed-project" "solo-session-bad-line" \
  '{"type":"user","message":{"content":[{"type":"text","text":"historical"}]}}')
burn_solo_sample
append_solo_line "$bad_file" \
  '{"type":"assistant","message":{"usage":{"input_tokens":2,"output_tokens":3}}}'
append_solo_line "$bad_file" 'not json at all'
append_solo_line "$bad_file" \
  '{"type":"assistant","message":{"usage":{"input_tokens":4,"output_tokens":5}}}'
burn_solo_sample
ledger="$WARDEN_HOME/state/burn/solo.jsonl"

assert_file_exists "$ledger" "solo ledger created despite malformed line"
assert_eq "2" "$(wc -l < "$ledger" | tr -d ' ')" "malformed transcript has baseline plus metered record"
assert_eq "14" "$(jq -r '.tokens' "$ledger" | tail -1)" "valid lines around malformed JSON are counted"
assert_eq "2" "$(jq -r '.turns' "$ledger" | tail -1)" "malformed JSON does not affect turn count"

# --- concurrent sessions in one project are separate rows ---
setup_sandbox

sid_a_file=$(write_solo_jsonl "proj" "sidA" \
  '{"type":"user","message":{"content":[{"type":"text","text":"historical A"}]}}')
sid_b_file=$(write_solo_jsonl "proj" "sidB" \
  '{"type":"user","message":{"content":[{"type":"text","text":"historical B"}]}}')
burn_solo_sample

append_solo_line "$sid_a_file" \
  '{"type":"assistant","message":{"usage":{"input_tokens":6,"output_tokens":4}}}'
append_solo_line "$sid_b_file" \
  '{"type":"assistant","message":{"usage":{"input_tokens":11,"output_tokens":9}}}'
burn_solo_sample

sleep 1
append_solo_line "$sid_a_file" \
  '{"type":"assistant","message":{"usage":{"input_tokens":2,"output_tokens":3}}}'
append_solo_line "$sid_b_file" \
  '{"type":"assistant","message":{"usage":{"input_tokens":4,"output_tokens":3}}}'
burn_solo_sample

ledger="$WARDEN_HOME/state/burn/solo.jsonl"
channels=$(jq -r '.channel' "$ledger" | sort -u)
report=$(burn_channel_report "$ledger" $(( $(date +%s) - 3600 )))

assert_eq "6" "$(wc -l < "$ledger" | tr -d ' ')" "two concurrent sessions append baseline and metered records independently"
assert_eq "2" "$(printf '%s\n' "$channels" | wc -l | tr -d ' ')" "one project with two sessions has two channel rows"
assert_contains "$channels" "proj:sidA" "sidA channel includes project and sid"
assert_contains "$channels" "proj:sidB" "sidB channel includes project and sid"
assert_empty "$(jq -r 'select(.channel == "proj") | .channel' "$ledger")" "project-only channel is not used"
assert_eq "15" "$(printf '%s\n' "$report" | awk -F'|' '$1 == "proj:sidA" {print $2}')" "sidA report total is isolated"
assert_eq "27" "$(printf '%s\n' "$report" | awk -F'|' '$1 == "proj:sidB" {print $2}')" "sidB report total is isolated"

# --- first encounter fast-path with baseline ----------------
setup_sandbox

large_file=$(write_solo_jsonl "large-project" "old-session")
for _ in 1 2 3 4 5 6 7 8 9 10; do
  append_solo_line "$large_file" \
    '{"type":"assistant","message":{"usage":{"input_tokens":1000,"output_tokens":1000}}}'
done
large_size=$(stat_size "$large_file")

burn_solo_sample
ledger="$WARDEN_HOME/state/burn/solo.jsonl"
state="$WARDEN_HOME/state/burn/solo-state.json"

assert_file_exists "$ledger" "first encounter of existing transcript writes baseline ledger"
assert_eq "1" "$(wc -l < "$ledger" | tr -d ' ')" "first encounter writes only baseline"
assert_eq "0" "$(jq -r '.tokens' "$ledger")" "first encounter baseline ignores historical tokens"
assert_eq "$large_size" "$(jq -r '.["large-project/old-session"].off' "$state")" "first encounter stores existing file size as offset"

append_solo_line "$large_file" \
  '{"type":"assistant","message":{"usage":{"input_tokens":4,"output_tokens":6,"cache_creation_input_tokens":2,"cache_read_input_tokens":3}}}'
burn_solo_sample

assert_eq "2" "$(wc -l < "$ledger" | tr -d ' ')" "only appended lines are metered after first encounter"
assert_eq "large-project:old-session" "$(jq -r '.channel' "$ledger" | tail -1)" "fast-path channel includes sid"
assert_eq "10" "$(jq -r '.tokens' "$ledger" | tail -1)" "historical tokens are not counted after first encounter"
assert_eq "1" "$(jq -r '.turns' "$ledger" | tail -1)" "only appended assistant message is counted after first encounter"
assert_eq "2" "$(jq -r '.cc' "$ledger" | tail -1)" "appended cache creation detail is recorded"
assert_eq "3" "$(jq -r '.cr' "$ledger" | tail -1)" "appended cache read detail is recorded"

# --- known size growth overrides mtime cutoff ---------------
setup_sandbox

old_file=$(write_solo_jsonl "quiet-project" "quiet-session" \
  '{"type":"user","message":{"content":[{"type":"text","text":"baseline"}]}}')
burn_solo_sample
append_solo_line "$old_file" \
  '{"type":"assistant","message":{"usage":{"input_tokens":4,"output_tokens":6}}}'
touch -t 202001010000 "$old_file"
WARDEN_SOLO_WINDOW_MINUTES=1 burn_solo_sample
ledger="$WARDEN_HOME/state/burn/solo.jsonl"

assert_eq "2" "$(wc -l < "$ledger" | tr -d ' ')" "known unread bytes are sampled even when mtime is outside the window"
assert_eq "10" "$(jq -r '.tokens' "$ledger" | tail -1)" "mtime cutoff override records appended tokens"

# --- busy lock skips entry script cleanly -------------------
setup_sandbox

write_solo_jsonl "locked-project" "locked-session" \
  '{"type":"user","message":{"content":[{"type":"text","text":"baseline"}]}}' >/dev/null
mkdir -p "$WARDEN_HOME/state/burn/solo.lock.d"
WARDEN_HOME="$WARDEN_HOME" WARDEN_CLAUDE_PROJECTS="$WARDEN_CLAUDE_PROJECTS" \
  bash "$REAL_WARDEN_HOME/bin/burn-solo-sample.sh"
rc=$?
assert_exit_code "0" "$rc" "busy solo lock exits 0"
assert_file_not_exists "$WARDEN_HOME/state/burn/solo.jsonl" "busy solo lock skips ledger writes"
assert_file_not_exists "$WARDEN_HOME/state/burn/solo-state.json" "busy solo lock skips state writes"

# --- stale state pruning ------------------------------------
setup_sandbox

state_dir="$WARDEN_HOME/state/burn"
mkdir -p "$state_dir"
live_file=$(write_solo_jsonl "prune-live" "live" \
  '{"type":"user","message":{"content":[{"type":"text","text":"still here"}]}}')
small_file=$(write_solo_jsonl "prune-small" "small" \
  '{"type":"user","message":{"content":[{"type":"text","text":"short"}]}}')
live_size=$(stat_size "$live_file")
old_ts=$(( $(date +%s) - 3 * 86400 ))
new_ts=$(date +%s)
cat > "$state_dir/solo-state.json" <<STATE
{
  "prune-live/live": {"off": $live_size, "in": 0, "out": 0, "cc": 0, "cr": 0, "turns": 0, "ts": $old_ts},
  "prune-missing/missing": {"off": 10, "in": 0, "out": 0, "cc": 0, "cr": 0, "turns": 0, "ts": $old_ts},
  "prune-small/small": {"off": 999, "in": 0, "out": 0, "cc": 0, "cr": 0, "turns": 0, "ts": $old_ts},
  "prune-new/missing": {"off": 10, "in": 0, "out": 0, "cc": 0, "cr": 0, "turns": 0, "ts": $new_ts}
}
STATE

burn_solo_prune_state 1
state="$state_dir/solo-state.json"
assert_eq "true" "$(jq -r 'has("prune-live/live")' "$state")" "state prune keeps old live entry"
assert_eq "false" "$(jq -r 'has("prune-missing/missing")' "$state")" "state prune drops old missing entry"
assert_eq "false" "$(jq -r 'has("prune-small/small")' "$state")" "state prune drops old smaller rewritten entry"
assert_eq "true" "$(jq -r 'has("prune-new/missing")' "$state")" "state prune keeps recent missing entry"
assert_not_empty "$(stat_size "$small_file")" "small prune fixture exists"

# --- disabled flag is a clean no-op -------------------------
setup_sandbox

write_solo_jsonl "disabled-project" "solo-session-disabled" \
  '{"type":"assistant","message":{"usage":{"input_tokens":10,"output_tokens":20}}}' >/dev/null
WARDEN_BURN_ENABLED=0 burn_solo_sample
rc=$?

assert_exit_code "0" "$rc" "disabled solo sampling exits 0"
assert_file_not_exists "$WARDEN_HOME/state/burn/solo.jsonl" "disabled solo sampling writes no ledger"
assert_file_not_exists "$WARDEN_HOME/state/burn/solo-state.json" "disabled solo sampling writes no state"

# --- truncated session resets stored offset -----------------
setup_sandbox

solo_file=$(write_solo_jsonl "truncate-project" "solo-session-truncate" \
  '{"type":"user","message":{"content":[{"type":"text","text":"historical"}]}}')
burn_solo_sample
append_solo_line "$solo_file" \
  '{"type":"assistant","message":{"usage":{"input_tokens":50,"output_tokens":60}}}'
append_solo_line "$solo_file" \
  '{"type":"assistant","message":{"usage":{"input_tokens":10,"output_tokens":30}}}'
burn_solo_sample
ledger="$WARDEN_HOME/state/burn/solo.jsonl"
state="$WARDEN_HOME/state/burn/solo-state.json"

assert_eq "150" "$(jq -r '.tokens' "$ledger" | tail -1)" "pre-truncate cumulative tokens recorded"
old_off=$(jq -r '.["truncate-project/solo-session-truncate"].off' "$state")

printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":8,"output_tokens":2}}}' > "$solo_file"
burn_solo_sample

assert_eq "3" "$(wc -l < "$ledger" | tr -d ' ')" "truncated transcript appends a reset snapshot after baseline"
assert_eq "10" "$(jq -r '.tokens' "$ledger" | tail -1)" "truncated transcript reprocesses from zero"
assert_eq "1" "$(jq -r '.turns' "$ledger" | tail -1)" "truncated transcript resets turns"
new_off=$(jq -r '.["truncate-project/solo-session-truncate"].off' "$state")
assert_gt "$old_off" "$new_off" "state offset is reset to the smaller rewritten file"

teardown_sandbox
