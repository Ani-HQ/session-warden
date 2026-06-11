#!/usr/bin/env bash
# channel-parity.sh — every enabled channel in openclaw.json must have an
# installed+enabled plugin that provides it.
#
# Born from a real incident (2026-06-11): the 2026.6.5 upgrade unbundled the
# Discord plugin from openclaw core. The gateway booted "healthy", started
# Telegram, and silently ignored channels.discord.enabled=true — no error, no
# log line, no health alert. All Discord agents were deaf for ~14 hours.
#
# Usage:
#   channel-parity.sh check    report parity, exit 0 in-parity / 1 mismatch
#   channel-parity.sh heal     check, then for each missing channel:
#                                - install the OFFICIAL plugin (@openclaw/<id>
#                                  scope only — never community code)
#                                - schedule one gateway restart
#                                - alert via warden Telegram
#                              Loop-guarded: one heal attempt per channel per
#                              CHANNEL_PARITY_COOLDOWN_SECONDS (default 6h).
#
# Wiring (three layers):
#   boot:    deploy/20-channel-parity.conf -> ExecStartPost heal
#   cron:    bin/doctor.sh runs `check` on its existing 5-min cadence
#   upgrade: update-openclaw.sh runs `check` before blessing an update

set -uo pipefail

MODE="${1:-check}"
OC_JSON="${OPENCLAW_CONFIG:-$HOME/.openclaw/openclaw.json}"
OC_BIN="${OPENCLAW_BIN:-$HOME/.npm-global/bin/openclaw}"
[ -x "$OC_BIN" ] || OC_BIN="$(command -v openclaw || true)"
STATE_DIR="${CHANNEL_PARITY_STATE_DIR:-$HOME/.openclaw/logs}"
COOLDOWN="${CHANNEL_PARITY_COOLDOWN_SECONDS:-21600}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(cd "$HERE/../.." && pwd)}"

log() { echo "[channel-parity] $*"; logger -t channel-parity "$*" 2>/dev/null || true; }

# Missing prerequisites must not break gateway startup — report and bail soft.
command -v jq >/dev/null 2>&1 || { log "jq not found; skipping"; exit 0; }
[ -f "$OC_JSON" ] || { log "config not found: $OC_JSON; skipping"; exit 0; }
[ -n "$OC_BIN" ] && [ -x "$OC_BIN" ] || { log "openclaw binary not found; skipping"; exit 0; }

enabled_channels=$(jq -r '.channels // {} | to_entries[] | select(.value.enabled == true) | .key' "$OC_JSON" 2>/dev/null)
[ -z "$enabled_channels" ] && exit 0

# Reads the persisted plugin registry — works whether or not the gateway is up.
plugins_json=$("$OC_BIN" plugins list --json 2>/dev/null)
[ -z "$plugins_json" ] && { log "could not read plugin registry; skipping"; exit 0; }
provided=$(echo "$plugins_json" | jq -r '.plugins[] | select(.enabled == true) | .channelIds[]?' 2>/dev/null | sort -u)

missing=()
for ch in $enabled_channels; do
  if echo "$provided" | grep -qx "$ch"; then
    echo "  [ok]      channel '$ch' has an enabled plugin"
  else
    echo "  [MISSING] channel '$ch' is enabled in config but NO enabled plugin provides it"
    missing+=("$ch")
  fi
done

[ "${#missing[@]}" -eq 0 ] && exit 0
[ "$MODE" != "heal" ] && exit 1

# ─── heal ────────────────────────────────────────────────
# shellcheck disable=SC1091
[ -f "${WARDEN_HOME}/config/thresholds.env" ] && source "${WARDEN_HOME}/config/thresholds.env"
# shellcheck disable=SC1091
[ -f "${WARDEN_HOME}/lib/notify.sh" ] && source "${WARDEN_HOME}/lib/notify.sh"

alert() {
  type notify_alert >/dev/null 2>&1 && notify_alert "$1" "${2:-}" || true
}

mkdir -p "$STATE_DIR"
healed=0
for ch in "${missing[@]}"; do
  stamp="${STATE_DIR}/.parity-heal-${ch}"
  last=$(cat "$stamp" 2>/dev/null || echo 0)
  now=$(date +%s)
  if [ $((now - last)) -lt "$COOLDOWN" ]; then
    # A heal already ran recently and the channel is still down — do not
    # install/restart again (loop guard). Doctor's cron alerting owns this now.
    log "channel '$ch' still missing but heal ran $((now - last))s ago; standing down"
    continue
  fi
  echo "$now" > "$stamp"
  log "channel '$ch' has no plugin — installing official clawhub:@openclaw/${ch}"
  if "$OC_BIN" plugins install "clawhub:@openclaw/${ch}" >>"${STATE_DIR}/channel-parity.log" 2>&1; then
    log "installed @openclaw/${ch}"
    alert "channel-parity auto-healed '${ch}'" "channels.${ch} was enabled in openclaw.json but no plugin provided it (the 2026.6.5-unbundling failure mode). Installed clawhub:@openclaw/${ch}; restarting gateway."
    healed=1
  else
    log "install of @openclaw/${ch} FAILED — manual fix needed"
    alert "channel-parity could NOT heal '${ch}'" "channels.${ch} is enabled but has no plugin, and auto-install of clawhub:@openclaw/${ch} failed. Fix manually: ${OC_BIN} plugins install clawhub:@openclaw/${ch} && systemctl --user restart openclaw-gateway.service"
  fi
done

if [ "$healed" -eq 1 ]; then
  log "scheduling gateway restart to load newly installed plugin(s)"
  # When run as the gateway's own ExecStartPost we live inside the unit's
  # cgroup (KillMode=control-group); a plain `systemctl restart` would kill
  # this script mid-flight. systemd-run escapes into a transient unit.
  if command -v systemd-run >/dev/null 2>&1; then
    systemd-run --user --collect --on-active=3 \
      systemctl --user restart openclaw-gateway.service >/dev/null 2>&1 \
      || systemctl --user restart openclaw-gateway.service
  else
    systemctl --user restart openclaw-gateway.service
  fi
fi
exit 1
