#!/usr/bin/env bash
# reap.sh — detect and kill stalled agent turns (out-of-process backstop)
#
# WHY THIS EXISTS
#   The openclaw gateway runs an in-process watchdog that kills a turn whose
#   CLI child stops making progress. That watchdog is fast and precise, but it
#   shares a failure domain with the gateway: it lives inside the compiled
#   runtime (a string patch that no-ops after `npm update openclaw`) and it
#   depends on the gateway's own event loop being healthy enough to fire. If
#   either fails, a turn can hang forever and the channel goes silent.
#
#   This library is the INDEPENDENT backstop. It reads gateway state from disk
#   and the kernel (/proc) only — never an RPC round-trip — and kills the wedged
#   CLI child directly with kill(2). For a single turn to hang silently forever,
#   the in-process watchdog AND this reaper AND kill(2) all have to fail at once.
#
# DETECTION SIGNAL (gateway-independent, reads disk + /proc only)
#   The agent CLI is a PERSISTENT "live session" process per session, fed turns
#   over stdin. So an idle session and a stuck turn BOTH show a live process
#   blocked in ep_poll — wchan alone cannot tell them apart. The only thing that
#   says "a turn is in flight" without asking the gateway is the on-disk
#   sessions.json status field: status=="running" means the gateway dispatched a
#   turn and is awaiting completion. Forward progress is the session JSONL
#   transcript's mtime: a healthy turn streams tokens / tool output and keeps
#   appending; a network-stalled turn cannot write anything.
#
#   STUCK := status=="running"
#            AND a live agent CLI process exists for the session
#            AND no forward progress (max(jsonl mtime, updatedAt)) for > hard cap
#
#   The hard cap is deliberately generous (default 15 min) and sits well ABOVE
#   the in-process watchdog, so this only ever fires when the fast layer failed.
#   No legitimate single turn is silent — zero transcript writes — for 15 min.
#
# Functions here are split into PURE (testable) and IMPURE (touch /proc, kill).

# ─── PURE: forward-progress timestamp ────────────────────
# Newest of (updatedAt, jsonl mtime), in epoch seconds. Either signal advancing
# means the turn is alive. updatedAt is ms; jsonl mtime is seconds (may be empty).
reap_last_progress_epoch() {
  local updated_at_ms="${1:-0}" jsonl_mtime="${2:-0}"
  local updated_s=$(( ${updated_at_ms:-0} / 1000 ))
  local mtime=${jsonl_mtime:-0}
  if [ "$mtime" -gt "$updated_s" ]; then
    echo "$mtime"
  else
    echo "$updated_s"
  fi
}

# ─── PURE: stall verdict ─────────────────────────────────
# Echoes "STUCK" when the gateway still believes a turn is running but it has
# made no progress past the hard cap. Echoes "" otherwise.
#
# NOTE: process liveness is deliberately NOT part of the verdict. status=="running"
# (not the presence of a process) is what says "a turn is in flight" — a live
# process exists for idle sessions too, and conversely a stuck turn whose child
# we can't find is STILL stuck. Folding proc-liveness in here would silently
# skip exactly the case we exist to catch. Liveness instead decides the ACTION
# (kill a live child / clear stale bookkeeping / escalate), in the orchestrator.
#   args: <status> <now_epoch> <last_progress_epoch> <hard_cap_secs>
reap_stall_verdict() {
  local status="$1" now="$2" last_progress="$3" cap="$4"
  [ "$status" = "running" ] || { echo ""; return 0; }
  local idle=$(( now - last_progress ))
  if [ "$idle" -gt "$cap" ]; then
    echo "STUCK"
  else
    echo ""
  fi
}

