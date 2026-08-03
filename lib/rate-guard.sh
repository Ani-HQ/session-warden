#!/usr/bin/env bash
# lib/rate-guard.sh — sourced helpers for doctor / status surfaces.
# Heavy lifting lives in lib/rate-guard.py; this file exposes shell checks.

rate_guard_state_file() {
  echo "${WARDEN_HOME}/state/rate-guard/state.json"
}

rate_guard_active_provider() {
  local f
  f="$(rate_guard_state_file)"
  [ -f "$f" ] || { echo ""; return 0; }
  jq -r '.active.provider // empty' "$f" 2>/dev/null || true
}

rate_guard_is_demoted() {
  local f
  f="$(rate_guard_state_file)"
  [ -f "$f" ] || return 1
  [ "$(jq -r '.active.demoted // false' "$f" 2>/dev/null)" = "true" ]
}

# Sets RATE_GUARD_DOCTOR_LEVEL (ok|info|warn) and RATE_GUARD_DOCTOR_NOTE.
# Call without command substitution so the level is visible to the caller.
rate_guard_doctor_note() {
  RATE_GUARD_DOCTOR_LEVEL=ok
  RATE_GUARD_DOCTOR_NOTE=""
  local f provider resets detail grace now overdue label
  f="$(rate_guard_state_file)"
  [ -f "$f" ] || return 0
  [ "$(jq -r '.active.demoted // false' "$f")" = "true" ] || return 0

  provider="$(jq -r '.active.provider // "unknown"' "$f")"
  resets="$(jq -r '.active.resetsAt // empty' "$f")"
  detail="$(jq -r '.active.detail // ""' "$f")"
  grace="${WARDEN_RATE_GUARD_RESTORE_GRACE_SEC:-120}"
  now="$(date +%s)"

  RATE_GUARD_DOCTOR_LEVEL=info
  if [ -n "$resets" ]; then
    overdue="$(python3 -c "print(1 if float('$resets') + $grace < $now else 0)" 2>/dev/null || echo 0)"
    label="$(python3 -c "from datetime import datetime,timezone; print(datetime.fromtimestamp(float('$resets'), tz=timezone.utc).strftime('%Y-%m-%d %H:%MZ'))" 2>/dev/null || echo "$resets")"
    if [ "$overdue" = "1" ]; then
      RATE_GUARD_DOCTOR_LEVEL=warn
      RATE_GUARD_DOCTOR_NOTE="rate-guard: ${provider} still demoted past reset window (reset=${label}) — restore may be stuck"
      return 0
    fi
    RATE_GUARD_DOCTOR_NOTE="rate-guard: ${provider} demoted until ${label}${detail:+ · $detail}"
  else
    RATE_GUARD_DOCTOR_NOTE="rate-guard: ${provider} demoted (no resets_at yet)${detail:+ · $detail}"
  fi
}
