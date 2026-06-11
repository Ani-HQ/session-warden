#!/usr/bin/env bash
# doctor.sh — verify the warden itself is alive and correctly wired.
#
# The warden monitors agents; doctor monitors the warden. It DERIVES expected
# wiring (cron entries, heartbeats, gateway, patches, deps, state hygiene) and
# diffs against reality, instead of trusting that an installer once ran.
# Born from a real incident: the core scan loop was silently unwired for 19
# days (2026-05-22 → 2026-06-10) and nothing noticed.
#
# Usage:
#   doctor.sh             human-readable report, exit 0 healthy / 1 unhealthy
#   doctor.sh --alert     additionally send a Telegram alert on failure
#                         (throttled to one per WARDEN_DOCTOR_ALERT_COOLDOWN_SECONDS)
#
# Dead-man's switch: on a fully healthy run, pings WARDEN_HEARTBEAT_URL if set
# (e.g. a healthchecks.io check). If this host dies or doctor itself gets
# unwired, the pings stop and the external service alerts — covering the one
# failure doctor can't self-report.
#
# Run via cron: */5 * * * * /path/to/session-warden/bin/doctor.sh --alert

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
export WARDEN_HOME

[ -f "${WARDEN_HOME}/config/thresholds.env" ] && source "${WARDEN_HOME}/config/thresholds.env"
source "${WARDEN_HOME}/lib/notify.sh"

LOG_FILE="${WARDEN_LOG_FILE:-${WARDEN_HOME}/state/scan.log}"
STATE_DIR="${WARDEN_HOME}/state"

MAX_SCAN_AGE="${WARDEN_DOCTOR_MAX_SCAN_AGE:-240}"        # scan runs every 30s; 4 min = 8 missed ticks
MAX_REAP_AGE="${WARDEN_DOCTOR_MAX_REAP_AGE:-240}"
LOG_WARN_BYTES="${WARDEN_DOCTOR_LOG_WARN_BYTES:-52428800}" # 50MB
ALERT_COOLDOWN="${WARDEN_DOCTOR_ALERT_COOLDOWN_SECONDS:-3600}"
CHECK_PATCHES="${WARDEN_DOCTOR_CHECK_PATCHES:-0}"
OPENCLAW_DIST="${WARDEN_OPENCLAW_DIST:-$HOME/.npm-global/lib/node_modules/openclaw/dist}"
CRONTAB_CMD="${WARDEN_CRONTAB_CMD:-crontab}"             # overridable for tests

ALERT=0
[ "${1:-}" = "--alert" ] && ALERT=1

failures=()
warnings=()
ok_count=0

ok()   { printf '  [ok]   %s\n' "$1"; ok_count=$((ok_count + 1)); }
warn() { printf '  [warn] %s\n' "$1"; warnings+=("$1"); }
fail() { printf '  [FAIL] %s\n' "$1"; failures+=("$1"); }

file_age() {
  # seconds since mtime, or empty if missing
  local f="$1"
  [ -f "$f" ] || { echo ""; return; }
  echo $(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0) ))
}

echo "session-warden doctor — $(date -Iseconds)"
echo ""

# ─── 1. Dependencies ──────────────────────────────────────
echo "dependencies:"
for cmd in jq curl flock; do
  if command -v "$cmd" >/dev/null 2>&1; then ok "$cmd"; else fail "$cmd missing"; fi
done
for cmd in claude openclaw; do
  if command -v "$cmd" >/dev/null 2>&1; then ok "$cmd"; else warn "$cmd not in PATH (summaries/recovery degraded)"; fi
done

# ─── 2. Config ────────────────────────────────────────────
echo "config:"
if [ -f "${WARDEN_HOME}/config/thresholds.env" ]; then
  ok "thresholds.env present"
else
  fail "config/thresholds.env missing — run install.sh"
fi

# ─── 3. Scheduler wiring ─────────────────────────────────
echo "scheduler:"
cron_content=$($CRONTAB_CMD -l 2>/dev/null || true)
for unit in scan reap-stalls; do
  count=$(echo "$cron_content" | grep -cE "bin/${unit}\.sh" || true)
  if [ "$count" -ge 2 ]; then
    ok "${unit}.sh wired in cron (${count} entries, 30s cadence)"
  elif [ "$count" -eq 1 ]; then
    warn "${unit}.sh has only 1 cron entry (expected 2 for 30s cadence)"
  else
    fail "${unit}.sh NOT in crontab — core loop dead. Re-run install.sh"
  fi
done
doctor_count=$(echo "$cron_content" | grep -cE "bin/doctor\.sh" || true)
if [ "$doctor_count" -ge 1 ]; then
  ok "doctor.sh wired in cron"
else
  warn "doctor.sh not in crontab — self-checks only run manually"
fi

# ─── 4. Loop liveness (heartbeats, not log mtime) ─────────
echo "liveness:"
scan_age=$(file_age "${STATE_DIR}/.last-scan-ts")
if [ -z "$scan_age" ]; then
  fail "scan heartbeat missing (${STATE_DIR}/.last-scan-ts) — scan.sh has never run"
elif [ "$scan_age" -gt "$MAX_SCAN_AGE" ]; then
  fail "scan heartbeat stale: last scan ${scan_age}s ago (max ${MAX_SCAN_AGE}s)"
else
  ok "scan loop alive (last run ${scan_age}s ago)"
fi

reap_age=$(file_age "${STATE_DIR}/.last-reap-ts")
if [ -z "$reap_age" ]; then
  fail "reaper heartbeat missing (${STATE_DIR}/.last-reap-ts) — reap-stalls.sh has never run"
