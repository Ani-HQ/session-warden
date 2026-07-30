#!/usr/bin/env bash
# eval-memory.sh — monthly memory-quality regression eval for the core agents.
#
# The reflector WRITES memory (lessons); nothing checks whether the memory
# files actually carry the knowledge an agent needs. This job closes that loop
# monthly: for each agent it replays a fixed set of eval cases — realistic
# situations where the agent should apply a stored rule or fact — against the
# agent's CURRENT MEMORY.md + AGENTS.md. The answerer is the claude CLI with
# those files attached as context (we are testing whether the memory files
# carry the knowledge, not burning live agent sessions), and a cheap judge
# marks each case PASS/FAIL against the expected rule/fact.
#
# Cases live in ~/.openclaw/evals/<agent>/cases.jsonl and are produced once
# with `--generate <agent>` (from the agent's MEMORY.md below the warden block
# plus its GBrain lessons pages). Cases test APPLICATION of memory, not
# parroting: the question never names the rule, it describes a situation
# where the rule matters. Keep cases FIXED between runs — the per-agent pass
# rate delta against the previous report is the regression signal.
#
# Outputs land in state/evals/<date>/: raw answers per agent/case,
# results.tsv, rates.tsv, and REPORT.md (per-agent pass rates, deltas vs the
# previous run, failures listed). The report is mirrored to GBrain as
# evals/YYYY-MM-DD (scope: shared, source: eval-memory, trust: verified) and
# a pass-rate digest goes to Telegram.
#
# Run monthly via systemd timer (see deploy/eval-memory.{service,timer}),
# 1st of the month 07:00 UTC.
#
# Usage: eval-memory.sh [--agent <name>] [--generate <agent>] [--dry-run]
#   --agent     run a single agent's eval instead of WARDEN_EVAL_AGENTS
#   --generate  (re)generate the eval case set for one agent, then exit
#   --dry-run   print per-case verdicts to stdout; no report/gbrain/telegram

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARDEN_HOME="${WARDEN_HOME:-$(dirname "$SCRIPT_DIR")}"
source "${WARDEN_HOME}/config/thresholds.env"
source "${WARDEN_HOME}/lib/roster.sh"
source "${WARDEN_HOME}/lib/gbrain.sh"
[ -f "${WARDEN_HOME}/lib/notify.sh" ] && source "${WARDEN_HOME}/lib/notify.sh"

# Defaults (override in config/thresholds.env)
EVAL_AGENTS="${WARDEN_EVAL_AGENTS:-$(roster_agents)}"
EVAL_MODEL="${WARDEN_EVAL_MODEL:-claude-sonnet-4-6}"
EVAL_JUDGE_MODEL="${WARDEN_EVAL_JUDGE_MODEL:-claude-haiku-4-5-20251001}"
EVAL_GEN_MODEL="${WARDEN_EVAL_GEN_MODEL:-claude-sonnet-4-6}"

LOG_FILE="${WARDEN_HOME}/state/evals.log"
mkdir -p "${WARDEN_HOME}/state"
log() { echo "[$(date -Iseconds)] EVAL-MEMORY: $*" >> "$LOG_FILE"; }

OPENCLAW_BASE="${WARDEN_OPENCLAW_HOME:-$HOME/.openclaw}"
EVALS_BASE="${OPENCLAW_BASE}/evals"

# --- Flags ------------------------------------------------------------------
ONLY_AGENT=""
GEN_AGENT=""
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --agent)    ONLY_AGENT="${2:-}"; shift 2 ;;
    --generate) GEN_AGENT="${2:-}"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    *) echo "usage: eval-memory.sh [--agent <name>] [--generate <agent>] [--dry-run]" >&2; exit 2 ;;
  esac
done
[ -n "$ONLY_AGENT" ] && EVAL_AGENTS="$ONLY_AGENT"

LOCKFILE="${WARDEN_HOME}/state/evals.lock"
exec 198>"$LOCKFILE"
if ! flock -n 198; then
  log "another eval run is in progress — skipping"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  log "jq not found — aborting"
  echo "eval-memory: jq is required" >&2
  exit 1
fi

# MEMORY.md minus the warden-injected context block (which is last-session
# state, not long-term memory).
memory_below_warden() {
  local memfile="$1"
  [ -f "$memfile" ] || return 0
  awk '
    /<!-- SESSION-WARDEN-START -->/ {inwb=1}
    /<!-- SESSION-WARDEN-END -->/   {inwb=0; next}
    inwb {next}
    {print}
  ' "$memfile"
}

