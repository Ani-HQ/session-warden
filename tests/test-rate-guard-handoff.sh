#!/usr/bin/env bash
# test-rate-guard-handoff.sh — rate-guard demote/restore calls handoff for changed primaries

echo "  rate-guard: handoff on primary change"

RG_HOME="$SANDBOX/rg-home"
mkdir -p "$RG_HOME/bin" "$RG_HOME/lib" "$RG_HOME/state/rate-guard" "$SANDBOX/openclaw"

# Stub handoff that records calls and fails for agent "failme"
cat > "$RG_HOME/bin/handoff.sh" <<'MOCK'
#!/usr/bin/env bash
agent="$1"
reason="$2"
echo "$agent $reason" >> "${WARDEN_HOME}/state/rate-guard/handoff-calls.log"
if [ "$agent" = "failme" ]; then
  exit 1
fi
exit 0
MOCK
chmod +x "$RG_HOME/bin/handoff.sh"
cp "$REAL_WARDEN_HOME/lib/rate-guard.py" "$RG_HOME/lib/rate-guard.py"

# Minimal openclaw.json
python3 - <<'PY'
import json
from pathlib import Path
import os
cfg = {
  "agents": {
    "defaults": {
      "model": {
        "primary": "anthropic/claude-sonnet-4-6",
        "fallbacks": ["openai/gpt-5.6-terra", "google/gemini-3-flash-preview"],
      },
      "models": {},
    },
    "list": [
      {
        "id": "ping",
        "model": {
          "primary": "anthropic/claude-sonnet-5",
          "fallbacks": ["openai/gpt-5.6-terra"],
        },
      },
      {
        "id": "failme",
        "model": {
          "primary": "anthropic/claude-sonnet-4-6",
          "fallbacks": ["openai/gpt-5.6-terra"],
        },
      },
      {
        "id": "codex",
        "model": {
          "primary": "openai/gpt-5.6-sol",
          "fallbacks": ["google/gemini-3-flash-preview"],
        },
      },
    ],
  }
}
Path(os.environ["SANDBOX"], "openclaw", "openclaw.json").write_text(json.dumps(cfg, indent=2))
PY

export WARDEN_HOME="$RG_HOME"
export WARDEN_OPENCLAW_HOME="$SANDBOX/openclaw"

out=$(python3 - <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["WARDEN_HOME"] + "/lib")
# Load module by path
import importlib.util
spec = importlib.util.spec_from_file_location(
    "rate_guard", os.environ["WARDEN_HOME"] + "/lib/rate-guard.py"
)
rg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rg)

# Force CFG paths already set via env in module — reload constants
rg.WARDEN_HOME = __import__("pathlib").Path(os.environ["WARDEN_HOME"])
rg.OPENCLAW_HOME = __import__("pathlib").Path(os.environ["WARDEN_OPENCLAW_HOME"])
rg.CFG = rg.OPENCLAW_HOME / "openclaw.json"
rg.STATE_DIR = rg.WARDEN_HOME / "state" / "rate-guard"
rg.STATE = rg.STATE_DIR / "state.json"
rg.BASELINE = rg.STATE_DIR / "baseline-models.json"
rg.HANDOFF_BIN = rg.WARDEN_HOME / "bin" / "handoff.sh"

result = rg.apply_demotion("claude", 9999999999.0, "test demote")
print(json.dumps(result))
cfg = json.loads(rg.CFG.read_text())
print("PING_PRIMARY=" + cfg["agents"]["list"][0]["model"]["primary"])
print("FAILME_PRIMARY=" + cfg["agents"]["list"][1]["model"]["primary"])
print("CODEX_PRIMARY=" + cfg["agents"]["list"][2]["model"]["primary"])
PY
)

assert_contains "$out" '"action": "demoted"' "demote action when some handoffs ok"
assert_contains "$out" "failme" "failed handoff agent listed"
assert_contains "$out" "PING_PRIMARY=openai/gpt-5.6-terra" "ping demoted after successful handoff"
assert_contains "$out" "FAILME_PRIMARY=anthropic/claude-sonnet-4-6" "failme kept original primary"
assert_contains "$out" "CODEX_PRIMARY=openai/gpt-5.6-sol" "non-claude primary unchanged"

calls=$(cat "$RG_HOME/state/rate-guard/handoff-calls.log" 2>/dev/null || true)
assert_contains "$calls" "ping rate-guard-demote" "handoff called for ping"
assert_contains "$calls" "failme rate-guard-demote" "handoff called for failme"
assert_not_contains "$calls" "codex rate-guard-demote" "handoff not called for unchanged primary"
