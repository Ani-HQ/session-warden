#!/usr/bin/env bash
# model-switch.sh — handoff then change an agent's primary model.
#
# Usage:
#   bin/model-switch.sh <agent> <model> [--restart] [--force]
#
# OpenClaw: edits openclaw.json (hot-reload; --restart optional).
# Hermes: edits ~/.hermes-<agent>/config.yaml and restarts hermes-<agent>-gateway.

set -uo pipefail

WARDEN_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WARDEN_HOME

if [ -f "${WARDEN_HOME}/config/thresholds.env" ]; then
  # shellcheck disable=SC1091
  source "${WARDEN_HOME}/config/thresholds.env"
fi

# shellcheck source=../lib/handoff.sh
source "${WARDEN_HOME}/lib/handoff.sh"

OPENCLAW_HOME="${WARDEN_OPENCLAW_HOME:-$HOME/.openclaw}"
CFG="${OPENCLAW_HOME}/openclaw.json"
HERMES_BIN="${WARDEN_HERMES_BIN:-$HOME/hermes-agent/venv/bin/hermes}"

usage() {
  cat <<'EOF'
Usage: session-warden model-switch <agent> <model> [--restart] [--force]

Checkpoint live work to memory + GBrain, then set the agent's primary model.

  --force    allow switch even if handoff extract is empty
  --restart  restart openclaw-gateway after OpenClaw config edit (default: no;
             Hermes always restarts its own gateway)
EOF
}

if [ $# -lt 2 ]; then
  usage
  exit 2
fi

agent="$1"
model="$2"
shift 2
force=0
restart=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force) force=1; shift ;;
    --restart) restart=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

runtime=$(handoff_detect_runtime "$agent") || true
if [ "$runtime" = "unknown" ]; then
  echo "ERROR: unknown agent '$agent' (no OpenClaw or Hermes home)" >&2
  exit 2
fi

force_args=()
[ "$force" = "1" ] && force_args=(--force)

echo "Handoff $agent ($runtime) before model → $model ..."
if ! handoff_agent "$agent" "model-switch" "${force_args[@]}"; then
  echo "ERROR: handoff failed for $agent — refusing model switch (use --force to override)" >&2
  exit 1
fi