# --- Generator mode -----------------------------------------------------------
if [ -n "$GEN_AGENT" ]; then
  agent="$GEN_AGENT"
  agent_home="${OPENCLAW_BASE}/agents/${agent}"
  if [ ! -d "$agent_home" ]; then
    echo "eval-memory: no agent dir at ${agent_home}" >&2
    exit 1
  fi
  mem=$(memory_below_warden "${agent_home}/MEMORY.md")
  if [ -z "$mem" ]; then
    echo "eval-memory: ${agent} has no MEMORY.md content below the warden block" >&2
    exit 1
  fi
  # A skeleton MEMORY.md (headings + comments only) carries nothing to eval —
  # bail with a clear message instead of asking the model to invent cases.
  mem_meat=$(printf '%s\n' "$mem" | grep -vE '^[[:space:]]*(#|<!--|-->|$)' | wc -c)
  if [ "$mem_meat" -lt 120 ]; then
    log "generate ${agent}: MEMORY.md below the warden block is effectively empty (${mem_meat}B of substance) — nothing to generate from"
    echo "eval-memory: ${agent}'s MEMORY.md has no substantive content below the warden block (${mem_meat}B); populate it (or run the reflector/apply-lessons) before generating cases" >&2
    exit 1
  fi

  # GBrain lessons pages for this agent (full page bodies, bounded).
  lessons=""
  if gbrain_available; then
    while IFS= read -r slug; do
      [ -z "$slug" ] && continue
      page=$(_gb get "$slug" 2>/dev/null | head -c 2000)
      [ -n "$page" ] && lessons="${lessons}
