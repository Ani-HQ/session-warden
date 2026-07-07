#!/usr/bin/env bash
# test-install.sh — tests for install.sh

echo "  install: script exists and is executable"

# ─── Install script exists ───────────────────────────────

assert_file_exists "$REAL_WARDEN_HOME/install.sh" "install.sh exists"

echo "  install: config example exists"

# ─── Config example exists ───────────────────────────────

assert_file_exists "$WARDEN_HOME/config/thresholds.env.example" "thresholds.env.example exists"

echo "  install: config example has all required vars"

# ─── Config example completeness ─────────────────────────

example=$(cat "$WARDEN_HOME/config/thresholds.env.example")
assert_contains "$example" "WARDEN_MAX_TOKENS" "example has WARDEN_MAX_TOKENS"
assert_contains "$example" "WARDEN_MAX_TURNS" "example has WARDEN_MAX_TURNS"
assert_contains "$example" "WARDEN_MAX_COMPACTIONS" "example has WARDEN_MAX_COMPACTIONS"
assert_contains "$example" "WARDEN_COOLDOWN_SECONDS" "example has WARDEN_COOLDOWN_SECONDS"
assert_contains "$example" "WARDEN_GATEWAY_RESTART_COOLDOWN_SECONDS" "example has gateway cooldown"
assert_contains "$example" "WARDEN_SUMMARY_MODEL" "example has WARDEN_SUMMARY_MODEL"
assert_contains "$example" "WARDEN_SCAN_AGENTS" "example has WARDEN_SCAN_AGENTS"
assert_contains "$example" "WARDEN_OPENCLAW_HOME" "example has WARDEN_OPENCLAW_HOME"
assert_contains "$example" "WARDEN_CLAUDE_PROJECTS" "example has WARDEN_CLAUDE_PROJECTS"
assert_contains "$example" "WARDEN_TELEGRAM_BOT_TOKEN" "example has WARDEN_TELEGRAM_BOT_TOKEN"
assert_contains "$example" "WARDEN_TELEGRAM_CHAT_ID" "example has WARDEN_TELEGRAM_CHAT_ID"
assert_contains "$example" "WARDEN_LOG_FILE" "example has WARDEN_LOG_FILE"
assert_contains "$example" "WARDEN_DRY_RUN" "example has WARDEN_DRY_RUN"
assert_contains "$example" "WARDEN_ARCHIVE_RETENTION_DAYS" "example has retention days"
assert_contains "$example" "WARDEN_ACTIVE_THRESHOLD_SECS" "example has active threshold"
assert_contains "$example" "WARDEN_MEMORY_MAX_BYTES" "example has memory max bytes"
assert_contains "$example" "WARDEN_MAX_CONSECUTIVE_FAILURES" "example has max consecutive failures"

echo "  install: no sensitive data in example"

# ─── No secrets in example config ─────────────────────────

assert_not_contains "$example" "ntn_" "no Notion tokens in example"
assert_not_contains "$example" "xoxb-" "no Slack tokens in example"
assert_not_contains "$example" "sk-" "no API keys in example"