queue_openclaw_recovery() {
  local agent="$1" slug="${2:-}"
  local recovery_dir="${WARDEN_HOME}/state/pending-recoveries"
  mkdir -p "$recovery_dir"
  local sjson="${OPENCLAW_HOME}/agents/${agent}/sessions/sessions.json"
  [ -f "$sjson" ] || return 0
  local channel_key
  channel_key=$(jq -r '
    to_entries
    | map(select(.value.cliSessionIds["claude-cli"] // "" | length > 0))
    | sort_by(.value.updatedAt // 0) | reverse | .[0].key // empty
  ' "$sjson" 2>/dev/null)
  [ -n "$channel_key" ] || return 0
  local safe
  safe=$(echo "$channel_key" | sed 's/[^a-zA-Z0-9_-]/_/g')
  local slug_file="${WARDEN_HOME}/state/handoff/${agent}.${safe}.slug"
  [ -z "$slug" ] && [ -f "$slug_file" ] && slug=$(cat "$slug_file")
  local outfile="${recovery_dir}/${agent}-${safe}-model-switch.json"
  jq -n \
    --arg agent "$agent" \
    --arg channel "$channel_key" \
    --arg reason "model-switch" \
    --arg slug "$slug" \
    --arg model "$model" \
    --argjson ts "$(date +%s)" \
    '{agent:$agent, channel_key:$channel, reason:$reason, gbrain_slug:$slug, model:$model, queuedAt:$ts}' \
    > "$outfile"
  echo "Queued recovery for $agent / $channel_key"
}

apply_openclaw_model() {
  local agent="$1" model="$2"
  [ -f "$CFG" ] || { echo "ERROR: missing $CFG" >&2; return 1; }
  local bak="${CFG}.bak-model-switch-$(date +%Y%m%d-%H%M%S)"
  cp "$CFG" "$bak"

  python3 - "$CFG" "$agent" "$model" <<'PY'
import json, sys
from pathlib import Path
cfg_path, agent, model = sys.argv[1], sys.argv[2], sys.argv[3]
c = json.loads(Path(cfg_path).read_text())
# allowlist
models = c.setdefault("agents", {}).setdefault("defaults", {}).setdefault("models", {})
models.setdefault(model, {})
# ensure google provider entry for google/* models
if model.startswith("google/"):
    mid = model.split("/", 1)[1]
    google = c.setdefault("models", {}).setdefault("providers", {}).setdefault("google", {})
    glist = google.setdefault("models", [])
    if not any(m.get("id") == mid for m in glist if isinstance(m, dict)):
        glist.append({
            "id": mid,
            "name": mid,
            "reasoning": True,
            "input": ["text", "image"],
            "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
            "contextWindow": 1048576,
            "maxTokens": 65536,
        })
found = False
for a in c.get("agents", {}).get("list", []):
    if a.get("id") != agent:
        continue
    found = True
    old = a.get("model") or {}
    if isinstance(old, str):
        prev, fbs = old, []
    else:
        prev = old.get("primary")
        fbs = list(old.get("fallbacks") or [])
    fallbacks = []
    if prev and prev != model:
        fallbacks.append(prev)
    for f in fbs:
        if f not in fallbacks and f != model:
            fallbacks.append(f)
    a["model"] = {"primary": model, "fallbacks": fallbacks}
    break
if not found:
    sys.exit(3)
Path(cfg_path).write_text(json.dumps(c, indent=2) + "\n")
print(json.dumps({"primary": model, "fallbacks": fallbacks}))
PY
  local rc=$?
  if [ "$rc" -eq 3 ]; then
    echo "ERROR: agent '$agent' not in openclaw.json agents.list" >&2
    mv "$bak" "$CFG"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    echo "ERROR: failed to edit openclaw.json" >&2
    mv "$bak" "$CFG"
    return 1
  fi
  echo "Updated OpenClaw model for $agent (backup $bak)"
  if [ "$restart" = "1" ]; then
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    systemctl --user restart openclaw-gateway.service
    echo "Restarted openclaw-gateway"
  else
    echo "OpenClaw hot-reloads model chains — no gateway restart (pass --restart to force)"
  fi
  queue_openclaw_recovery "$agent"
}

apply_hermes_model() {
  local agent="$1" model="$2"
  local hermes_home cfg
  hermes_home=$(hermes_home_for "$agent")
  cfg="${hermes_home}/config.yaml"
  [ -f "$cfg" ] || { echo "ERROR: missing $cfg" >&2; return 1; }
  local bak="${cfg}.bak-model-switch-$(date +%Y%m%d-%H%M%S)"
  cp "$cfg" "$bak"
  python3 - "$cfg" "$model" <<'PY'
import re, sys
from pathlib import Path
cfg_path, model = Path(sys.argv[1]), sys.argv[2]
text = cfg_path.read_text()
new, n = re.subn(
    r"(^model:\n  default: ).+$",
    rf"\1{model}",
    text,
    count=1,
    flags=re.M,
)
if n != 1:
    # fallback: first `default:` under model block
    new, n = re.subn(r"(^  default: ).+$", rf"\1{model}", text, count=1, flags=re.M)
if n != 1:
    sys.exit(3)
cfg_path.write_text(new)
print(model)
PY
  if [ $? -ne 0 ]; then
    echo "ERROR: could not update model.default in $cfg" >&2
    mv "$bak" "$cfg"
    return 1
  fi
  echo "Updated Hermes model for $agent → $model (backup $bak)"
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  systemctl --user restart "hermes-${agent}-gateway.service"
  echo "Restarted hermes-${agent}-gateway"

  # Best-effort wake via hermes send into active telegram session
  local slug="" meta="${WARDEN_HOME}/state/handoff/${agent}.meta"
  [ -f "${WARDEN_HOME}/state/handoff/${agent}.hermes.slug" ] && \
    slug=$(cat "${WARDEN_HOME}/state/handoff/${agent}.hermes.slug")
  local msg
  msg="Model switched to ${model}. Read memories/HANDOFF.md and CONTEXT.md first"
  [ -n "$slug" ] && msg="${msg} (gbrain: ${slug})"
  msg="${msg}, then resume pending work. Do not ask what you were doing — the handoff has it."

  if [ -x "$HERMES_BIN" ]; then
    # Try to discover a telegram chat from sessions.json / channel_directory
    local target=""
    if [ -f "${hermes_home}/sessions/sessions.json" ]; then
      target=$(jq -r '
        to_entries
        | map(select(.key | test("telegram")))
        | sort_by(.value.updated_at // "") | reverse
        | .[0].value.origin.chat_id // empty
      ' "${hermes_home}/sessions/sessions.json" 2>/dev/null || true)
    fi
    if [ -n "$target" ]; then
      HERMES_HOME="$hermes_home" timeout 30 "$HERMES_BIN" send \
        --platform telegram --target "$target" --message "$msg" \
        >/dev/null 2>&1 \
        && echo "Sent Hermes wake to telegram:$target" \
        || echo "WARN: hermes send failed (files still written)"
    else
      echo "No telegram target found — handoff files written; no wake send"
    fi
  fi
}

case "$runtime" in
  openclaw) apply_openclaw_model "$agent" "$model" ;;
  hermes)   apply_hermes_model "$agent" "$model" ;;
esac
exit $?
