#!/usr/bin/env bash
# test-notify.sh — tests for lib/notify.sh

source "$WARDEN_HOME/lib/notify.sh"

echo "  notify: skip when no token"

# ─── Notification skipped when no credentials ─────────────

export WARDEN_TELEGRAM_BOT_TOKEN=""
export WARDEN_TELEGRAM_CHAT_ID=""

output=$(notify_rotation "test-agent" "discord-general" "TOKENS" "tokens=3000000" 2>&1)
assert_empty "$output" "no output when telegram credentials missing"

echo "  notify: skip when no chat ID"

# ─── Token set but no chat ID ────────────────────────────

export WARDEN_TELEGRAM_BOT_TOKEN="fake-token"
export WARDEN_TELEGRAM_CHAT_ID=""

output=$(notify_rotation "test-agent" "discord-general" "TOKENS" "tokens=3000000" 2>&1)
assert_empty "$output" "no output when chat ID missing"

echo "  notify: notify_test function exists"

# ─── notify_test is callable ─────────────────────────────

type notify_test &>/dev/null
exit_code=$?
assert_eq "0" "$exit_code" "notify_test function is defined"

# Reset
export WARDEN_TELEGRAM_BOT_TOKEN=""
export WARDEN_TELEGRAM_CHAT_ID=""
