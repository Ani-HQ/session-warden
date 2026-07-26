#!/usr/bin/env bash
# fleet-live/generate.sh — public redacted spectator board for fleet.ani.computer
set -euo pipefail

export HOME="${HOME:-/home/$(id -un)}"
export PATH="$HOME/.npm-global/bin:$HOME/.bun/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR
export FLEET_OUT="${FLEET_OUT:-/var/www/fleet}"
mkdir -p "$FLEET_OUT"

python3 "$SCRIPT_DIR/collect.py"
python3 "$SCRIPT_DIR/bake.py"

echo "fleet-live ok $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
