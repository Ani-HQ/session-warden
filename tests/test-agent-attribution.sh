#!/usr/bin/env bash
# test-agent-attribution.sh — tests for lib/agent-attribution.sh

source "$WARDEN_HOME/lib/agent-attribution.sh"

echo "  agent-attribution: agent_from_cwd (built-in resolution)"

# Ensure no user map file interferes with the built-in resolution tests.
export WARDEN_AGENT_PATH_MAP="/nonexistent/agent-paths.env"

# ─── OpenClaw agent dirs — name taken verbatim from the path ──
assert_eq "scout"  "$(agent_from_cwd "$HOME/.openclaw/agents/scout")"          "openclaw agent (bare)"
assert_eq "scribe" "$(agent_from_cwd "$HOME/.openclaw/agents/scribe/work/x")"  "openclaw agent (nested)"
assert_eq "relay"  "$(agent_from_cwd "/home/someone/.openclaw/agents/relay")"  "openclaw agent (other home)"

# ─── home and fallback ────────────────────────────────────
assert_eq "home"    "$(agent_from_cwd "$HOME")"        "bare home dir -> home"
assert_eq "home"    "$(agent_from_cwd "$HOME/")"       "home dir trailing slash -> home"
assert_eq "unknown" "$(agent_from_cwd "/tmp/random")"  "unrecognized path -> unknown"
assert_eq "unknown" "$(agent_from_cwd "")"             "empty cwd -> unknown"

echo "  agent-attribution: agent_from_cwd (custom path map)"

# ─── User-supplied glob rules, first match wins ───────────
map="$(mktemp)"
cat > "$map" <<'EOF'
# comment line, ignored

*acme*frontend*  = web
*acme*           = core
*/work/scraper*  = scraper-bot
EOF
export WARDEN_AGENT_PATH_MAP="$map"

assert_eq "web"         "$(agent_from_cwd "/srv/acme/frontend/app")"  "custom map: specific pattern first"
assert_eq "core"        "$(agent_from_cwd "/srv/acme/api")"           "custom map: general fallback"
assert_eq "scraper-bot" "$(agent_from_cwd "/home/x/work/scraper")"    "custom map: later rule"
assert_eq "unknown"     "$(agent_from_cwd "/srv/other")"              "custom map: no rule -> unknown"
assert_eq "relay"       "$(agent_from_cwd "$HOME/.openclaw/agents/relay")" "openclaw dir wins over custom map"

rm -f "$map"
export WARDEN_AGENT_PATH_MAP="/nonexistent/agent-paths.env"

echo "  agent-attribution: agent_from_sessions_path"

# ─── OpenClaw sessions.json path ──────────────────────────
assert_eq "scout" "$(agent_from_sessions_path "/home/u/.openclaw/agents/scout/sessions/sessions.json")"  "sessions path -> scout"
assert_eq "relay" "$(agent_from_sessions_path "/x/agents/relay/sessions/sessions.json")"                 "sessions path -> relay"

echo "  agent-attribution: functions exported"

# ─── Exported to subshells ────────────────────────────────
sub_result=$(bash -c 'agent_from_cwd "$HOME/.openclaw/agents/probe"' 2>/dev/null)
assert_eq "probe" "$sub_result" "agent_from_cwd available in subshell (exported)"
