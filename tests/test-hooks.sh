#!/usr/bin/env bash
# test-hooks.sh — tests for hooks system

echo "  hooks: directory exists"

# ─── Hook directory exists ────────────────────────────────

assert_dir_exists "$WARDEN_HOME/hooks/post-summary" "post-summary hook directory exists"

echo "  hooks: gbrain hook exists and is executable"

# ─── GBrain hook ──────────────────────────────────────────

gbrain_hook="$WARDEN_HOME/hooks/post-summary/01-gbrain.sh"
assert_file_exists "$gbrain_hook" "gbrain hook exists"

echo "  hooks: gbrain hook has no hardcoded secrets"

# ─── No secrets in gbrain hook ────────────────────────────

hook_content=$(cat "$gbrain_hook")
assert_not_contains "$hook_content" "ntn_" "gbrain hook has no Notion tokens"
assert_not_contains "$hook_content" "sk-" "gbrain hook has no API keys"
assert_not_contains "$hook_content" "xoxb-" "gbrain hook has no Slack tokens"
assert_not_contains "$hook_content" "/home/" "gbrain hook has no hardcoded home paths"

echo "  hooks: gbrain hook documents env vars"

# ─── Hook documentation ──────────────────────────────────

assert_contains "$hook_content" "WARDEN_AGENT" "hook documents WARDEN_AGENT"
assert_contains "$hook_content" "WARDEN_CHANNEL_KEY" "hook documents WARDEN_CHANNEL_KEY"
assert_contains "$hook_content" "WARDEN_SESSION_ID" "hook documents WARDEN_SESSION_ID"
assert_contains "$hook_content" "WARDEN_MEMORY_FILE" "hook documents WARDEN_MEMORY_FILE"
assert_contains "$hook_content" "WARDEN_TRANSCRIPT_FILE" "hook documents WARDEN_TRANSCRIPT_FILE"
assert_contains "$hook_content" "WARDEN_ARCHIVED_JSONL" "hook documents WARDEN_ARCHIVED_JSONL"

echo "  hooks: gbrain hook exits gracefully without gbrain"

# ─── Graceful exit when gbrain not installed ──────────────

# Ensure gbrain is NOT in PATH
ORIG_PATH="$PATH"
export PATH="/usr/bin:/bin"

output=$(bash "$gbrain_hook" 2>&1)
exit_code=$?
assert_eq "0" "$exit_code" "gbrain hook exits 0 when gbrain missing"

export PATH="$ORIG_PATH"

echo "  hooks: custom hook execution"

# ─── Custom hooks are picked up ──────────────────────────

custom_hook="$WARDEN_HOME/hooks/post-summary/99-test-hook.sh"
cat > "$custom_hook" <<'HOOK'
#!/usr/bin/env bash
echo "CUSTOM_HOOK_RAN: $WARDEN_AGENT"
HOOK
chmod +x "$custom_hook"

output=$(WARDEN_AGENT="test-agent" bash "$custom_hook" 2>&1)
assert_contains "$output" "CUSTOM_HOOK_RAN: test-agent" "custom hook runs with env vars"

# Cleanup
rm -f "$custom_hook"
