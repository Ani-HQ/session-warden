#!/usr/bin/env bash
# run.sh — invoke a worker, or route then invoke.
#
# Usage:
#   bin/run.sh --worker ID --prompt "..."
#   bin/run.sh --task "..." [--path PATH] [--host ID] [--json]

set -uo pipefail

WARDEN_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WARDEN_HOME

if [ -f "${WARDEN_HOME}/config/thresholds.env" ]; then
  # shellcheck disable=SC1091
  source "${WARDEN_HOME}/config/thresholds.env"
fi

# shellcheck source=../lib/router.sh
source "${WARDEN_HOME}/lib/router.sh"

usage() {
  cat <<'EOF'
Usage: session-warden run --worker ID --prompt "..."
       session-warden run --task "..." [--path PATH] [--host ID] [--json]

Invoke a catalog worker. With --task, route first; if that worker fails,
retry once with the fallback.
EOF
}

json=0
worker=""
prompt=""
task=""
file=""
host=""
paths=()
cwd=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --json) json=1; shift ;;
    --worker) worker="${2:-}"; shift 2 ;;
    --prompt) prompt="${2:-}"; shift 2 ;;
    --task) task="${2:-}"; shift 2 ;;
    --file) file="${2:-}"; shift 2 ;;
    --host) host="${2:-}"; shift 2 ;;
    --cwd) cwd="${2:-}"; shift 2 ;;
    --path)
      paths+=("${2:-}")
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$prompt" ] && [ -n "$file" ]; then
  prompt=$(cat "$file")
fi
if [ -z "$task" ] && [ -n "$file" ] && [ -z "$worker" ]; then
  task=$(cat "$file")
fi

emit_result() {
  local used="$1" used_fallback="$2" raw="$3"
  printf '%s\n' "$raw" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    data = {"exit": 1, "stdout": "", "stderr": raw, "worker": ""}
data["fallbackUsed"] = sys.argv[1] == "1"
data["worker"] = sys.argv[2]
code = int(data.get("exit") or 0)
if sys.argv[3] == "1":
    print(json.dumps(data, indent=2))
    sys.exit(code)
err = data.get("stderr") or ""
if err:
    sys.stderr.write(err if err.endswith("\n") else err + "\n")
sys.stdout.write(data.get("stdout") or "")
sys.exit(code)
' "$used_fallback" "$used" "$json"
}

invoke_json() {
  local id="$1" text="$2"
  local extra=()
  [ -n "$cwd" ] && extra+=(--cwd "$cwd")
  workers_py invoke --worker "$id" --prompt "$text" --json "${extra[@]}"
}

if [ -z "$worker" ]; then
  if [ -z "$task" ]; then
    echo "ERROR: pass --worker and --prompt, or --task" >&2
    usage >&2
    exit 2
  fi
  route_args=(--task "$task" --json)
  [ -n "$host" ] && route_args+=(--host "$host")
  for p in "${paths[@]+"${paths[@]}"}"; do
    route_args+=(--path "$p")
  done
  decision=$(router_route "${route_args[@]}") || true
  worker=$(printf '%s' "$decision" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("worker") or "")')
  fallback=$(printf '%s' "$decision" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("fallback") or "")')
  if [ -z "$worker" ]; then
    echo "ERROR: no available worker for this task" >&2
    [ "$json" = "1" ] && printf '%s\n' "$decision"
    exit 1
  fi
  prompt="${prompt:-$task}"
  first=$(invoke_json "$worker" "$prompt")
  first_exit=$(printf '%s' "$first" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("exit", 1))')
  if [ "$first_exit" != "0" ] && [ -n "$fallback" ]; then
    echo "run: $worker failed (exit $first_exit) — retrying $fallback" >&2
    second=$(invoke_json "$fallback" "$prompt")
    emit_result "$fallback" "1" "$second"
    exit $?
  fi
  emit_result "$worker" "0" "$first"
  exit $?
fi

if [ -z "$prompt" ]; then
  echo "ERROR: --prompt is required with --worker" >&2
  exit 2
fi

raw=$(invoke_json "$worker" "$prompt")
emit_result "$worker" "0" "$raw"
exit $?
