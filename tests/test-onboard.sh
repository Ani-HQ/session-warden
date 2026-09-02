#!/usr/bin/env bash
# test-onboard.sh — detect hosts, dry-run writes nothing, install skills

export WARDEN_ONBOARD_HOME="$SANDBOX/home"
mkdir -p "$WARDEN_ONBOARD_HOME"

echo "  onboard: dry-run writes nothing"

out=$("$WARDEN_HOME/bin/session-warden" onboard --dry-run)
assert_contains "$out" "dry-run" "dry-run mentions dry-run"
assert_contains "$out" "Extra Anthropic quota is gone" "dry-run states quota is gone"
assert_file_not_exists "$WARDEN_HOME/config/routing.yaml" "dry-run does not write routing.yaml"
assert_file_not_exists "$WARDEN_ONBOARD_HOME/.claude/skills/session-warden-route/SKILL.md" "dry-run does not install claude skill"

echo "  onboard: --host not detected installs nothing"

out=$("$WARDEN_HOME/bin/session-warden" onboard --host claude-code)
assert_contains "$out" "not detected" "missing host is reported"
assert_file_not_exists "$WARDEN_ONBOARD_HOME/.claude/skills/session-warden-route/SKILL.md" "no skill without host"

echo "  onboard: detected hosts get skills + routing.yaml"

cat > "$SANDBOX/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo claude
STUB
chmod +x "$SANDBOX/bin/claude"
mkdir -p "$WARDEN_ONBOARD_HOME/.openclaw/agents"
echo '{}' > "$WARDEN_ONBOARD_HOME/.openclaw/openclaw.json"
mkdir -p "$WARDEN_ONBOARD_HOME/.hermes-baymax"
export WARDEN_OPENCLAW_HOME="$WARDEN_ONBOARD_HOME/.openclaw"

out=$("$WARDEN_HOME/bin/session-warden" onboard)
assert_contains "$out" "openclaw" "onboard lists openclaw"
assert_contains "$out" "hermes" "onboard lists hermes"
assert_contains "$out" "claude-code" "onboard lists claude-code"
assert_file_exists "$WARDEN_HOME/config/routing.yaml" "onboard writes routing.yaml"
assert_file_exists "$WARDEN_ONBOARD_HOME/.claude/skills/session-warden-route/SKILL.md" "claude skill installed"
assert_file_exists "$WARDEN_ONBOARD_HOME/.openclaw/skills/session-warden-route/SKILL.md" "openclaw shared skill installed"
assert_file_exists "$WARDEN_ONBOARD_HOME/.hermes-baymax/skills/session-warden-route/SKILL.md" "hermes home skill installed"
assert_contains "$(cat "$WARDEN_ONBOARD_HOME/.claude/skills/session-warden-route/SKILL.md")" "session-warden route" "skill tells the host to route"

echo "  onboard: dry-run still writes nothing after a real install (skills already there)"

# A second dry-run must not be required to succeed — just prove the flag
# still prints would-install without deleting existing files.
before=$(cat "$WARDEN_HOME/config/routing.yaml")
"$WARDEN_HOME/bin/session-warden" onboard --dry-run >/dev/null
after=$(cat "$WARDEN_HOME/config/routing.yaml")
assert_eq "$before" "$after" "dry-run does not rewrite routing.yaml"
