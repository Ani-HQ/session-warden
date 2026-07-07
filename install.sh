#!/usr/bin/env bash
# install.sh — set up session-warden cron-based scanner
set -e

WARDEN_HOME="${WARDEN_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

echo "session-warden installer"
echo "========================"
echo ""

# ─── Check dependencies ──────────────────────────────────

missing=0
for cmd in jq claude curl; do
  if command -v "$cmd" >/dev/null; then
    echo "  [ok] $cmd"
  else
    echo "  [missing] $cmd"
    missing=1
  fi
done

# Optional deps
optional_note() {
  case "$1" in
    python3) echo "crash buffer detection" ;;
    gbrain)  echo "snapshot module + GBrain knowledge-graph memory" ;;
  esac
}
for cmd in python3 gbrain; do
  if command -v "$cmd" >/dev/null; then
    echo "  [ok] $cmd (optional: $(optional_note "$cmd"))"
  else
    echo "  [--] $cmd not found (optional: $(optional_note "$cmd") will be skipped)"
  fi
done

if [ "$missing" -eq 1 ]; then
  echo ""
  echo "ERROR: required dependencies missing. Install them and re-run."
  exit 1
fi
echo ""

# ─── Detect OpenClaw ──────────────────────────────────────

OPENCLAW_HOME=""
if [ -d "$HOME/.openclaw" ] && [ -f "$HOME/.openclaw/openclaw.json" ]; then
  OPENCLAW_HOME="$HOME/.openclaw"
  agent_count=$(ls -d "$OPENCLAW_HOME/agents/"*/ 2>/dev/null | wc -l)
  echo "  [ok] OpenClaw found at $OPENCLAW_HOME ($agent_count agents)"
elif command -v openclaw >/dev/null; then
  echo "  [ok] openclaw CLI found, but no config at ~/.openclaw"
  echo "       Run 'openclaw doctor' first, then re-run this installer."
  exit 1
else
  echo "  [!!] OpenClaw not found."
  echo "       session-warden requires OpenClaw to manage agent sessions."
  echo "       Install OpenClaw first: npm install -g openclaw"
  exit 1
fi
echo ""

# ─── Create config ────────────────────────────────────────

CONFIG_FILE="$WARDEN_HOME/config/thresholds.env"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "Creating config from example..."
  cp "$WARDEN_HOME/config/thresholds.env.example" "$CONFIG_FILE"

  # Auto-fill detected OpenClaw path
  if [ -n "$OPENCLAW_HOME" ]; then
    sed -i "s|^WARDEN_OPENCLAW_HOME=.*|WARDEN_OPENCLAW_HOME=${OPENCLAW_HOME}|" "$CONFIG_FILE"
  fi

  echo ""
  echo "  Config created: $CONFIG_FILE"
  echo "  Review and edit thresholds, then re-run this installer."
  echo ""
  echo "  Key settings to check:"
  echo "    WARDEN_MAX_TOKENS    — when to rotate (default: 2M tokens)"
  echo "    WARDEN_TELEGRAM_*    — optional alert credentials"
  echo ""
  exit 0
fi
echo "  [ok] Config exists: $CONFIG_FILE"
echo ""

# ─── Make scripts executable ──────────────────────────────

chmod +x "$WARDEN_HOME/bin/"*.sh "$WARDEN_HOME/bin/"*.js 2>/dev/null || true
chmod +x "$WARDEN_HOME/lib/"*.sh 2>/dev/null || true
chmod +x "$WARDEN_HOME/install.sh"

# ─── Create state directories ────────────────────────────

mkdir -p \
  "$WARDEN_HOME/state/pending-summaries" \
  "$WARDEN_HOME/state/cooldowns" \
  "$WARDEN_HOME/state/context-sync" \
  "$WARDEN_HOME/state/crash-buffers" \
  "$WARDEN_HOME/state/pending-recoveries" \
  "$WARDEN_HOME/state/mcp-supervisor" \
  "$WARDEN_HOME/state/reap" \
  "$WARDEN_HOME/state/snapshot"

# ─── Install cron ─────────────────────────────────────────

CRON_CMD_A="* * * * * /bin/bash ${WARDEN_HOME}/bin/scan.sh"
CRON_CMD_B="* * * * * sleep 30 && /bin/bash ${WARDEN_HOME}/bin/scan.sh"
CRON_CMD_REAP_A="* * * * * /bin/bash ${WARDEN_HOME}/bin/reap-stalls.sh"
CRON_CMD_REAP_B="* * * * * sleep 30 && /bin/bash ${WARDEN_HOME}/bin/reap-stalls.sh"
SNAP_INTERVAL="${WARDEN_SNAPSHOT_INTERVAL_MINUTES:-30}"
CRON_CMD_SNAP="*/${SNAP_INTERVAL} * * * * /bin/bash ${WARDEN_HOME}/bin/snapshot.sh"
CRON_CMD_DOCTOR="*/5 * * * * /bin/bash ${WARDEN_HOME}/bin/doctor.sh --alert >/dev/null 2>&1"
CRON_TAG="# session-warden"

# Remove existing session-warden cron entries, then add fresh ones.
# (The snapshot/reap/doctor tags also contain "# session-warden", so the grep -v clears them too.)
# WARDEN_CRONTAB_CMD lets tests target a mock crontab instead of the real one.
CRONTAB_CMD="${WARDEN_CRONTAB_CMD:-crontab}"
( $CRONTAB_CMD -l 2>/dev/null | grep -v "$CRON_TAG" ; \
  echo "${CRON_CMD_A} ${CRON_TAG}" ; \
  echo "${CRON_CMD_B} ${CRON_TAG}-30s" ; \
  echo "${CRON_CMD_REAP_A} ${CRON_TAG}-reap" ; \
  echo "${CRON_CMD_REAP_B} ${CRON_TAG}-reap-30s" ; \
  echo "${CRON_CMD_SNAP} ${CRON_TAG}-snapshot" ; \
  echo "${CRON_CMD_DOCTOR} ${CRON_TAG}-doctor" ) | $CRONTAB_CMD -

echo "Installed:"
echo "  Cron:    every 30 seconds -> ${WARDEN_HOME}/bin/scan.sh"
echo "  Cron:    every 30 seconds -> ${WARDEN_HOME}/bin/reap-stalls.sh"
echo "  Cron:    every ${SNAP_INTERVAL} min  -> ${WARDEN_HOME}/bin/snapshot.sh"
echo "  Cron:    every 5 min  -> ${WARDEN_HOME}/bin/doctor.sh --alert (self-health)"
echo "  Config:  ${CONFIG_FILE}"
echo "  Log:     ${WARDEN_HOME}/state/scan.log"
echo "  Agents:  ${OPENCLAW_HOME}/agents/"
echo ""
echo "Verify:    crontab -l | grep session-warden"
echo "Dry run:   WARDEN_DRY_RUN=1 bash ${WARDEN_HOME}/bin/scan.sh"
echo "Monitor:   tail -f ${WARDEN_HOME}/state/scan.log"
