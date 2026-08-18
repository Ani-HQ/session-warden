#!/usr/bin/env bash
# handoff.sh — CLI/entry wrapper for lib/handoff.sh
#
# Usage:
#   bin/handoff.sh <agent> [reason] [--force]
#
# Exit codes match handoff_agent (0 ok, 1 refused/empty, 2 unknown agent).

set -uo pipefail

WARDEN_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WARDEN_HOME

if [ -f "${WARDEN_HOME}/config/thresholds.env" ]; then
  # shellcheck disable=SC1091
  source "${WARDEN_HOME}/config/thresholds.env"
fi

# shellcheck source=../lib/handoff.sh
source "${WARDEN_HOME}/lib/handoff.sh"

if [ $# -lt 1 ]; then
  echo "Usage: handoff.sh <agent> [reason] [--force]" >&2
  exit 2
fi

agent="$1"
shift
reason="manual"
force_flag=()
while [ $# -gt 0 ]; do
  case "$1" in
    --force) force_flag=(--force); shift ;;
    model-switch|rate-guard-demote|rate-guard-restore|manual)
      reason="$1"; shift ;;
    *)
      # treat unknown positional as reason once
      if [ "$reason" = "manual" ] && [[ "$1" != -* ]]; then
        reason="$1"; shift
      else
        echo "Unknown arg: $1" >&2
        exit 2
      fi
      ;;
  esac
done

handoff_agent "$agent" "$reason" "${force_flag[@]}"
exit $?
