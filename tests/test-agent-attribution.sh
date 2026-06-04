#!/usr/bin/env bash
# test-agent-attribution.sh — tests for lib/agent-attribution.sh

source "$WARDEN_HOME/lib/agent-attribution.sh"

echo "  agent-attribution: agent_from_cwd"

# ─── OpenClaw agent dirs ──────────────────────────────────
assert_eq "kai"  "$(agent_from_cwd "$HOME/.openclaw/agents/kai")"          "openclaw agent (bare)"
assert_eq "zara" "$(agent_from_cwd "$HOME/.openclaw/agents/zara/work/x")"  "openclaw agent (nested)"
assert_eq "nova" "$(agent_from_cwd "/home/someone/.openclaw/agents/nova")" "openclaw agent (other home)"

# ─── ai-holdingco projects ────────────────────────────────
assert_eq "kai-adventuresof" "$(agent_from_cwd "/x/ai-holdingco/apps/storybook")" "ai-holdingco storybook"
assert_eq "kai-yeet"         "$(agent_from_cwd "/x/ai-holdingco/yeet")"            "ai-holdingco yeet"
assert_eq "kai"              "$(agent_from_cwd "/x/ai-holdingco/hood/other")"      "ai-holdingco generic"

# ─── crossval ─────────────────────────────────────────────
assert_eq "cv-special-ops" "$(agent_from_cwd "/x/crossval/api")"   "crossval path"
assert_eq "cv-special-ops" "$(agent_from_cwd "/x/cv-backend")"     "cv-backend path"
assert_eq "cv-special-ops" "$(agent_from_cwd "/x/cv-website")"     "cv-website path"

# ─── home and fallback ────────────────────────────────────
assert_eq "home"    "$(agent_from_cwd "$HOME")"        "bare home dir -> home"
assert_eq "home"    "$(agent_from_cwd "$HOME/")"       "home dir trailing slash -> home"
assert_eq "unknown" "$(agent_from_cwd "/tmp/random")"  "unrecognized path -> unknown"
assert_eq "unknown" "$(agent_from_cwd "")"             "empty cwd -> unknown"

echo "  agent-attribution: agent_from_sessions_path"

# ─── OpenClaw sessions.json path ──────────────────────────
assert_eq "kai"  "$(agent_from_sessions_path "/home/u/.openclaw/agents/kai/sessions/sessions.json")"  "sessions path -> kai"
assert_eq "zara" "$(agent_from_sessions_path "/x/agents/zara/sessions/sessions.json")"                "sessions path -> zara"

echo "  agent-attribution: functions exported"

# ─── Exported to subshells ────────────────────────────────
sub_result=$(bash -c 'agent_from_cwd "$HOME/.openclaw/agents/remy"' 2>/dev/null)
assert_eq "remy" "$sub_result" "agent_from_cwd available in subshell (exported)"
