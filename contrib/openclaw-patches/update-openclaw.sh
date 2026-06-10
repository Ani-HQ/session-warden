#!/usr/bin/env bash
# update-openclaw.sh — update OpenClaw without silently losing the dist patches.
#
# The dist patches (output-limits, watchdog stall cap, error humanizer) live in
# compiled JS that `npm install -g openclaw` replaces wholesale. This script
# makes updates a deliberate, verified operation:
#
#   1. snapshot the current package dir (rollback point)
#   2. install the requested version
#   3. re-apply patches via ensure-patches.sh
#   4. verify every patch marker is present in the new dist
#   5. tell you exactly what to do next (restart is YOUR call, never automatic)
#
# Usage:
#   update-openclaw.sh                 # update to latest
#   update-openclaw.sh 2026.6.1        # update to a specific version
#   update-openclaw.sh --rollback      # restore the last pre-update snapshot

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="${OPENCLAW_PKG_DIR:-$HOME/.npm-global/lib/node_modules/openclaw}"
SNAP_DIR="${OPENCLAW_SNAP_DIR:-$HOME/.openclaw/_archive}"
SNAP_TARBALL="${SNAP_DIR}/openclaw-pre-update.tar.gz"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -d "$PKG_DIR" ] || die "openclaw package not found at $PKG_DIR"

current_version=$(node -p "require('${PKG_DIR}/package.json').version" 2>/dev/null || echo "unknown")

if [ "${1:-}" = "--rollback" ]; then
  [ -f "$SNAP_TARBALL" ] || die "no snapshot at $SNAP_TARBALL"
  echo "Rolling back openclaw (currently ${current_version}) from snapshot..."
  rm -rf "$PKG_DIR"
  mkdir -p "$PKG_DIR"
  tar -xzf "$SNAP_TARBALL" -C "$(dirname "$PKG_DIR")" || die "rollback extraction failed"
  restored=$(node -p "require('${PKG_DIR}/package.json').version" 2>/dev/null || echo "unknown")
  echo "Restored openclaw ${restored}."
  echo "Restart the gateway when ready: systemctl --user restart openclaw-gateway.service"
  exit 0
fi

target="${1:-latest}"
echo "openclaw update: ${current_version} -> ${target}"
echo ""

# ─── 1. Snapshot ─────────────────────────────────────────
mkdir -p "$SNAP_DIR"
echo "[1/4] Snapshotting current package (${current_version})..."
tar -czf "$SNAP_TARBALL" -C "$(dirname "$PKG_DIR")" "$(basename "$PKG_DIR")" \
  || die "snapshot failed — aborting before any change"
echo "      -> $SNAP_TARBALL ($(du -h "$SNAP_TARBALL" | cut -f1))"

# ─── 2. Install ──────────────────────────────────────────
echo "[2/4] Installing openclaw@${target}..."
npm install -g "openclaw@${target}" || die "npm install failed — package unchanged or partially changed; --rollback if needed"
new_version=$(node -p "require('${PKG_DIR}/package.json').version" 2>/dev/null || echo "unknown")
echo "      -> installed ${new_version}"

# ─── 3. Re-apply patches ─────────────────────────────────
echo "[3/4] Re-applying dist patches..."
bash "${HERE}/ensure-patches.sh"

# ─── 4. Verify markers ───────────────────────────────────
echo "[4/4] Verifying patch markers in new dist..."
DIST="${PKG_DIR}/dist"
dist_js=$(find "$DIST" -maxdepth 1 -name '*.js' 2>/dev/null)
missing=0
check() {
  local label="$1"; shift
  local m
  for m in "$@"; do
    if grep -lq "$m" $dist_js 2>/dev/null; then
      echo "  [ok]      $label"
      return 0
    fi
  done
  echo "  [MISSING] $label"
  missing=1
}
check "output-limits"      "__WARDEN_OUTPUT_LIMITS__"
check "watchdog-stall-cap" "__OC_HARD_TURN_CAP_MS"
check "error-humanizer"    "__WARDEN_ERROR_HUMANIZER__" "__OPENCLAW_ERROR_HUMANIZER_PATCHED__"

echo ""
if [ "$missing" -eq 1 ]; then
  echo "RESULT: ${current_version} -> ${new_version}, but some patches did NOT re-apply."
  echo "The new compiled code likely shifted past the patch anchors. Options:"
  echo "  - inspect: node ${HERE}/patch-manager.js status"
  echo "  - retry:   node ${HERE}/patch-manager.js apply --patch=<id> -v"
  echo "  - revert:  $0 --rollback"
  echo ""
  echo "Do NOT restart the gateway until you've decided — the running process"
  echo "still has the old (patched) code in memory."
  exit 1
fi

echo "RESULT: ${current_version} -> ${new_version}, all patches verified."
echo "Restart when ready (low-traffic window recommended):"
echo "  systemctl --user restart openclaw-gateway.service"
echo "  journalctl --user -u openclaw-gateway.service -f   # watch for 10 min"
echo "Rollback available: $0 --rollback"
