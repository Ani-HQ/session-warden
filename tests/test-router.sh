#!/usr/bin/env bash
# test-router.sh — credits-first heuristic, user rules, rate-guard skip

# shellcheck source=../lib/router.sh
source "$WARDEN_HOME/lib/router.sh"

install_stub() {
  local name="$1"
  cat > "$SANDBOX/bin/$name" <<STUB
#!/usr/bin/env bash
echo "${name}-ok"
STUB
  chmod +x "$SANDBOX/bin/$name"
}

echo "  router: low-complexity task picks cheapest detected worker"

install_stub deepseek
install_stub claude

decision=$(router_route --task "fix the typo in README" --json)
worker=$(printf '%s' "$decision" | python3 -c 'import json,sys; print(json.load(sys.stdin)["worker"])')
complexity=$(printf '%s' "$decision" | python3 -c 'import json,sys; print(json.load(sys.stdin)["complexity"])')
assert_eq "low" "$complexity" "typo ask is low complexity"
assert_eq "deepseek-chat" "$worker" "low-complexity pick is cheapest model"

echo "  router: high-complexity task picks a frontier harness"

decision=$(router_route --task "redesign the architecture of the auth system" --json)
worker=$(printf '%s' "$decision" | python3 -c 'import json,sys; print(json.load(sys.stdin)["worker"])')
complexity=$(printf '%s' "$decision" | python3 -c 'import json,sys; print(json.load(sys.stdin)["complexity"])')
assert_eq "high" "$complexity" "architecture ask is high complexity"
assert_eq "claude-code" "$worker" "high-complexity pick is frontier harness"

echo "  router: tools needed stay on a harness"

decision=$(router_route --task "implement a login function and add a test" --json)
worker=$(printf '%s' "$decision" | python3 -c 'import json,sys; print(json.load(sys.stdin)["worker"])')
needs=$(printf '%s' "$decision" | python3 -c 'import json,sys; print(json.load(sys.stdin)["needsTools"])')
assert_eq "True" "$needs" "implement+test needs tools"
assert_eq "claude-code" "$worker" "tools ask uses the harness, not a chat model"

echo "  router: missing CLI is not selected"

rm -f "$SANDBOX/bin/deepseek"
decision=$(router_route --task "summarize this paragraph" --json)
worker=$(printf '%s' "$decision" | python3 -c 'import json,sys; print(json.load(sys.stdin)["worker"])')
available=$(printf '%s' "$decision" | python3 -c 'import json,sys; print("deepseek-chat" in json.load(sys.stdin)["available"])')
assert_eq "False" "$available" "deepseek-chat not in available after stub removed"
assert_eq "claude-code" "$worker" "falls back to remaining detected worker"

echo "  router: user rule wins"

install_stub deepseek
cat > "$WARDEN_HOME/config/routing.yaml" <<'YAML'
policy: credits-first
rules:
  - match: { path: "**/security/**" }
    worker: claude-code
  - match: { complexity: low }
    worker: deepseek-chat
YAML

decision=$(router_route --task "look at this" --path "src/security/auth.go" --json)
worker=$(printf '%s' "$decision" | python3 -c 'import json,sys; print(json.load(sys.stdin)["worker"])')
reason=$(printf '%s' "$decision" | python3 -c 'import json,sys; print(json.load(sys.stdin)["reason"])')
assert_eq "claude-code" "$worker" "path rule pins security to claude-code"
assert_eq "user-rule" "$reason" "reason is user-rule"

decision=$(router_route --task "summarize the changelog" --json)
worker=$(printf '%s' "$decision" | python3 -c 'import json,sys; print(json.load(sys.stdin)["worker"])')
assert_eq "deepseek-chat" "$worker" "complexity:low rule picks deepseek-chat"

echo "  router: demoted provider is skipped"

mkdir -p "$WARDEN_HOME/state/rate-guard"
cat > "$WARDEN_HOME/state/rate-guard/state.json" <<'JSON'
{"active": {"demoted": true, "provider": "claude"}}
JSON

decision=$(router_route --task "redesign the architecture of the auth system" --json)
worker=$(printf '%s' "$decision" | python3 -c 'import json,sys; print(json.load(sys.stdin)["worker"])')
demoted=$(printf '%s' "$decision" | python3 -c 'import json,sys; print(json.load(sys.stdin)["demotedProvider"])')
assert_eq "claude" "$demoted" "route reports demoted provider"
assert_neq "claude-code" "$worker" "demoted claude-code is not chosen"

echo "  router: CLI entrypoint"

out=$("$WARDEN_HOME/bin/session-warden" route --task "summarize this" --json)
assert_contains "$out" '"worker"' "session-warden route --json prints worker"

echo "  router: run retries fallback when the first worker fails"

cat > "$SANDBOX/bin/deepseek" <<'STUB'
#!/usr/bin/env bash
echo "deepseek-fail" >&2
exit 7
STUB
chmod +x "$SANDBOX/bin/deepseek"
cat > "$SANDBOX/bin/glm" <<'STUB'
#!/usr/bin/env bash
echo "glm-ok"
STUB
chmod +x "$SANDBOX/bin/glm"
rm -f "$WARDEN_HOME/state/rate-guard/state.json"
rm -f "$WARDEN_HOME/config/routing.yaml"

out=$("$WARDEN_HOME/bin/session-warden" run --task "summarize this paragraph" --json 2>/dev/null)
used=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("fallbackUsed"))')
worker=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("worker"))')
assert_eq "True" "$used" "run used fallback after first worker failed"
assert_eq "glm" "$worker" "fallback worker is glm"
