#!/usr/bin/env bash
# test-workers.sh — catalog merge, PATH detect, invoke

echo "  workers: catalog lists built-ins"

# shellcheck source=../lib/workers.sh
source "$WARDEN_HOME/lib/workers.sh"

catalog=$(workers_catalog_json)
assert_contains "$catalog" '"id": "claude-code"' "catalog includes claude-code"
assert_contains "$catalog" '"id": "codex"' "catalog includes codex"
assert_contains "$catalog" '"id": "deepseek-chat"' "catalog includes deepseek-chat"
assert_contains "$catalog" '"id": "glm"' "catalog includes glm"

echo "  workers: missing CLI is not available"

claude_flag=$(printf '%s' "$catalog" | python3 -c '
import json,sys
ws=json.load(sys.stdin)["workers"]
print(next(w["available"] for w in ws if w["id"]=="claude-code"))
')
assert_eq "False" "$claude_flag" "claude-code not available without stub"

echo "  workers: stub on WARDEN_WORKER_PATH is detected"

cat > "$SANDBOX/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf 'claude-ok:%s\n' "$*"
STUB
chmod +x "$SANDBOX/bin/claude"

catalog=$(workers_catalog_json)
claude_flag=$(printf '%s' "$catalog" | python3 -c '
import json,sys
ws=json.load(sys.stdin)["workers"]
print(next(w["available"] for w in ws if w["id"]=="claude-code"))
')
assert_eq "True" "$claude_flag" "claude-code available when stub is on WARDEN_WORKER_PATH"

echo "  workers: overlay adds a worker"

mkdir -p "$WARDEN_HOME/config/workers.d"
cat > "$WARDEN_HOME/config/workers.d/local.json" <<'JSON'
{
  "id": "my-local-llm",
  "kind": "model",
  "label": "Local",
  "provider": "local",
  "costClass": "cheap",
  "capabilities": ["chat"],
  "detect": { "commands": ["llama"] },
  "invoke": { "argv": ["llama", "{{prompt}}"], "timeoutSec": 10 }
}
JSON

cat > "$SANDBOX/bin/llama" <<'STUB'
#!/usr/bin/env bash
printf 'llama:%s\n' "$1"
STUB
chmod +x "$SANDBOX/bin/llama"

catalog=$(workers_catalog_json)
assert_contains "$catalog" '"id": "my-local-llm"' "overlay worker appears in catalog"
local_flag=$(printf '%s' "$catalog" | python3 -c '
import json,sys
ws=json.load(sys.stdin)["workers"]
print(next(w["available"] for w in ws if w["id"]=="my-local-llm"))
')
assert_eq "True" "$local_flag" "overlay worker is detected"

echo "  workers: invoke runs the stub"

out=$(workers_invoke my-local-llm "hello")
assert_contains "$out" "llama:hello" "invoke substitutes prompt and runs argv"

echo "  workers: CLI table"

table=$("$WARDEN_HOME/bin/session-warden" workers)
assert_contains "$table" "claude-code" "workers CLI lists claude-code"
assert_contains "$table" "yes" "workers CLI shows a detected worker"
