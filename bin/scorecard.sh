#!/usr/bin/env bash
# scorecard.sh — weekly model A/B benchmark across experimental Hermes agents.
#
# When several Hermes agents run the same fleet role on different models
# (homes at ~/.hermes-<name>, listed in WARDEN_SCORECARD_AGENTS), nothing
# measures which model is actually better at
# THIS fleet's work. This job closes that loop weekly: it runs a fixed task
# set (config/scorecard-tasks.jsonl — factual reasoning, summarization,
# structured extraction, style, planning, grounded tool use, judgment, logic)
# through every agent as a real non-interactive turn, then scores each answer
# 0-10 with a blind judge (the judge is NEVER told which agent/model produced
# the answer — it grades text against the task's rubric only).
#
# Outputs land in state/scorecard/<date>/: raw answers per agent/task, a
# scores.tsv, and REPORT.md (per-category scores + totals per agent). The
# report is mirrored to GBrain as scorecards/YYYY-MM-DD (scope: personal,
# source: scorecard, trust: verified — scores are measured, not asserted) and
# a totals digest goes to Telegram.
#
# Run weekly via systemd timer (see deploy/scorecard.{service,timer}),
# Saturday 06:00 UTC.
#
# Usage: scorecard.sh [--agent <name>] [--task <id>] [--dry-run]
#   --agent    benchmark a single agent instead of WARDEN_SCORECARD_AGENTS
#   --task     run a single task id from the task set instead of all 8
#   --dry-run  print answers + judge scores to stdout; no report/gbrain/telegram

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
source "${WARDEN_HOME}/config/thresholds.env"
source "${WARDEN_HOME}/lib/gbrain.sh"
[ -f "${WARDEN_HOME}/lib/notify.sh" ] && source "${WARDEN_HOME}/lib/notify.sh"

# Defaults (override in config/thresholds.env)
SCORECARD_AGENTS="${WARDEN_SCORECARD_AGENTS:-}"
JUDGE_MODEL="${WARDEN_SCORECARD_JUDGE_MODEL:-claude-sonnet-4-6}"
TURN_TIMEOUT="${WARDEN_SCORECARD_TURN_TIMEOUT:-180}"
TASKS_FILE="${WARDEN_SCORECARD_TASKS:-${WARDEN_HOME}/config/scorecard-tasks.jsonl}"
HERMES_BIN="${WARDEN_HERMES_BIN:-$HOME/hermes-agent/venv/bin/hermes}"

LOG_FILE="${WARDEN_HOME}/state/scorecard.log"
mkdir -p "${WARDEN_HOME}/state"
log() { echo "[$(date -Iseconds)] SCORECARD: $*" >> "$LOG_FILE"; }

# --- Flags ------------------------------------------------------------------
ONLY_AGENT=""
ONLY_TASK=""
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --agent)   ONLY_AGENT="${2:-}"; shift 2 ;;
    --task)    ONLY_TASK="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "usage: scorecard.sh [--agent <name>] [--task <id>] [--dry-run]" >&2; exit 2 ;;
  esac
done
[ -n "$ONLY_AGENT" ] && SCORECARD_AGENTS="$ONLY_AGENT"

if [ -z "$SCORECARD_AGENTS" ]; then
  log "WARDEN_SCORECARD_AGENTS not set — nothing to benchmark"
  echo "scorecard: set WARDEN_SCORECARD_AGENTS to the Hermes agents to benchmark (homes at ~/.hermes-<name>)" >&2
  exit 1
fi

LOCKFILE="${WARDEN_HOME}/state/scorecard.lock"
exec 197>"$LOCKFILE"
if ! flock -n 197; then
  log "another scorecard is running — skipping"
  exit 0
fi

if [ ! -f "$TASKS_FILE" ]; then
  log "task set missing: ${TASKS_FILE} — aborting"
  echo "scorecard: task set missing: ${TASKS_FILE}" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  log "jq not found — aborting"
  echo "scorecard: jq is required" >&2
  exit 1
fi

date_str=$(date +%Y-%m-%d)
RUN_DIR="${WARDEN_HOME}/state/scorecard/${date_str}"
SCORES_TSV="${RUN_DIR}/scores.tsv"
mkdir -p "$RUN_DIR"
: > "$SCORES_TSV"

# The experimental Hermes homes and their model labels (labels are for the
# REPORT only — the judge never sees them; see judge blindness below).
# The label is read live from each agent's Hermes config (model.default).
hermes_home_for() { echo "$HOME/.hermes-$1"; }
model_for() {
  local cfg label=""
  cfg="$(hermes_home_for "$1")/config.yaml"
  if [ -f "$cfg" ]; then
    label=$(awk '/^model:/{m=1;next} m && /^  default:/{sub(/^  default:[ \t]*/,""); print; exit}' "$cfg")
    [ -n "$label" ] || label=$(awk '/^  default:/{sub(/^  default:[ \t]*/,""); print; exit}' "$cfg")
  fi
  echo "${label:-unknown}"
}

