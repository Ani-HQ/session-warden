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
source "${WARDEN_HOME}/lib/portable.sh"   # stat_mtime / stat_size
source "${WARDEN_HOME}/lib/registry.sh"   # declared_agents / agent_is_managed
source "${WARDEN_HOME}/lib/notify.sh"
source "${WARDEN_HOME}/lib/rate-guard.sh" # rate_guard_doctor_note

LOG_FILE="${WARDEN_LOG_FILE:-${WARDEN_HOME}/state/scan.log}"
STATE_DIR="${WARDEN_HOME}/state"

MAX_SCAN_AGE="${WARDEN_DOCTOR_MAX_SCAN_AGE:-240}"        # scan runs every 30s; 4 min = 8 missed ticks
MAX_REAP_AGE="${WARDEN_DOCTOR_MAX_REAP_AGE:-240}"
LOG_WARN_BYTES="${WARDEN_DOCTOR_LOG_WARN_BYTES:-52428800}" # 50MB
ALERT_COOLDOWN="${WARDEN_DOCTOR_ALERT_COOLDOWN_SECONDS:-3600}"
# How recently an undeclared agent must have run to count as still alive.
STRAY_ACTIVE_MAX_AGE="${WARDEN_STRAY_ACTIVE_MAX_AGE:-86400}"
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
  echo $(( $(date +%s) - $(stat_mtime "$f") ))
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
wtgc_count=$(echo "$cron_content" | grep -cE "bin/reap-worktrees\.sh" || true)
if [ "$wtgc_count" -ge 1 ]; then
  ok "reap-worktrees.sh wired in cron (agent worktree GC)"
else
  warn "reap-worktrees.sh not in crontab — abandoned agent worktrees won't be swept"
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
  log_bytes=$(stat_size "$LOG_FILE")
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

