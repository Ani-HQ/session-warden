#!/usr/bin/env bash
# fleet-review.sh — weekly REAL-WORK quality review of the production fleet.
#
# The model scorecard (bin/scorecard.sh) benchmarks the experimental Hermes
# agents on synthetic tasks. That tells you nothing about how the agents doing
# actual revenue work — every agent in config/fleet-roster.tsv, grouped by the
# team column — are performing on their REAL
# jobs. This job closes that gap: for each production agent it harvests the
# work it actually did over the past week (from its session transcripts),
# then a judge scores that real output against a role-aware quality bar and
# writes a 0-100 score + a one-line insight + one recommended action.
#
# Dormant agents (no sessions in the window) are recorded as idle, not scored
# or penalised. An agent that correctly does nothing (e.g. a chief-of-staff agent returning
# NO_REPLY on marketing mail) is good filtering — the harvester collapses those
# runs so the judge sees the substantive work, and the judge is told as much.
#
# Outputs land in state/fleet-review/<date>/:
#   review.json  — machine-readable, consumed by the health dashboard
#   REPORT.md    — human report (per-agent score, delta vs last run, insight)
#   <agent>.sample.txt — the harvested work sample, for audit
# The report is mirrored to GBrain as fleet-review/YYYY-MM-DD and a digest goes
# to Telegram. Run weekly via systemd (deploy/fleet-review.{service,timer}).
#
# Usage: fleet-review.sh [--agent <name>] [--dry-run]
#   --agent    review a single agent instead of the whole roster
#   --dry-run  print scores to stdout; no report/gbrain/telegram

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
source "${WARDEN_HOME}/config/thresholds.env"
source "${WARDEN_HOME}/lib/gbrain.sh"
[ -f "${WARDEN_HOME}/lib/notify.sh" ] && source "${WARDEN_HOME}/lib/notify.sh"

ROSTER_FILE="${WARDEN_FLEET_ROSTER:-${WARDEN_HOME}/config/fleet-roster.tsv}"
JUDGE_MODEL="${WARDEN_FLEET_JUDGE_MODEL:-claude-sonnet-4-6}"
WINDOW_DAYS="${WARDEN_FLEET_WINDOW_DAYS:-7}"
MAX_SAMPLE_CHARS="${WARDEN_FLEET_MAX_SAMPLE_CHARS:-12000}"
JUDGE_TIMEOUT="${WARDEN_FLEET_JUDGE_TIMEOUT:-150}"
OPENCLAW_BASE="${WARDEN_OPENCLAW_HOME:-$HOME/.openclaw}"
HARVESTER="${WARDEN_HOME}/lib/harvest-work.py"

LOG_FILE="${WARDEN_HOME}/state/fleet-review.log"
mkdir -p "${WARDEN_HOME}/state"
log() { echo "[$(date -Iseconds)] FLEET-REVIEW: $*" >> "$LOG_FILE"; }

ONLY_AGENT=""
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --agent)   ONLY_AGENT="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "usage: fleet-review.sh [--agent <name>] [--dry-run]" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "fleet-review: jq required" >&2; exit 1; }
[ -f "$ROSTER_FILE" ] || { echo "fleet-review: roster not found at $ROSTER_FILE" >&2; exit 1; }
[ -f "$HARVESTER" ]   || { echo "fleet-review: harvester not found at $HARVESTER" >&2; exit 1; }

LOCKFILE="${WARDEN_HOME}/state/fleet-review.lock"
exec 197>"$LOCKFILE"
flock -n 197 || { log "another fleet-review run is in progress — skipping"; exit 0; }

