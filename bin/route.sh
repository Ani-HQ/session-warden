#!/usr/bin/env bash
# route.sh — pick a worker for a task (rules, then credits-first).
#
# Usage:
#   bin/route.sh --task "..." [--path PATH] [--tag TAG] [--host ID] [--json]
#   bin/route.sh --file TASK.txt [--json]

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
Usage: session-warden route --task "..." [--path PATH] [--tag TAG] [--host ID] [--json]
       session-warden route --file TASK.txt [--json]

Pick a bash worker. User rules in config/routing.yaml win when the worker
is available; otherwise credits-first heuristics pick the cheapest capable
one. Rate-guard-demoted providers are skipped.
EOF
}

if [ $# -eq 0 ]; then
  usage >&2
  exit 2
fi

args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --task|--file|--path|--tag|--host)
      if [ $# -lt 2 ]; then
        echo "ERROR: $1 needs a value" >&2
        exit 2
      fi
      args+=("$1" "$2")
      shift 2
      ;;
    --json) args+=(--json); shift ;;
    *)
      echo "Unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

router_route "${args[@]}"
