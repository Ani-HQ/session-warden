#!/usr/bin/env bash
# harvest-actions.sh — run the Discord button handler for skill-harvest
# proposal cards (contrib/discord-harvest-actions).
#
# Thin launcher: sources config/thresholds.env (systemd EnvironmentFile can't
# parse its shell-style defaults) and execs the Node listener. Long-running —
# deploy with deploy/harvest-actions.service.
#
# Requires in config/thresholds.env:
#   WARDEN_DISCORD_BOT_TOKEN          bot that posts the proposal cards
#   WARDEN_DISCORD_ALLOWED_USER_IDS   who may click the buttons (default: nobody)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
source "${WARDEN_HOME}/config/thresholds.env"

command -v node >/dev/null 2>&1 || { echo "node not found in PATH" >&2; exit 1; }

APP_DIR="${WARDEN_HOME}/contrib/discord-harvest-actions"
if [ ! -d "${APP_DIR}/node_modules" ]; then
  echo "installing dependencies in ${APP_DIR} ..." >&2
  (cd "$APP_DIR" && npm install --omit=dev --no-audit --no-fund) || exit 1
fi

export WARDEN_HOME
exec node "${APP_DIR}/index.js"