# Resolve an agent's live model from openclaw.json, prettified (opus-4.8 etc.).
resolve_model() {
  python3 - "$1" "${OPENCLAW_BASE}/openclaw.json" <<'PY'
import json, sys, re, os
agent, path = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
except Exception:
    print("?"); sys.exit()
lst = d.get("agents", {}).get("list", [])
dflt = d.get("agents", {}).get("defaults", {}).get("model", {})
dflt = dflt.get("primary") if isinstance(dflt, dict) else dflt
found = None
for a in lst:
    if not isinstance(a, dict):
        continue
    name = (a.get("name") or a.get("id") or "").lower()
    if name.split()[0:1] == [agent.lower()] or name.startswith(agent.lower()):
        m = a.get("model", dflt)
        found = m.get("primary") if isinstance(m, dict) else m
        break
m = (found or dflt or "?").split("/")[-1].replace("claude-", "")
m = re.sub(r"-(\d)-(\d)\b", lambda x: f"-{x.group(1)}.{x.group(2)}", m)
m = re.sub(r"-\d{8}$", "", m)
print(m)
PY
}

date_str=$(date +%Y-%m-%d)
RUN_DIR="${WARDEN_HOME}/state/fleet-review/${date_str}"
mkdir -p "$RUN_DIR"
OBJECTS_FILE="${RUN_DIR}/.objects.jsonl"   # one JSON object per agent, assembled at the end
: > "$OBJECTS_FILE"

log "run starting (roster: ${ROSTER_FILE}, judge: ${JUDGE_MODEL}, window: ${WINDOW_DAYS}d, dry_run: ${DRY_RUN})"

