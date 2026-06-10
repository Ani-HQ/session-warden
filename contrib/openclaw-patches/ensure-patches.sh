#!/usr/bin/env bash
# ensure-patches.sh — re-apply the supported OpenClaw dist patches at gateway boot.
#
# Wire as a non-blocking ExecStartPre on the gateway unit (note the leading `-`):
#   ExecStartPre=-/bin/bash <repo>/contrib/openclaw-patches/ensure-patches.sh
#
# Applies only the patch set known to be safe against the current runtime:
#   - output-limits        (manifest, marker-checked, no-op when present)
#   - error-humanizer      (manifest, marker-checked, no-op when present)
#   - watchdog stall cap   (standalone idempotent script; supersedes the
#                           retired smart-watchdog manifest, see its header)
#
# Never exits non-zero: a failed patch must not block the gateway from starting.
# That exact failure mode (ExecStartPre hard-failing) crash-looped the old
# system-level unit 278k times between 2026-05-22 and 2026-06-10.

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_PREFIX="[ensure-patches]"

# OpenClaw >= 2026.6.5 ships everything these patches fixed as native config:
#   cliBackends.<b>.reliability.outputLimits.{maxTurnRawChars,maxTurnLines}
#   cliBackends.<b>.reliability.watchdog.{fresh,resume}.noOutputTimeoutMs
# Detect native support by its resolver function and skip patching entirely —
# the patches are retired, not just incompatible.
DIST="${OPENCLAW_DIST:-$HOME/.npm-global/lib/node_modules/openclaw/dist}"
if grep -lq "resolveClaudeLiveOutputLimits" "$DIST"/claude-live-session-*.js 2>/dev/null; then
  echo "$LOG_PREFIX native reliability config detected (openclaw >= 2026.6.5) — patches retired, nothing to do"
  exit 0
fi

run() {
  echo "$LOG_PREFIX $*"
  "$@" || echo "$LOG_PREFIX WARN: '$*' failed (exit $?) — continuing"
}

run node "$HERE/patch-manager.js" apply --patch=output-limits
run node "$HERE/patch-manager.js" apply --patch=error-humanizer
run node "$HERE/patch-watchdog-stall-cap.js"

exit 0