elif [ "$reap_age" -gt "$MAX_REAP_AGE" ]; then
  fail "reaper heartbeat stale: last run ${reap_age}s ago (max ${MAX_REAP_AGE}s)"
else
  ok "reaper alive (last run ${reap_age}s ago)"
fi

# ─── 5. Gateway ───────────────────────────────────────────
if [ "${WARDEN_DOCTOR_SKIP_GATEWAY:-0}" != "1" ]; then
  echo "gateway:"
  if systemctl --user is-active openclaw-gateway.service >/dev/null 2>&1; then
    ok "openclaw-gateway.service (user) active"
  elif pgrep -f 'openclaw.*gateway|openclaw-gateway' >/dev/null 2>&1; then
    warn "gateway process found but not under user systemd"
  else
    fail "no gateway running (openclaw-gateway.service inactive, no process)"
  fi
  # Split-brain guard: a second, system-level unit fighting the user one.
  # (A stale system unit crash-looped 278k times here before being caught.)
  if systemctl is-enabled openclaw.service >/dev/null 2>&1; then
    fail "system-level openclaw.service is enabled — duplicate of the user unit, disable it"
  else
    ok "no duplicate system-level unit"
  fi
fi

# ─── 5b. Channel parity (enabled channels must have plugins) ──
# Catches the silent-channel failure mode: openclaw 2026.6.5 unbundled the
# Discord plugin; the gateway booted "healthy" with channels.discord enabled
# in config but no provider loaded, and nothing alerted for 14 hours.
PARITY_SH="${WARDEN_PARITY_SH:-${WARDEN_HOME}/contrib/openclaw-patches/channel-parity.sh}"
if [ "${WARDEN_DOCTOR_SKIP_GATEWAY:-0}" != "1" ] && [ -x "$PARITY_SH" ]; then
  echo "channel parity:"
  parity_out=$(bash "$PARITY_SH" check 2>&1)
  if [ $? -eq 0 ]; then
    ok "every enabled channel has an enabled plugin"
  else
    fail "channel/plugin mismatch — $(echo "$parity_out" | grep -o "channel '[a-z]*' is enabled in config but NO enabled plugin" | tr '\n' '; ')run channel-parity.sh heal"
  fi
fi

# ─── 6. Dist patches (opt-in: contrib patches are host-specific) ──
if [ "$CHECK_PATCHES" = "1" ] && [ -d "$OPENCLAW_DIST" ]; then
  echo "patches:"
  dist_js=$(find "$OPENCLAW_DIST" -maxdepth 1 -name '*.js' 2>/dev/null)
  check_marker() {
    local label="$1"; shift
    local found=0 m
    for m in "$@"; do
      if grep -lq "$m" $dist_js 2>/dev/null; then found=1; break; fi
    done
    if [ "$found" -eq 1 ]; then
      ok "$label patch present"
    else
      fail "$label patch MISSING from dist — run contrib/openclaw-patches/ensure-patches.sh"
    fi
  }
  check_marker "output-limits"   "__WARDEN_OUTPUT_LIMITS__"
  check_marker "watchdog-stall-cap" "__OC_HARD_TURN_CAP_MS"
  check_marker "error-humanizer" "__WARDEN_ERROR_HUMANIZER__" "__OPENCLAW_ERROR_HUMANIZER_PATCHED__"
fi

# ─── 7. State hygiene ────────────────────────────────────
echo "state:"
if [ -f "$LOG_FILE" ]; then
  log_bytes=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$log_bytes" -gt "$LOG_WARN_BYTES" ]; then
    warn "scan.log is $((log_bytes / 1048576))MB — rotation overdue (cleanup-archives handles this daily)"
  else
    ok "scan.log size OK ($((log_bytes / 1048576))MB)"
  fi
fi
stale_summaries=$(find "${STATE_DIR}/pending-summaries" -name '*.json' -mmin +60 2>/dev/null | wc -l)
if [ "$stale_summaries" -gt 0 ]; then
  warn "${stale_summaries} pending summaries older than 1h — summarize.sh may be failing"
else
  ok "no stale pending summaries"
fi
disk_avail_kb=$(df -Pk "$WARDEN_HOME" 2>/dev/null | awk 'NR==2 {print $4}')
if [ -n "$disk_avail_kb" ] && [ "$disk_avail_kb" -lt 2097152 ]; then
  fail "less than 2GB disk free ($((disk_avail_kb / 1024))MB)"
else
  ok "disk space OK"
fi

# ─── Verdict ─────────────────────────────────────────────
echo ""
if [ "${#failures[@]}" -eq 0 ]; then
  echo "HEALTHY: ${ok_count} checks passed, ${#warnings[@]} warnings"
  # Dead-man's switch: only ping when fully healthy, so a silent warden
  # means silent pings means an external alert.
  if [ -n "${WARDEN_HEARTBEAT_URL:-}" ]; then
    curl -fsS -m 10 --retry 2 -o /dev/null "$WARDEN_HEARTBEAT_URL" 2>/dev/null || true
  fi
  exit 0
fi

echo "UNHEALTHY: ${#failures[@]} failures, ${#warnings[@]} warnings"

if [ "$ALERT" -eq 1 ]; then
  alert_ts_file="${STATE_DIR}/.doctor-alert-ts"
  last_alert=$(cat "$alert_ts_file" 2>/dev/null || echo 0)
  now=$(date +%s)
  if [ $((now - last_alert)) -ge "$ALERT_COOLDOWN" ]; then
    details=$(printf '%s\n' "${failures[@]}")
    notify_doctor "${#failures[@]} failures on $(hostname -s 2>/dev/null || echo host)" "$details"
    echo "$now" > "$alert_ts_file"
  fi
fi

exit 1