# ─── PURE: contract self-check ───────────────────────────
# The reaper reads openclaw's on-disk sessions.json schema. If a future openclaw
# upgrade reshapes that file, reap_list_running would silently return nothing and
# the reaper would no-op — reintroducing the exact silent-hang failure mode we
# exist to kill. This check makes drift LOUD instead. Echoes "DRIFT" when a
# sessions.json is present and non-empty but exposes NONE of the keys we depend
# on (status / cliSessionIds / updatedAt), or is unparseable. Empty stores are
# fine (echo ""). The orchestrator alerts (log + Telegram) on DRIFT.
reap_schema_drift() {
  local sjson="$1"
  [ -f "$sjson" ] || { echo ""; return 0; }
  jq -e . "$sjson" >/dev/null 2>&1 || { echo "DRIFT"; return 0; }
  local entries
  entries=$(jq -r 'to_entries | length' "$sjson" 2>/dev/null)
  [ "${entries:-0}" -gt 0 ] || { echo ""; return 0; }
  local recognizable
  recognizable=$(jq -r '[to_entries[].value
      | select(type == "object")
      | select(has("status") or has("cliSessionIds") or has("updatedAt"))]
      | length' "$sjson" 2>/dev/null)
  if [ "${recognizable:-0}" -gt 0 ]; then echo ""; else echo "DRIFT"; fi
}

# ─── PURE: list running candidates from a sessions.json ──
# Output: channel_key|cli_session_id|updatedAt_ms  (one per running session that
# has a claude-cli session id). These are the only sessions worth probing.
reap_list_running() {
  local sjson="$1"
  [ -f "$sjson" ] || return 0
  jq -r '
    to_entries[] |
    select(.value.status == "running") |
    select(.value.cliSessionIds["claude-cli"] // "" | length > 0) |
    "\(.key)|\(.value.cliSessionIds["claude-cli"])|\(.value.updatedAt // 0)"
  ' "$sjson" 2>/dev/null
}

# ─── IMPURE: locate the agent CLI pid for a session ──────
# Safety-gated so we NEVER kill a stray or interactive `claude` (e.g. a human's
# Claude Code session, which has no OPENCLAW_MCP_* env). A pid qualifies only if
# BOTH hold:
#   1. its cmdline contains the cli session id (`--session-id <id>`), and
#   2. its /proc environ has OPENCLAW_MCP_AGENT_ID == this agent.
# Echoes the pid, or nothing. WARDEN_PROC (default /proc) is overridable for tests.
reap_find_agent_pid() {
  local cli_session_id="$1" agent="$2"
  local procfs="${WARDEN_PROC:-/proc}"
  [ -n "$cli_session_id" ] || return 0
  local pid
  for pid in $(pgrep -f -- "--session-id ${cli_session_id}" 2>/dev/null); do
    local envfile="${procfs}/${pid}/environ"
    [ -r "$envfile" ] || continue
    local env_agent
    env_agent=$(tr '\0' '\n' < "$envfile" 2>/dev/null | sed -n 's/^OPENCLAW_MCP_AGENT_ID=//p' | head -1)
    if [ -n "$env_agent" ] && [ "$env_agent" = "$agent" ]; then
      echo "$pid"
      return 0
    fi
  done
  return 0
}

# ─── IMPURE: read a process wchan (diagnostic only) ──────
reap_proc_wchan() {
  local pid="$1" procfs="${WARDEN_PROC:-/proc}"
  cat "${procfs}/${pid}/wchan" 2>/dev/null || echo "?"
}

# ─── IMPURE: kill a wedged CLI child, TERM then KILL ─────
# Returns 0 if the process is gone afterwards, 1 if it survived (escalate).
# Honors WARDEN_DRY_RUN (logs intent, kills nothing).
reap_kill_pid() {
  local pid="$1" grace="${2:-10}"
  [ -n "$pid" ] || return 1
  if [ "${WARDEN_DRY_RUN:-0}" = "1" ]; then
    echo "[dry-run] would SIGTERM->SIGKILL pid $pid"
    return 0
  fi
  kill -TERM "$pid" 2>/dev/null
  local waited=0
  while [ "$waited" -lt "$grace" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1
    waited=$(( waited + 1 ))
  done
  # Still alive after grace — escalate to SIGKILL.
  kill -KILL "$pid" 2>/dev/null
  sleep 1
  kill -0 "$pid" 2>/dev/null && return 1
  return 0
}
