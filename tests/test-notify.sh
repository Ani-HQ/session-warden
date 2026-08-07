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

echo "  notify: harvest discord card skips when unconfigured"

# ─── Discord harvest card: silent no-op without credentials ───

export WARDEN_DISCORD_BOT_TOKEN=""
export WARDEN_HARVEST_DISCORD_CHANNEL_ID=""

output=$(notify_harvest_skill_discord "test-agent" "test-skill" "A test skill." 2>&1)
exit_code=$?
assert_empty "$output" "no output when discord credentials missing"
assert_eq "0" "$exit_code" "skip (not failure) when discord credentials missing"

export WARDEN_DISCORD_BOT_TOKEN="fake-token"
export WARDEN_HARVEST_DISCORD_CHANNEL_ID=""

output=$(notify_harvest_skill_discord "test-agent" "test-skill" "A test skill." 2>&1)
exit_code=$?
assert_empty "$output" "no output when discord channel missing"
assert_eq "0" "$exit_code" "skip (not failure) when discord channel missing"

echo "  notify: harvest discord card respects opt-out"

# ─── WARDEN_HARVEST_NOTIFY_DISCORD=0 short-circuits before any send ───

export WARDEN_DISCORD_BOT_TOKEN="fake-token"
export WARDEN_HARVEST_DISCORD_CHANNEL_ID="123456789"
export WARDEN_HARVEST_NOTIFY_DISCORD=0

output=$(notify_harvest_skill_discord "test-agent" "test-skill" "A test skill." 2>&1)
exit_code=$?
assert_empty "$output" "no output when discord cards disabled"
assert_eq "0" "$exit_code" "skip (not failure) when discord cards disabled"

echo "  notify: harvest discord openclaw path needs channel"

# ─── OpenClaw path: account set but no channel → skip ───

unset WARDEN_HARVEST_NOTIFY_DISCORD
export WARDEN_HARVEST_DISCORD_ACCOUNT="isaac"
export WARDEN_HARVEST_DISCORD_CHANNEL_ID=""
export WARDEN_DISCORD_BOT_TOKEN=""

output=$(notify_harvest_skill_discord "test-agent" "test-skill" "A test skill." 2>&1)
exit_code=$?
assert_empty "$output" "no output when openclaw channel missing"
assert_eq "0" "$exit_code" "skip (not failure) when openclaw channel missing"

# Reset
export WARDEN_TELEGRAM_BOT_TOKEN=""
export WARDEN_TELEGRAM_CHAT_ID=""
export WARDEN_DISCORD_BOT_TOKEN=""
export WARDEN_HARVEST_DISCORD_CHANNEL_ID=""
unset WARDEN_HARVEST_NOTIFY_DISCORD
unset WARDEN_HARVEST_DISCORD_ACCOUNT
