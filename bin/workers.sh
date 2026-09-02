#!/usr/bin/env bash
# workers.sh — list catalog workers and whether they are on PATH.
#
# Usage:
#   bin/workers.sh [--json]

set -uo pipefail

WARDEN_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WARDEN_HOME

if [ -f "${WARDEN_HOME}/config/thresholds.env" ]; then
  # shellcheck disable=SC1091
  source "${WARDEN_HOME}/config/thresholds.env"
fi

# shellcheck source=../lib/workers.sh
source "${WARDEN_HOME}/lib/workers.sh"

json=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) json=1; shift ;;
    -h|--help)
      echo "Usage: session-warden workers [--json]"
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      echo "Usage: session-warden workers [--json]" >&2
      exit 2
      ;;
  esac
done

if [ "$json" = "1" ]; then
  workers_catalog_json
else
  workers_list
fi