# ─── 7c. Undeclared agents that are still running ────────────
# A retirement done halfway is invisible: the agent loses its channel binding
# and looks gone, but its session files stay behind, so it goes on spending
# tokens with nobody watching. Four agents sat in that state for two days.
# Now that scan.sh ignores undeclared agents, this is also the check that keeps
# that gate honest — an agent dropped from openclaw.json by mistake stops being
# supervised, and the only thing standing between that and silence is this.
declared_now="$(declared_agents)"
if [ -n "$declared_now" ]; then
  echo "agent registry:"
  strays=""
  for sjson in "${WARDEN_OPENCLAW_HOME}"/agents/*/sessions/sessions.json; do
    [ -f "$sjson" ] || continue
    a=$(basename "$(dirname "$(dirname "$sjson")")")
    # Pools belong to openclaw, so their presence says nothing about a botched
    # retirement. Only an undeclared *agent* is worth waking someone over.
    agent_is_pool "$a" && continue
    agent_is_declared "$a" "$declared_now" && continue
    age=$(file_age "$sjson")
    [ -n "$age" ] || continue
    if [ "$age" -lt "$STRAY_ACTIVE_MAX_AGE" ]; then
      strays="${strays}${a} (active $((age / 3600))h ago) "
    fi
  done
  if [ -n "$strays" ]; then
    fail "agents not declared in openclaw.json but still running: ${strays}— finish retiring them (archive the workspace) or add them back to agents.list"
  else
    ok "no undeclared agents are active ($(echo $declared_now | wc -w) declared)"
  fi
fi

# ─── 7b. Agent worktree hygiene ──────────────────────────
# The GC (reap-worktrees.sh) removes landed/idle worktrees and ALERTS on stale
# dirty/unpushed ones it won't auto-delete. Surface both here so hoarding or a
# wedged GC can't silently fill the disk.
WT_ROOT="${WT_ROOT:-$HOME/.openclaw/worktrees}"
WT_COUNT_WARN="${WARDEN_DOCTOR_WT_COUNT_WARN:-20}"
WT_SIZE_WARN_MB="${WARDEN_DOCTOR_WT_SIZE_WARN_MB:-2048}"
if [ -d "$WT_ROOT" ]; then
  echo "worktrees:"
  wt_count=$(find "$WT_ROOT" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l)
  wt_mb=$(du -sm "$WT_ROOT" 2>/dev/null | awk '{print $1}'); wt_mb="${wt_mb:-0}"
  if [ "$wt_count" -gt "$WT_COUNT_WARN" ]; then
    warn "${wt_count} agent worktrees live (>${WT_COUNT_WARN}) — GC may be behind or agents aren't running 'wt done'"
  elif [ "$wt_mb" -gt "$WT_SIZE_WARN_MB" ]; then
    warn "agent worktrees using ${wt_mb}MB (>${WT_SIZE_WARN_MB}MB)"
  else
    ok "agent worktrees OK (${wt_count} live, ${wt_mb}MB)"
  fi
  alert_file="${STATE_DIR}/.worktree-alerts"
  if [ -s "$alert_file" ]; then
    n=$(grep -c . "$alert_file" 2>/dev/null || echo 0)
    warn "${n} stale worktree(s) flagged by GC (dirty/unpushed, need a human) — see ${alert_file}"
  fi
fi

# ─── 7d. Skills prompt budget ─────────────────────────────
# OpenClaw renders every live skill's name + description into every prompt,
# capped at maxSkillsPromptChars (default 18000 chars). Past the cap it
# silently drops skills from the list — the agent just stops knowing they
# exist. The weekly harvester grows this number, so warn well before the
# cliff instead of discovering it from a confused agent.
SKILLS_PROMPT_BUDGET="${WARDEN_SKILLS_PROMPT_BUDGET:-18000}"
SKILLS_MAX_COUNT="${WARDEN_SKILLS_MAX_COUNT:-150}"
oc_home="${WARDEN_OPENCLAW_HOME:-$HOME/.openclaw}"
if [ -d "$oc_home/agents" ] && command -v python3 >/dev/null 2>&1; then
  # shellcheck disable=SC2046  # word splitting intended: one argv per declared agent
  skills_tsv=$(python3 - "$oc_home" $(declared_agents) <<'PYEOF' 2>/dev/null || true
import glob, os, re, sys
root = sys.argv[1]
agents = sys.argv[2:] or [
    os.path.basename(d) for d in sorted(glob.glob(os.path.join(root, "agents", "*")))
]
for a in agents:
    total = n = 0
    for f in glob.glob(os.path.join(root, "agents", a, "skills", "*", "SKILL.md")):
        try:
            head = open(f, encoding="utf-8", errors="replace").read(4000)
        except OSError:
            continue
        m = re.search(r"^---\n(.*?)\n---", head, re.S)
        fm = m.group(1) if m else ""
        name = re.search(r"^name:\s*(.+)$", fm, re.M)
        desc = re.search(r"^description:\s*(.+)$", fm, re.M)
        total += len(name.group(1) if name else os.path.basename(os.path.dirname(f)))
        total += len(desc.group(1) if desc else "") + 24
        n += 1
    if n:
        print(f"{a}\t{n}\t{total}")
PYEOF
)
  skills_over=0
  while IFS=$'\t' read -r sa sn schars; do
    [ -n "$sa" ] || continue
    if [ "$schars" -gt "$SKILLS_PROMPT_BUDGET" ]; then
      fail "agent '$sa': skills prompt ~${schars} chars exceeds budget ${SKILLS_PROMPT_BUDGET} — openclaw is silently dropping skills (prune or raise skillsLimits.maxSkillsPromptChars)"
      skills_over=1
    elif [ "$schars" -gt $((SKILLS_PROMPT_BUDGET * 8 / 10)) ]; then
      warn "agent '$sa': skills prompt ~${schars} chars is over 80% of the ${SKILLS_PROMPT_BUDGET} budget (${sn} skills)"
      skills_over=1
    fi
    if [ "$sn" -gt "$SKILLS_MAX_COUNT" ]; then
      fail "agent '$sa': ${sn} skills exceeds maxSkillsInPrompt (${SKILLS_MAX_COUNT}) — excess skills never reach the prompt"
      skills_over=1
    fi
  done <<< "$skills_tsv"
  [ "$skills_over" -eq 0 ] && ok "skills prompt within budget for every agent"
fi

# ─── Rate guard ──────────────────────────────────────────
# Surfaces active demotions (info) and overdue restores (warn) without
# failing the doctor run — team chats stay quiet; this is the ops signal.
if [ "${WARDEN_RATE_GUARD:-1}" = "1" ]; then
  echo "rate-guard:"
  rate_guard_doctor_note
  case "${RATE_GUARD_DOCTOR_LEVEL:-ok}" in
    warn)
      warn "${RATE_GUARD_DOCTOR_NOTE:-rate-guard demotion overdue}"
      ;;
    info)
      ok "${RATE_GUARD_DOCTOR_NOTE:-rate-guard demotion active}"
      ;;
    *)
      ok "no active demotion"
      ;;
  esac
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