log "run starting (agents: ${SCORECARD_AGENTS}, judge: ${JUDGE_MODEL}, task: ${ONLY_TASK:-all}, dry_run: ${DRY_RUN})"

n_turns=0
n_failed=0
matched_task=0

while IFS= read -r task_json; do
  [ -z "$task_json" ] && continue
  task_id=$(echo "$task_json" | jq -r '.id')
  [ -n "$ONLY_TASK" ] && [ "$task_id" != "$ONLY_TASK" ] && continue
  matched_task=1
  category=$(echo "$task_json" | jq -r '.category')
  prompt=$(echo "$task_json" | jq -r '.prompt')
  rubric=$(echo "$task_json" | jq -r '.rubric')

  for agent in $SCORECARD_AGENTS; do
    agent_home=$(hermes_home_for "$agent")
    if [ ! -d "$agent_home" ]; then
      log "$agent: no hermes home at ${agent_home} — SKIP"
      continue
    fi
    mkdir -p "${RUN_DIR}/${agent}"
    out_file="${RUN_DIR}/${agent}/${task_id}.txt"

    # --- 1. Run the turn (real non-interactive Hermes session) -------------
    # -Q suppresses banner/spinner/tool previews; the trailing "session_id:"
    # line is Hermes bookkeeping, not model output — strip it.
    HERMES_HOME="$agent_home" timeout "$TURN_TIMEOUT" "$HERMES_BIN" chat -Q -q "$prompt" 2>/dev/null \
      | grep -v '^session_id: ' > "$out_file"
    n_turns=$((n_turns + 1))

    if [ ! -s "$out_file" ]; then
      log "${agent}/${task_id}: turn produced no output (timeout or crash) — scored 0"
      echo "(no output — turn failed or timed out after ${TURN_TIMEOUT}s)" > "$out_file"
      printf '%s\t%s\t%s\t%s\t%s\n' "$agent" "$task_id" "$category" "0" "no output (timeout/crash)" >> "$SCORES_TSV"
      n_failed=$((n_failed + 1))
      [ "$DRY_RUN" = "1" ] && { echo "=== ${agent} / ${task_id}: NO OUTPUT (score 0) ==="; echo ""; }
      continue
    fi
    answer=$(head -c 12000 "$out_file")

    # --- 2. Judge (BLIND: never reveal which agent/model answered) ---------
    verdict=$(timeout 120 claude -p --model "$JUDGE_MODEL" "You are grading an anonymous AI assistant's answer to a benchmark task. You do not know, and must not try to guess, which system produced it — grade the text against the rubric only.

TASK PROMPT:
${prompt}

RUBRIC (what a good answer contains):
${rubric}

ANSWER:
${answer}

Score the answer 0-10 (10 = fully satisfies the rubric, 0 = empty or irrelevant). Output EXACTLY two lines, nothing else:
SCORE: <integer 0-10>
JUSTIFICATION: <one line>" 2>/dev/null)

    score=$(echo "$verdict" | grep -oE '^SCORE: *[0-9]+' | head -1 | grep -oE '[0-9]+')
    just=$(echo "$verdict" | grep -E '^JUSTIFICATION:' | head -1 | sed 's/^JUSTIFICATION: *//' | tr '\t' ' ')
    if [ -z "$score" ]; then
      log "${agent}/${task_id}: judge returned no parseable score — recorded as -"
      score="-"
      just="judge failed to return a score"
    fi
    # Clamp anything weird the judge might emit.
    case "$score" in
      -) : ;;
      *) [ "$score" -gt 10 ] 2>/dev/null && score=10 ;;
    esac

    printf '%s\t%s\t%s\t%s\t%s\n' "$agent" "$task_id" "$category" "$score" "${just:-}" >> "$SCORES_TSV"
    log "${agent}/${task_id}: score ${score}/10"

    if [ "$DRY_RUN" = "1" ]; then
      echo "=== ${agent} ($(model_for "$agent")) / ${task_id} — SCORE: ${score}/10 ==="
      echo "--- answer ---"
      cat "$out_file"
      echo "--- judge ---"
      echo "${just}"
      echo ""
    fi
  done
done < "$TASKS_FILE"

if [ "$matched_task" = "0" ]; then
  log "no task matched '--task ${ONLY_TASK}' — nothing run"
  echo "scorecard: no task with id '${ONLY_TASK}' in ${TASKS_FILE}" >&2
  exit 1
