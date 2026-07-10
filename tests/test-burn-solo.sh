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

assert_file_not_exists "$ledger" "first encounter stores baseline without ledger append"
assert_file_exists "$state" "solo state created on first encounter"
assert_eq "$baseline_size" "$(jq -r '.["standalone-project/solo-session-1"].off' "$state")" "first encounter stores current offset"

append_solo_line "$solo_file" \
  '{"type":"assistant","message":{"usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":3,"cache_read_input_tokens":4},"content":[{"type":"text","text":"hi"}]}}'
append_solo_line "$solo_file" \
  '{"type":"assistant","message":{"usage":{"input_tokens":5,"output_tokens":7,"cache_creation_input_tokens":1,"cache_read_input_tokens":2},"content":[{"type":"text","text":"done"}]}}'
burn_solo_sample

assert_file_exists "$ledger" "solo ledger created after metered append"
assert_eq "1" "$(wc -l < "$ledger" | tr -d ' ')" "first metered sample appends one cumulative record"
assert_eq "standalone-project:solo-session-1" "$(jq -r '.channel' "$ledger")" "project and sid recorded as channel"
assert_eq "solo-session-1" "$(jq -r '.sid' "$ledger")" "session basename recorded as sid"
assert_eq "42" "$(jq -r '.tokens' "$ledger")" "input + output tokens recorded cumulatively"
assert_eq "2" "$(jq -r '.turns' "$ledger")" "assistant messages counted as turns"
assert_eq "15" "$(jq -r '."in"' "$ledger")" "input token detail recorded"
assert_eq "27" "$(jq -r '.out' "$ledger")" "output token detail recorded"
assert_eq "4" "$(jq -r '.cc' "$ledger")" "cache creation detail recorded"
assert_eq "6" "$(jq -r '.cr' "$ledger")" "cache read detail recorded"

burn_solo_sample
assert_eq "1" "$(wc -l < "$ledger" | tr -d ' ')" "unchanged solo transcript appends nothing"

sleep 1
append_solo_line "$solo_file" \
  '{"type":"assistant","message":{"usage":{"input_tokens":3,"output_tokens":4,"cache_creation_input_tokens":0,"cache_read_input_tokens":1},"content":[{"type":"text","text":"again"}]}}'
burn_solo_sample
assert_eq "2" "$(wc -l < "$ledger" | tr -d ' ')" "new solo lines append one new record"
assert_eq "49" "$(jq -r '.tokens' "$ledger" | tail -1)" "latest solo record has increased cumulative tokens"
assert_eq "3" "$(jq -r '.turns' "$ledger" | tail -1)" "latest solo record has increased cumulative turns"

write_solo_jsonl "-home-user--openclaw-agents-test-agent" "fleet-session" \
  '{"type":"assistant","message":{"usage":{"input_tokens":1000,"output_tokens":1000}}}' >/dev/null
burn_solo_sample
assert_eq "2" "$(wc -l < "$ledger" | tr -d ' ')" "OpenClaw agent project dirs are excluded"
assert_empty "$(jq -r 'select(.channel | contains("openclaw-agents")) | .channel' "$ledger")" "excluded channel never appears in solo ledger"

now=$(date +%s)
report=$(burn_channel_report "$ledger" $(( now - 3600 )))
assert_eq "7" "$(printf '%s\n' "$report" | awk -F'|' '$1 == "standalone-project:solo-session-1" {print $2}')" "burn report consumes solo cumulative delta"
assert_eq "1" "$(printf '%s\n' "$report" | awk -F'|' '$1 == "standalone-project:solo-session-1" {print $3}')" "burn report consumes solo turn delta"

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
assert_eq "14" "$(jq -r '.tokens' "$ledger")" "valid lines around malformed JSON are counted"
assert_eq "2" "$(jq -r '.turns' "$ledger")" "malformed JSON does not affect turn count"

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

assert_eq "4" "$(wc -l < "$ledger" | tr -d ' ')" "two concurrent sessions append independent records"
assert_eq "2" "$(printf '%s\n' "$channels" | wc -l | tr -d ' ')" "one project with two sessions has two channel rows"
assert_contains "$channels" "proj:sidA" "sidA channel includes project and sid"
assert_contains "$channels" "proj:sidB" "sidB channel includes project and sid"
assert_empty "$(jq -r 'select(.channel == "proj") | .channel' "$ledger")" "project-only channel is not used"
assert_eq "5" "$(printf '%s\n' "$report" | awk -F'|' '$1 == "proj:sidA" {print $2}')" "sidA report delta is isolated"
assert_eq "7" "$(printf '%s\n' "$report" | awk -F'|' '$1 == "proj:sidB" {print $2}')" "sidB report delta is isolated"

# --- first encounter fast-path ------------------------------
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

assert_file_not_exists "$ledger" "first encounter of existing transcript appends no ledger record"
assert_eq "$large_size" "$(jq -r '.["large-project/old-session"].off' "$state")" "first encounter stores existing file size as offset"

append_solo_line "$large_file" \
  '{"type":"assistant","message":{"usage":{"input_tokens":4,"output_tokens":6,"cache_creation_input_tokens":2,"cache_read_input_tokens":3}}}'
burn_solo_sample

assert_file_exists "$ledger" "post-baseline append creates solo ledger"
assert_eq "1" "$(wc -l < "$ledger" | tr -d ' ')" "only appended lines are metered after first encounter"
assert_eq "large-project:old-session" "$(jq -r '.channel' "$ledger")" "fast-path channel includes sid"
assert_eq "10" "$(jq -r '.tokens' "$ledger")" "historical tokens are not counted after first encounter"
assert_eq "1" "$(jq -r '.turns' "$ledger")" "only appended assistant message is counted after first encounter"
assert_eq "2" "$(jq -r '.cc' "$ledger")" "appended cache creation detail is recorded"
assert_eq "3" "$(jq -r '.cr' "$ledger")" "appended cache read detail is recorded"

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

assert_eq "150" "$(jq -r '.tokens' "$ledger")" "pre-truncate cumulative tokens recorded"
old_off=$(jq -r '.["truncate-project/solo-session-truncate"].off' "$state")

printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":8,"output_tokens":2}}}' > "$solo_file"
burn_solo_sample

assert_eq "2" "$(wc -l < "$ledger" | tr -d ' ')" "truncated transcript appends a reset snapshot"
assert_eq "10" "$(jq -r '.tokens' "$ledger" | tail -1)" "truncated transcript reprocesses from zero"
assert_eq "1" "$(jq -r '.turns' "$ledger" | tail -1)" "truncated transcript resets turns"
new_off=$(jq -r '.["truncate-project/solo-session-truncate"].off' "$state")
assert_gt "$old_off" "$new_off" "state offset is reset to the smaller rewritten file"

teardown_sandbox
