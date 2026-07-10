#!/usr/bin/env bash
# burn-solo-sample.sh — standalone timer entry point for solo burn sampling

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
export WARDEN_HOME

# shellcheck source=/dev/null  # Optional deployment-local configuration.
[ -f "${WARDEN_HOME}/config/thresholds.env" ] && source "${WARDEN_HOME}/config/thresholds.env"
# shellcheck source=/dev/null  # Resolved from WARDEN_HOME at runtime.
source "${WARDEN_HOME}/lib/burn-solo.sh"

mkdir -p "${WARDEN_HOME}/state" 2>/dev/null || true
touch "${WARDEN_HOME}/state/.last-solo-sample-ts" 2>/dev/null || true
burn_solo_sample || true
burn_solo_check || true
exit 0
