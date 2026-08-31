#!/usr/bin/env bash
# test-recovery.sh — explicit-failure labels on wake prompts

source "$WARDEN_HOME/lib/recovery.sh"

echo "  recovery: incomplete reasons"

rc=0; recovery_is_incomplete ZOMBIE || rc=$?
assert_eq "0" "$rc" "ZOMBIE is incomplete"
rc=0; recovery_is_incomplete FAILED || rc=$?
assert_eq "0" "$rc" "FAILED is incomplete"
rc=0; recovery_is_incomplete STALL || rc=$?
assert_eq "0" "$rc" "STALL is incomplete"
rc=0; recovery_is_incomplete TIMEOUT || rc=$?
assert_eq "0" "$rc" "TIMEOUT is incomplete"
rc=0; recovery_is_incomplete CRASH || rc=$?
assert_eq "0" "$rc" "CRASH is incomplete"

rc=0; recovery_is_incomplete TOKENS || rc=$?
assert_eq "1" "$rc" "TOKENS is a planned rotation, not incomplete"
rc=0; recovery_is_incomplete TURNS || rc=$?
assert_eq "1" "$rc" "TURNS is a planned rotation, not incomplete"
rc=0; recovery_is_incomplete COMPACTIONS || rc=$?
assert_eq "1" "$rc" "COMPACTIONS is a planned rotation, not incomplete"
rc=0; recovery_is_incomplete SIZE || rc=$?
assert_eq "1" "$rc" "SIZE is a planned rotation, not incomplete"
rc=0; recovery_is_incomplete model-switch || rc=$?
assert_eq "1" "$rc" "model-switch is a planned handoff, not incomplete"

echo "  recovery: banner"

banner=$(recovery_incomplete_banner ZOMBIE)
assert_contains "$banner" "INCOMPLETE:" "banner names the incomplete state"
assert_contains "$banner" "ZOMBIE" "banner includes the reason"
assert_contains "$banner" "Do not report this work as done" "banner forbids claiming done"

echo "  recovery: planned rotation has no banner"

planned=$(build_recovery_message TOKENS "last task was a deploy" "")
assert_not_contains "$planned" "INCOMPLETE:" "token rotation is not labeled incomplete"
assert_contains "$planned" "You just came back from a session restart" "planned wake keeps the existing prose"
assert_contains "$planned" "last task was a deploy" "planned wake inlines CONTEXT.md"

echo "  recovery: zombie / failed labeled incomplete"

zombie=$(build_recovery_message ZOMBIE "stale context" "")
assert_contains "$zombie" "INCOMPLETE:" "zombie wake is labeled incomplete"
assert_contains "$zombie" "ZOMBIE" "zombie wake names the reason"
assert_contains "$zombie" "Do not report this work as done" "zombie wake forbids claiming done"
assert_contains "$zombie" "stale context" "zombie wake still inlines context"
# Banner must be first so the model reads the status, not the transcript tail.
assert_eq "INCOMPLETE:" "$(printf '%s\n' "$zombie" | head -1 | awk '{print $1}')" \
  "INCOMPLETE is the first token the next agent sees"

failed=$(build_recovery_message FAILED "" "")
assert_contains "$failed" "INCOMPLETE:" "failed wake is labeled incomplete"
assert_contains "$failed" "FAILED" "failed wake names the reason"

echo "  recovery: crash buffer still prioritized"

crash=$(build_recovery_message ZOMBIE "ctx body" "please ship the fix")
assert_contains "$crash" "INCOMPLETE:" "crash+zombie is still incomplete"
assert_contains "$crash" "ctx body" "context is inlined when both context and crash buffer exist"
assert_contains "$crash" "Unprocessed Messages" "crash path uses the unprocessed-messages wording"

crash_only=$(build_recovery_message FAILED "" "reply to jane")
assert_contains "$crash_only" "INCOMPLETE:" "crash-only failed wake is incomplete"
assert_contains "$crash_only" "reply to jane" "crash-only path inlines the buffer"

echo "  recovery: stall reaper"

stall=$(build_stall_recovery_message)
assert_contains "$stall" "INCOMPLETE:" "stall wake is labeled incomplete"
assert_contains "$stall" "STALL" "stall wake names the reason"
assert_contains "$stall" "Do not report this work as done" "stall wake forbids claiming done"
assert_contains "$stall" "watchdog" "stall wake keeps the watchdog wording"
assert_eq "INCOMPLETE:" "$(printf '%s\n' "$stall" | head -1 | awk '{print $1}')" \
  "stall banner is first"