fi
log "turns complete: ${n_turns} run, ${n_failed} produced no output"

# --- 3. Dry run stops here ---------------------------------------------------
if [ "$DRY_RUN" = "1" ]; then
  log "dry run — no report/gbrain/telegram"
  flock -u 197
  exit 0
fi

# --- 4. Build REPORT.md (per-category scores + totals per agent) -------------
REPORT="${RUN_DIR}/REPORT.md"
{
  echo "# Model scorecard — ${date_str}"
  echo ""
  echo "Weekly A/B benchmark across the experimental Hermes agents. Each answer"
  echo "was scored 0-10 by a blind judge (\`${JUDGE_MODEL}\`) against the task's"
  echo "rubric; the judge was never told which agent or model produced it."
  echo ""
  header="| task | category |"
  sep="|---|---|"
  for agent in $SCORECARD_AGENTS; do
    header="${header} ${agent} ($(model_for "$agent")) |"
    sep="${sep}---|"
  done
  echo "$header"
  echo "$sep"
  while IFS= read -r task_json; do
    [ -z "$task_json" ] && continue
    tid=$(echo "$task_json" | jq -r '.id')
    [ -n "$ONLY_TASK" ] && [ "$tid" != "$ONLY_TASK" ] && continue
    tcat=$(echo "$task_json" | jq -r '.category')
    row="| ${tid} | ${tcat} |"
    for agent in $SCORECARD_AGENTS; do
      s=$(awk -F'\t' -v a="$agent" -v t="$tid" '$1==a && $2==t {print $4; exit}' "$SCORES_TSV")
      row="${row} ${s:--} |"
    done
    echo "$row"
  done < "$TASKS_FILE"
  total_row="| **TOTAL** | |"
  n_tasks=0
  for agent in $SCORECARD_AGENTS; do
    tot=$(awk -F'\t' -v a="$agent" '$1==a && $4 ~ /^[0-9]+$/ {sum+=$4; n++} END {print sum+0}' "$SCORES_TSV")
    n_tasks=$(awk -F'\t' -v a="$agent" '$1==a {n++} END {print n+0}' "$SCORES_TSV")
    total_row="${total_row} **${tot}/$((n_tasks * 10))** |"
  done
  echo "$total_row"
  echo ""
  echo "## Judge notes"
  echo ""
  for agent in $SCORECARD_AGENTS; do
    echo "### ${agent} ($(model_for "$agent"))"
    echo ""
    awk -F'\t' -v a="$agent" '$1==a {printf "- `%s`: %s/10 — %s\n", $2, $4, $5}' "$SCORES_TSV"
    echo ""
  done
  echo "Raw answers: \`state/scorecard/${date_str}/<agent>/<task-id>.txt\`"
} > "$REPORT"
log "report written: ${REPORT}"

# --- 5. Mirror to GBrain (scope: personal, source: scorecard, trust: verified
#     — the scores are measured against a fixed rubric, not asserted) ---------
if gbrain_available; then
  slug="scorecards/${date_str}"
  {
    printf -- '---\ntype: report\ntitle: Model scorecard %s\nscope: personal\nsource: scorecard\ntrust: verified\ntags:\n  - scorecard\n  - benchmark\n  - session-warden\n---\n\n' "$date_str"
    cat "$REPORT"
  } | _gb_put "$slug" \
    && log "gbrain: put ${slug}" \
    || log "gbrain: put FAILED for ${slug} (non-fatal)"
else
  log "gbrain CLI not found — skipped GBrain mirror"
fi

# --- 6. Telegram digest (totals table) ----------------------------------------
if type notify_scorecard &>/dev/null; then
  totals=""
  for agent in $SCORECARD_AGENTS; do
    tot=$(awk -F'\t' -v a="$agent" '$1==a && $4 ~ /^[0-9]+$/ {sum+=$4} END {print sum+0}' "$SCORES_TSV")
    n_tasks=$(awk -F'\t' -v a="$agent" '$1==a {n++} END {print n+0}' "$SCORES_TSV")
    totals="${totals}$(printf '%-8s %s  %s/%s' "$agent" "($(model_for "$agent"))" "$tot" "$((n_tasks * 10))")"$'\n'
  done
  summary="\`\`\`
${totals}\`\`\`
Full report: \`state/scorecard/${date_str}/REPORT.md\` · GBrain: \`scorecards/${date_str}\`"
  if notify_scorecard "$summary"; then
    log "telegram notification sent"
  else
    log "telegram notification FAILED (non-fatal)"
  fi
fi

log "run complete: ${n_turns} turns, report + mirrors done"
flock -u 197