reviewed=0
while IFS=$'\t' read -r agent team channel role; do
  # skip comments/blank/header
  [ -z "${agent:-}" ] && continue
  case "$agent" in \#*) continue ;; esac
  [ "$agent" = "agent" ] && continue
  [ -n "$ONLY_AGENT" ] && [ "$agent" != "$ONLY_AGENT" ] && continue

  sessions_dir="${OPENCLAW_BASE}/agents/${agent}/sessions"
  model="$(resolve_model "$agent")"

  if [ ! -d "$sessions_dir" ]; then
    log "${agent}: no sessions dir — recording as idle"
    jq -n --arg a "$agent" --arg t "$team" --arg c "$channel" --arg r "$role" --arg m "$model" \
      '{agent:$a,team:$t,channel:$c,role:$r,model:$m,sessions:0,active:false,score:null,insight:"No activity in the review window.",action:"none"}' \
      >> "$OBJECTS_FILE"
    continue
  fi

  sample="$(python3 "$HARVESTER" "$sessions_dir" --days "$WINDOW_DAYS" --max-chars "$MAX_SAMPLE_CHARS" 2>/dev/null)"
  n_sessions=$(printf '%s\n' "$sample" | awk '/^#SESSIONS /{print $2; exit}')
  n_sessions="${n_sessions:-0}"
  printf '%s\n' "$sample" > "${RUN_DIR}/${agent}.sample.txt"

  if [ "$n_sessions" -eq 0 ]; then
    log "${agent}: 0 sessions in ${WINDOW_DAYS}d — idle"
    jq -n --arg a "$agent" --arg t "$team" --arg c "$channel" --arg r "$role" --arg m "$model" \
      '{agent:$a,team:$t,channel:$c,role:$r,model:$m,sessions:0,active:false,score:null,insight:"Dormant — no sessions this week.",action:"Give it a mandate or retire it."}' \
      >> "$OBJECTS_FILE"
    reviewed=$((reviewed+1))
    continue
  fi

  # Judge the real work against a role-aware quality bar.
  verdict=$(printf '%s' "$sample" | timeout "$JUDGE_TIMEOUT" claude -p --model "$JUDGE_MODEL" "You are a demanding but fair manager reviewing one of your AI teammates' ACTUAL work from the past week.

TEAMMATE: ${agent}
ROLE: ${role}
MODEL IT RUNS ON: ${model}

Below is a representative, lightly-trimmed sample of the real work this teammate produced this week (its own session outputs — the prompts it got and what it did). Runs of routine no-op turns are collapsed into a single counted line; an agent correctly deciding NOT to act (e.g. ignoring marketing email, returning NO_REPLY) is GOOD judgment, never counted against it.

Judge the QUALITY of the work for someone in this role: is it correct, useful, complete, well-communicated, and does it follow through? Reward good judgment and clear communication; penalise sloppiness, hallucinated facts, dropped balls, or vague non-answers. Grade against what a strong human in this role would expect — not perfection.

Respond with EXACTLY three lines, nothing else:
SCORE: <integer 0-100>
INSIGHT: <one plain-English sentence a non-technical founder would understand: what this agent is good or weak at, based on the sample>
ACTION: <one short concrete recommendation, or the single word none>

=== WORK SAMPLE ===
${sample}" 2>/dev/null)

  score=$(printf '%s\n' "$verdict" | grep -iE '^SCORE:' | head -1 | grep -oE '[0-9]+' | head -1)
  insight=$(printf '%s\n' "$verdict" | grep -iE '^INSIGHT:' | head -1 | sed -E 's/^INSIGHT:[[:space:]]*//I' | tr '\t' ' ')
  action=$(printf '%s\n' "$verdict" | grep -iE '^ACTION:' | head -1 | sed -E 's/^ACTION:[[:space:]]*//I' | tr '\t' ' ')

  if [ -z "$score" ]; then
    log "${agent}: judge returned no parseable score — recording unscored"
    jq -n --arg a "$agent" --arg t "$team" --arg c "$channel" --arg r "$role" --arg m "$model" --argjson s "$n_sessions" \
      '{agent:$a,team:$t,channel:$c,role:$r,model:$m,sessions:$s,active:true,score:null,insight:"Active this week; automated review could not score this run.",action:"none"}' \
      >> "$OBJECTS_FILE"
    reviewed=$((reviewed+1))
    continue
  fi
  [ "$score" -gt 100 ] 2>/dev/null && score=100

  jq -n --arg a "$agent" --arg t "$team" --arg c "$channel" --arg r "$role" --arg m "$model" \
        --argjson s "$n_sessions" --argjson sc "$score" \
        --arg ins "${insight:-Reviewed.}" --arg act "${action:-none}" \
    '{agent:$a,team:$t,channel:$c,role:$r,model:$m,sessions:$s,active:true,score:$sc,insight:$ins,action:$act}' \
    >> "$OBJECTS_FILE"
  log "${agent}: ${score}/100 (${n_sessions} sessions) — ${insight}"
  [ "$DRY_RUN" = "1" ] && printf '%-7s %3s/100  (%s sessions)  %s\n' "$agent" "$score" "$n_sessions" "${insight}"
  reviewed=$((reviewed+1))
done < "$ROSTER_FILE"

if [ "$reviewed" -eq 0 ] && [ ! -s "$OBJECTS_FILE" ]; then
  log "nothing reviewed — check roster"
  flock -u 197
  exit 0
fi

# Assemble the canonical review.json (sorted: active first, then by score desc).
REVIEW_JSON="${RUN_DIR}/review.json"
jq -s --arg date "$date_str" --arg window "$WINDOW_DAYS" --arg judge "$JUDGE_MODEL" '
  {date:$date, window_days:($window|tonumber), judge:$judge,
   agents: (sort_by([(.active|not), (-(.score // -1))]))}' \
  "$OBJECTS_FILE" > "$REVIEW_JSON"
log "review.json written: ${REVIEW_JSON}"

if [ "$DRY_RUN" = "1" ]; then
  log "dry run — no report/gbrain/telegram"
  flock -u 197
  exit 0
fi

# Delta vs the previous run (the week-over-week signal).
prev_json=""
prev_date=""
while IFS= read -r d; do
  [ "$(basename "$d")" = "$date_str" ] && continue
  [ -s "${d}/review.json" ] && { prev_json="${d}/review.json"; prev_date="$(basename "$d")"; }
done < <(find "${WARDEN_HOME}/state/fleet-review" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

# REPORT.md
REPORT="${RUN_DIR}/REPORT.md"
{
  echo "# Fleet review — ${date_str}"
  echo ""
  echo "Weekly quality review of the production fleet's REAL work over the last"
  echo "${WINDOW_DAYS} days, scored 0-100 by \`${JUDGE_MODEL}\` against each agent's role."
  [ -n "$prev_date" ] && { echo ""; echo "Delta is vs the previous run (${prev_date})."; }
  echo ""
  echo "| agent | team | model | role-fit score | Δ | sessions | insight |"
  echo "|---|---|---|---|---|---|---|"
  jq -r '.agents[] | [.agent, .team, .model, (.score|tostring), (.sessions|tostring), .insight] | @tsv' "$REVIEW_JSON" \
  | while IFS=$'\t' read -r agent team model score sessions insight; do
      delta="n/a"
      if [ -n "$prev_json" ] && [ "$score" != "null" ]; then
        prev=$(jq -r --arg a "$agent" '.agents[] | select(.agent==$a) | (.score // "null")' "$prev_json")
        if [ -n "$prev" ] && [ "$prev" != "null" ]; then
          d=$(( score - prev )); [ "$d" -ge 0 ] && delta="+${d}" || delta="${d}"
        fi
      fi
      disp_score="$score"; [ "$score" = "null" ] && { disp_score="idle"; delta="—"; }
      echo "| ${agent} | ${team} | ${model} | ${disp_score} | ${delta} | ${sessions} | ${insight} |"
    done
  echo ""
  echo "## Recommended actions"
  echo ""
  jq -r '.agents[] | select(.action != "none" and .action != "") | "- **\(.agent)**: \(.action)"' "$REVIEW_JSON"
  echo ""
  echo "Work samples: \`state/fleet-review/${date_str}/<agent>.sample.txt\`"
} > "$REPORT"
log "report written: ${REPORT}"

# GBrain mirror (scope: shared, trust: verified — scored against real output).
if gbrain_available; then
  slug="fleet-review/${date_str}"
  {
    printf -- '---\ntype: report\ntitle: Fleet review %s\nscope: shared\nsource: fleet-review\ntrust: verified\ntags:\n  - fleet-review\n  - performance\n  - session-warden\n---\n\n' "$date_str"
    cat "$REPORT"
  } | _gb_put "$slug" \
    && log "gbrain: put ${slug}" \
    || log "gbrain: put FAILED for ${slug} (non-fatal)"
else
  log "gbrain CLI not found — skipped GBrain mirror"
fi

# Telegram digest.
if type notify_fleet &>/dev/null; then
  block=$(jq -r '.agents[] | if .score==null then "\(.agent|.[0:8]) \("        "[0:(8-(.agent|length))])  idle" else "\(.agent) \("        "[0:(8-(.agent|length))]) \(.score)/100" end' "$REVIEW_JSON" 2>/dev/null)
  # simpler, robust formatting via awk
  block=$(jq -r '.agents[] | [.agent, (if .score==null then "idle" else (.score|tostring)+"/100" end)] | @tsv' "$REVIEW_JSON" \
          | awk -F'\t' '{printf "%-8s %s\n",$1,$2}')
  top=$(jq -r '[.agents[]|select(.score!=null)]|sort_by(-.score)|.[0]|"\(.agent) (\(.score))"' "$REVIEW_JSON" 2>/dev/null)
  low=$(jq -r '[.agents[]|select(.score!=null)]|sort_by(.score)|.[0]|"\(.agent) (\(.score))"' "$REVIEW_JSON" 2>/dev/null)
  summary="\`\`\`
${block}\`\`\`
Best: ${top} · Weakest: ${low}
Full report: \`state/fleet-review/${date_str}/REPORT.md\` · GBrain: \`fleet-review/${date_str}\`"
  if notify_fleet "$summary"; then
    log "telegram notification sent"
  else
    log "telegram notification FAILED (non-fatal)"
  fi
fi

rm -f "$OBJECTS_FILE"
log "run complete: ${reviewed} agent(s) reviewed"
flock -u 197