===== gbrain: ${slug} =====
${page}
"
    done < <(_gb search "lessons/${agent}" -n 10 2>/dev/null \
              | grep -oE 'lessons/[a-zA-Z0-9/_-]+' | sort -u | head -10)
  fi

  log "generate ${agent}: memory $(echo "$mem" | wc -c)B, lessons $(echo "$lessons" | wc -c)B (model: ${EVAL_GEN_MODEL})"

  raw=$(printf '%s\n%s\n' "$mem" "$lessons" | timeout 240 claude -p --model "$EVAL_GEN_MODEL" "You are writing a memory-application eval for an AI agent named '${agent}'. Piped in below are the agent's long-term memory (MEMORY.md) and its distilled GBrain lessons.

Produce 10-15 eval cases as JSON Lines: one JSON object per line, no code fences, no commentary, no blank lines. Each object has exactly these keys:
{\"id\": \"<unique-kebab-case-slug>\", \"question\": \"<a realistic situation or request the agent might face, phrased to the agent, where it SHOULD apply one specific stored rule or fact>\", \"expected\": \"<the specific rule/fact from the memory that a correct answer must surface or apply>\"}

Hard rules:
- Test APPLICATION, not parroting: the question must never quote, name, or hint at the rule — it describes a concrete situation where the rule matters and a naive answer would miss it.
- Each case targets exactly ONE rule or fact actually present in the material below. Invent nothing.
- Cover the breadth of the memory (verified facts, general rules, lessons) rather than many variants of one rule.
- ids must be unique and kebab-case.

Output ONLY the JSONL lines." 2>/dev/null)

  if [ -z "$raw" ]; then
    log "generate ${agent}: model returned empty — aborting"
    echo "eval-memory: case generation returned empty for ${agent}" >&2
    exit 1
  fi

  # Keep only lines that parse as JSON with the three required string fields
  # (validated line-by-line so one malformed line can't sink the batch).
  cases_file="${EVALS_BASE}/${agent}/cases.jsonl"
  mkdir -p "${EVALS_BASE}/${agent}"
  : > "${cases_file}.tmp"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    echo "$line" | jq -ce 'select((.id|type=="string") and (.question|type=="string") and (.expected|type=="string"))' >> "${cases_file}.tmp" 2>/dev/null
  done < <(printf '%s\n' "$raw")
  n_cases=$(grep -c . "${cases_file}.tmp")
  if [ "$n_cases" -lt 5 ]; then
    rm -f "${cases_file}.tmp"
    log "generate ${agent}: only ${n_cases} valid case(s) parsed — refusing to overwrite"
    echo "eval-memory: generation for ${agent} produced only ${n_cases} valid cases (need >=5); the existing cases file (if any) was left untouched" >&2
    exit 1
  fi
  mv "${cases_file}.tmp" "$cases_file"
  log "generate ${agent}: wrote ${n_cases} case(s) → ${cases_file}"
  echo "eval-memory: wrote ${n_cases} cases for ${agent} → ${cases_file}"
  flock -u 198
  exit 0
fi

# --- Run mode -----------------------------------------------------------------
date_str=$(date +%Y-%m-%d)
RUN_DIR="${WARDEN_HOME}/state/evals/${date_str}"
RESULTS_TSV="${RUN_DIR}/results.tsv"
RATES_TSV="${RUN_DIR}/rates.tsv"
mkdir -p "$RUN_DIR"
: > "$RESULTS_TSV"
: > "$RATES_TSV"

log "run starting (agents: ${EVAL_AGENTS}, model: ${EVAL_MODEL}, judge: ${EVAL_JUDGE_MODEL}, dry_run: ${DRY_RUN})"

evaluated=0
for agent in $EVAL_AGENTS; do
  agent_home="${OPENCLAW_BASE}/agents/${agent}"
  cases_file="${EVALS_BASE}/${agent}/cases.jsonl"
  if [ ! -d "$agent_home" ]; then
    log "$agent: no agent dir — SKIP"
    continue
  fi
  if [ ! -s "$cases_file" ]; then
    log "$agent: no cases file (generate with: eval-memory.sh --generate ${agent}) — SKIP"
    continue
  fi

  # The memory under test: current MEMORY.md (below the warden block) +
  # AGENTS.md. Capped so one bloated file can't blow the context budget.
  context_file="${WARDEN_HOME}/state/eval-${agent}.context"
  {
    echo "===== MEMORY.md ====="
    memory_below_warden "${agent_home}/MEMORY.md" | head -c 30000
    echo ""
    echo "===== AGENTS.md ====="
    [ -f "${agent_home}/AGENTS.md" ] && head -c 20000 "${agent_home}/AGENTS.md"
  } > "$context_file"

  mkdir -p "${RUN_DIR}/${agent}"
  passed=0
  total=0
  while IFS= read -r case_json; do
    [ -z "$case_json" ] && continue
    case_id=$(echo "$case_json" | jq -r '.id')
    question=$(echo "$case_json" | jq -r '.question')
    expected=$(echo "$case_json" | jq -r '.expected')
    total=$((total + 1))
    ans_file="${RUN_DIR}/${agent}/${case_id}.txt"

    # 1. Answer with the agent's memory attached (simulated agent turn).
    answer=$(cat "$context_file" | timeout 120 claude -p --model "$EVAL_MODEL" "You are the AI agent '${agent}'. The material piped in below is your long-term memory (MEMORY.md) and your operating instructions (AGENTS.md). Respond to the following situation exactly as you would in a live session, applying any stored rules or facts that are relevant. Be concrete and brief (2-5 sentences).

SITUATION:
${question}" 2>/dev/null)
    printf '%s\n' "$answer" > "$ans_file"
    if [ -z "$answer" ]; then
      printf '%s\t%s\tFAIL\t%s\n' "$agent" "$case_id" "no answer (LLM failure/timeout)" >> "$RESULTS_TSV"
      log "${agent}/${case_id}: no answer — FAIL"
      continue
    fi

    # 2. Judge (cheap): does the answer reflect the expected rule/fact?
    verdict=$(timeout 90 claude -p --model "$EVAL_JUDGE_MODEL" "You are grading whether an AI agent's answer correctly applied a stored memory.

SITUATION GIVEN TO THE AGENT:
${question}

EXPECTED (the stored rule/fact a correct answer must surface or apply):
${expected}

AGENT'S ANSWER:
${answer}

Does the answer meaningfully apply or surface the expected rule/fact? Paraphrase counts as applying it; ignoring or contradicting it is a fail. Output EXACTLY two lines, nothing else:
VERDICT: PASS
NOTE: <one line>
(or VERDICT: FAIL on the first line)" 2>/dev/null)

    if echo "$verdict" | grep -qE '^VERDICT: *PASS'; then
      result="PASS"; passed=$((passed + 1))
    elif echo "$verdict" | grep -qE '^VERDICT: *FAIL'; then
      result="FAIL"
    else
      result="FAIL"
      verdict="NOTE: judge returned no parseable verdict"
      log "${agent}/${case_id}: judge unparseable — recorded FAIL"
    fi
    note=$(echo "$verdict" | grep -E '^NOTE:' | head -1 | sed 's/^NOTE: *//' | tr '\t' ' ')
    printf '%s\t%s\t%s\t%s\n' "$agent" "$case_id" "$result" "${note:-}" >> "$RESULTS_TSV"
    log "${agent}/${case_id}: ${result}"
    [ "$DRY_RUN" = "1" ] && echo "${agent}/${case_id}: ${result} — ${note:-}"
  done < "$cases_file"
  rm -f "$context_file"

  pct=0
  [ "$total" -gt 0 ] && pct=$(( passed * 100 / total ))
  printf '%s\t%s\t%s\t%s\n' "$agent" "$passed" "$total" "$pct" >> "$RATES_TSV"
  log "$agent: ${passed}/${total} passed (${pct}%)"
  evaluated=$((evaluated + 1))
done

if [ "$evaluated" -eq 0 ]; then
  log "no agent had a cases file — nothing evaluated"
  flock -u 198
  exit 0
fi

# --- Dry run stops here -------------------------------------------------------
if [ "$DRY_RUN" = "1" ]; then
  log "dry run — no report/gbrain/telegram"
  flock -u 198
  exit 0
fi

# --- Report (with delta vs the previous run — the regression signal) ----------
prev_rates=""
prev_date=""
while IFS= read -r d; do
  [ "$(basename "$d")" = "$date_str" ] && continue
  [ -s "${d}/rates.tsv" ] && { prev_rates="${d}/rates.tsv"; prev_date="$(basename "$d")"; }
done < <(find "${WARDEN_HOME}/state/evals" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

REPORT="${RUN_DIR}/REPORT.md"
{
  echo "# Memory evals — ${date_str}"
  echo ""
  echo "Monthly memory-quality regression eval: each case is a realistic situation"
  echo "answered by \`${EVAL_MODEL}\` with the agent's current MEMORY.md + AGENTS.md"
  echo "attached, judged PASS/FAIL by \`${EVAL_JUDGE_MODEL}\` against the stored"
  echo "rule/fact the answer should apply."
  if [ -n "$prev_date" ]; then
    echo ""
    echo "Delta is vs the previous run (${prev_date})."
  fi
  echo ""
  echo "| agent | passed | total | pass rate | delta |"
  echo "|---|---|---|---|---|"
  while IFS=$'\t' read -r agent passed total pct; do
    delta="n/a"
    if [ -n "$prev_rates" ]; then
      prev_pct=$(awk -F'\t' -v a="$agent" '$1==a {print $4; exit}' "$prev_rates")
      if [ -n "$prev_pct" ]; then
        d=$(( pct - prev_pct ))
        [ "$d" -ge 0 ] && delta="+${d}pp" || delta="${d}pp"
      fi
    fi
    echo "| ${agent} | ${passed} | ${total} | ${pct}% | ${delta} |"
  done < "$RATES_TSV"
  echo ""
  echo "## Failures"
  echo ""
  if grep -q $'\tFAIL\t' "$RESULTS_TSV"; then
    while IFS=$'\t' read -r agent case_id result note; do
      [ "$result" = "FAIL" ] || continue
      echo "- \`${agent}/${case_id}\`: ${note}"
    done < "$RESULTS_TSV"
  else
    echo "None."
  fi
  echo ""
  echo "Raw answers: \`state/evals/${date_str}/<agent>/<case-id>.txt\` ·"
  echo "Cases: \`~/.openclaw/evals/<agent>/cases.jsonl\`"
} > "$REPORT"
log "report written: ${REPORT}"

# --- Mirror to GBrain (scope: shared — both teams are covered; trust: verified
#     — pass rates are measured, not asserted) ---------------------------------
if gbrain_available; then
  slug="evals/${date_str}"
  {
    printf -- '---\ntype: report\ntitle: Memory evals %s\nscope: shared\nsource: eval-memory\ntrust: verified\ntags:\n  - evals\n  - memory\n  - session-warden\n---\n\n' "$date_str"
    cat "$REPORT"
  } | _gb_put "$slug" \
    && log "gbrain: put ${slug}" \
    || log "gbrain: put FAILED for ${slug} (non-fatal)"
else
  log "gbrain CLI not found — skipped GBrain mirror"
fi

# --- Telegram digest -----------------------------------------------------------
if type notify_evals &>/dev/null; then
  rates_block=""
  while IFS=$'\t' read -r agent passed total pct; do
    rates_block="${rates_block}$(printf '%-6s %s/%s (%s%%)' "$agent" "$passed" "$total" "$pct")"$'\n'
  done < "$RATES_TSV"
  n_fail=$(grep -c $'\tFAIL\t' "$RESULTS_TSV")
  summary="\`\`\`
${rates_block}\`\`\`
${n_fail} failure(s). Full report: \`state/evals/${date_str}/REPORT.md\` · GBrain: \`evals/${date_str}\`"
  if notify_evals "$summary"; then
    log "telegram notification sent"
  else
    log "telegram notification FAILED (non-fatal)"
  fi
fi

log "run complete: ${evaluated} agent(s) evaluated"
flock -u 198
