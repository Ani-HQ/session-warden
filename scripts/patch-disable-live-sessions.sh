#!/usr/bin/env bash
# patch-disable-live-sessions.sh
# Forces OpenClaw to use oneshot mode instead of live sessions for claude-cli.
# Live sessions crash silently under concurrent load (activeSessions >= 3).
# Oneshot mode is slower (~22s startup per message for MCP loading) but reliable.
#
# FRAGILE: patches compiled JS. Re-run after any openclaw update.
# Marker: __OPENCLAW_LIVE_SESSION_DISABLED__

set -euo pipefail

OPENCLAW_DIST="${HOME}/.npm-global/lib/node_modules/openclaw/dist"
TARGET="${OPENCLAW_DIST}/execute.runtime-rara7Weg.js"
MARKER="__OPENCLAW_LIVE_SESSION_DISABLED__"

if [ ! -f "$TARGET" ]; then
  echo "ERROR: target file not found: $TARGET"
  echo "OpenClaw may have been updated (runtime hash changed). Find the new execute.runtime-*.js file."
  exit 1
fi

if grep -q "$MARKER" "$TARGET"; then
  echo "already patched (marker found)"
  exit 0
fi

# Patch shouldUseClaudeLiveSession to always return false
if ! grep -q 'function shouldUseClaudeLiveSession(context)' "$TARGET"; then
  echo "ERROR: function shouldUseClaudeLiveSession not found in $TARGET"
  exit 1
fi

sed -i '/function shouldUseClaudeLiveSession(context) {/{
  N
  s/function shouldUseClaudeLiveSession(context) {\n\treturn .*/function shouldUseClaudeLiveSession(context) {\n\treturn false; \/* '"$MARKER"' force oneshot mode to prevent concurrent session crashes *\//
}' "$TARGET"

if grep -q "$MARKER" "$TARGET"; then
  echo "patched: live sessions disabled (oneshot mode forced)"
else
  echo "ERROR: patch failed — marker not found after sed"
  exit 1
fi
