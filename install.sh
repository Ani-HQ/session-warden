#!/usr/bin/env bash
# install.sh — set up session-warden cron-based scanner
set -e

WARDEN_HOME="${WARDEN_HOME:-$HOME/session-warden}"

echo "session-warden installer"
echo "======================"

# Check dependencies
for cmd in jq claude curl; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd not found"; exit 1; }
done

# Check config
if [ ! -f "$WARDEN_HOME/config/thresholds.env" ]; then
  echo "Creating config from example..."
  cp "$WARDEN_HOME/config/thresholds.env.example" "$WARDEN_HOME/config/thresholds.env"
  echo "EDIT $WARDEN_HOME/config/thresholds.env with your values before starting."
  exit 1
fi

# Make scripts executable
chmod +x "$WARDEN_HOME/bin/"*.sh
chmod +x "$WARDEN_HOME/lib/"*.sh
chmod +x "$WARDEN_HOME/install.sh"

# Create state directories
mkdir -p "$WARDEN_HOME/state/pending-summaries" "$WARDEN_HOME/state/cooldowns"

# Install cron job (every 30 seconds via two entries)
CRON_CMD_A="* * * * * /bin/bash ${WARDEN_HOME}/bin/scan.sh"
CRON_CMD_B="* * * * * sleep 30 && /bin/bash ${WARDEN_HOME}/bin/scan.sh"
CRON_TAG="# session-warden"

# Remove existing session-warden cron entries if present
( crontab -l 2>/dev/null | grep -v "$CRON_TAG" ; echo "${CRON_CMD_A} ${CRON_TAG}" ; echo "${CRON_CMD_B} ${CRON_TAG}-30s" ) | crontab -

echo ""
echo "Installed:"
echo "  Cron: every 30 seconds → ${WARDEN_HOME}/bin/scan.sh"
echo "  Log:  ${WARDEN_HOME}/state/scan.log"
echo ""
echo "Verify with: crontab -l | grep session-warden"
echo "Test with:   WARDEN_DRY_RUN=1 bash ${WARDEN_HOME}/bin/scan.sh"
echo "Monitor:     tail -f ${WARDEN_HOME}/state/scan.log"
