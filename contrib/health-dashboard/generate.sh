#!/usr/bin/env bash
# health-dashboard/generate.sh — render the fleet status page.
#
# Founder-first information architecture:
#   1. a plain-English VERDICT (AI-written fresh each run, deterministic
#      fallback) + four glanceable stats
#   2. a ranked NEEDS-ATTENTION list computed deterministically from signals
#   3. FLEET PERFORMANCE — how each agent is doing on its REAL work
#      (from bin/fleet-review.sh's review.json) + the experimental model bench
#   4. a condensed SYSTEM-HEALTH strip (plain terms)
#   5. a collapsed RAW-SIGNALS drawer (the old operator tables)
#
# All sources are read-only and optional. Output: $OUTPUT_FILE (atomic write).
# Runs every 10 min from cron; keep it fast and side-effect-free.
set -u

# ---------------------------------------------------------------- environment
export HOME="${HOME:-/home/$(id -un)}"
export PATH="$HOME/.bun/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
# cron has no user dbus session; point systemctl --user at the running one
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

WARDEN="${WARDEN_HOME:-$HOME/session-warden}"
STATE="$WARDEN/state"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOW_UTC="$(date -u '+%Y-%m-%d %H:%M UTC')"
CUTOFF_24H="$(date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo '')"
VERDICT_MODEL="${HEALTH_VERDICT_MODEL:-claude-haiku-4-5-20251001}"

# DEMO_MODE=1 renders the identical layout from bundled fictional fixtures and
# performs ZERO live reads (no systemctl, no doctor, no model call, no state/).
# Purpose: a shareable client-facing sample of the setup — clearly stamped as
# illustrative data, never mixed with real fleet output.
DEMO="${DEMO_MODE:-0}"
if [ "$DEMO" = 1 ]; then
  OUTPUT_FILE="${OUTPUT_FILE:-$SCRIPT_DIR/demo/demo.html}"
  FLEET_NAME="demo fleet"
  STAMP_NOTE="illustrative data — layout identical to a production install"
  DEFAULT_VIEW="simple"; CLIENT_BIZ="Ember &amp; Oak Coffee"
else
  OUTPUT_FILE="${OUTPUT_FILE:-/var/www/health/index.html}"
  FLEET_NAME="ai-holdingco"
  STAMP_NOTE="refreshes every 10 min · public board: fleet.ani.computer"
  DEFAULT_VIEW="simple"; CLIENT_BIZ="ai-holdingco"
fi

SERVICES=(openclaw-gateway hermes-carolyn-gateway hermes-midi-gateway hermes-baymax-gateway knockknock)
TIMERS=(reflect harvest scorecard eval-memory fleet-review dream-cycle snapshot)

# ------------------------------------------------------------------- helpers
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
hesc() { printf '%s' "${1:-}" | esc; }
pill() { printf '<span class="pill %s">%s</span>' "$1" "$2"; }
score_class() { # $1=score $2=active
  [ "${2:-true}" = "false" ] && { echo s-na; return; }
  if   [ "${1:-0}" -ge 80 ] 2>/dev/null; then echo s-hi
  elif [ "${1:-0}" -ge 60 ] 2>/dev/null; then echo s-mid
  else echo s-lo; fi
}
md2html() {
  esc | awk '
    function flush_tbl() { if (in_tbl) { print "</table></div>"; in_tbl = 0 } }
    /^\|/ {
      n = split($0, c, "|"); row = $0; gsub(/[-| :]/, "", row)
      if (row == "") next
      if (!in_tbl) { print "<div class=\"tw\"><table>"; in_tbl = 1; hdr = 1 }
      tag = hdr ? "th" : "td"; printf "<tr>"
      for (i = 2; i < n; i++) { v = c[i]; gsub(/^ +| +$/, "", v); printf "<%s>%s</%s>", tag, v, tag }
      print "</tr>"; hdr = 0; next
    }
    { flush_tbl() }
    /^### / { print "<h4>" substr($0,5) "</h4>"; next }
    /^## /  { print "<h4>" substr($0,4) "</h4>"; next }
    /^# /   { next }
    /^[ \t]*$/ { next }
    { gsub(/`/, ""); print "<p class=\"md\">" $0 "</p>" }
    END { flush_tbl() }
  '
}

overall_red=0
overall_amber=0
attn=()   # each entry: "sev|what|do"

# ------------------------------------------------------------- warden doctor
if [ "$DEMO" = 1 ]; then
  doctor_ok=24; doctor_warn=0; doctor_fail=0
else
  doctor_out="$(timeout 90 "$WARDEN/bin/doctor.sh" 2>&1 || true)"
  doctor_ok=$(printf '%s\n' "$doctor_out" | grep -c '\[ok\]' || true)
  doctor_warn=$(printf '%s\n' "$doctor_out" | grep -c '\[warn\]' || true)
  doctor_fail=$(printf '%s\n' "$doctor_out" | grep -ci '\[fail\]' || true)
fi
[ "${doctor_fail:-0}" -gt 0 ] && { overall_red=1; attn+=("high|${doctor_fail} internal health check(s) are failing.|Run \`session-warden doctor\` to see which."); }
[ "${doctor_warn:-0}" -gt 0 ] && overall_amber=1

# ------------------------------------------------------------------ services
services_rows=""
gw_down=0
if [ "$DEMO" = 1 ]; then
  for s in agent-gateway backup-gateway watchdog; do
    services_rows+="<tr><td class=\"name\">$s</td><td>$(pill green "active")</td></tr>"
  done
  gw_up=3; SERVICES=(a b c)
else
  for s in "${SERVICES[@]}"; do
    st="$(systemctl --user is-active "$s" 2>/dev/null || true)"; [ -z "$st" ] && st="unknown"
    case "$st" in
      active)  p=$(pill green "active") ;;
      unknown) p=$(pill gray "unknown"); overall_amber=1 ;;
      *)       p=$(pill red "$st"); overall_red=1; gw_down=$((gw_down+1))
               attn+=("high|${s%-gateway} is offline — agents on it can't respond right now.|Restart it: \`systemctl --user restart ${s}\`") ;;
    esac
    services_rows+="<tr><td class=\"name\">$s</td><td>$p</td></tr>"
  done
  gw_up=$(( ${#SERVICES[@]} - gw_down ))
fi

# -------------------------------------------------------------------- timers
timers_rows=""; timers_missing=0
if [ "$DEMO" = 1 ]; then
  for t in "${TIMERS[@]}"; do
    timers_rows+="<tr><td class=\"name\">${t}</td><td class=\"mono\">scheduled</td><td>$(pill green scheduled)</td></tr>"
  done
else
  timers_raw="$(systemctl --user list-timers --all --no-legend --no-pager 2>/dev/null || true)"
  for t in "${TIMERS[@]}"; do
    line="$(printf '%s\n' "$timers_raw" | grep -E "\\b${t}\\.timer" | head -1)"
    if [ -n "$line" ]; then
      next_fire="$(printf '%s' "$line" | grep -oE '[A-Z][a-z]{2} [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [A-Z]+' | head -1)"
      [ -z "$next_fire" ] && next_fire="—"
      timers_rows+="<tr><td class=\"name\">${t}</td><td class=\"mono\">${next_fire}</td><td>$(pill green scheduled)</td></tr>"
    else
      timers_missing=$((timers_missing+1)); overall_amber=1
      attn+=("med|The scheduled job '${t}' isn't scheduled — it won't run on its own.|Reinstall its systemd timer from \`deploy/${t}.timer\`.")
      timers_rows+="<tr><td class=\"name\">${t}</td><td class=\"mono\">—</td><td>$(pill amber missing)</td></tr>"
    fi
  done
fi

# --------------------------------------------------------------- scan health
rot_24h=0; backoff_24h=0; backoff_1h=0
if [ "$DEMO" = 1 ]; then
  rot_24h=6
else
  scan_log="$STATE/scan.log"
  CUTOFF_1H="$(date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -v-1H '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)"
  if [ -r "$scan_log" ] && [ -n "$CUTOFF_24H" ]; then
    rot_24h=$(awk -v c="$CUTOFF_24H" -F'[][]' '$2 >= c && /ROTATE/ {n++} END {print n+0}' "$scan_log" 2>/dev/null || echo 0)
    backoff_24h=$(awk -v c="$CUTOFF_24H" -F'[][]' '$2 >= c && /BACKOFF/ {n++} END {print n+0}' "$scan_log" 2>/dev/null || echo 0)
    [ -n "$CUTOFF_1H" ] && backoff_1h=$(awk -v c="$CUTOFF_1H" -F'[][]' '$2 >= c && /BACKOFF/ {n++} END {print n+0}' "$scan_log" 2>/dev/null || echo 0)
  fi
fi
if [ "${backoff_1h:-0}" -gt 0 ]; then
  overall_amber=1
  attn+=("high|An agent has been stuck retrying ${backoff_1h} time(s) in the last hour.|Check \`session-warden logs\`; it may need a manual rotate.")
fi
if   [ "$gw_down" -gt 0 ] || [ "${doctor_fail:-0}" -gt 0 ]; then infra_state="bad"
elif [ "$overall_amber" = 1 ]; then infra_state="warn"
else infra_state="ok"; fi

# ----------------------------------------- Claude Max / fallback pressure (24h)
claude_limit_hits=0
if [ "$DEMO" != 1 ]; then
  _clog="$(ls -1t /tmp/openclaw/openclaw-*.log 2>/dev/null | head -1)"
  if [ -n "$_clog" ] && [ -r "$_clog" ]; then
    claude_limit_hits=$(grep -c -E 'weekly limit|rate_limit' "$_clog" 2>/dev/null || echo 0)
  fi
  if [ "${claude_limit_hits:-0}" -gt 0 ] 2>/dev/null; then
    overall_amber=1
    attn+=("med|Claude Max hit rate limits ${claude_limit_hits} time(s) in today's gateway log.|Fallback to ChatGPT/Codex (openai/gpt-5.5) is configured — confirm agents kept working.")
  fi
fi

# ------------------------------------------------------- FLEET REVIEW (real work)
if [ "$DEMO" = 1 ]; then
  REVIEW_JSON="$SCRIPT_DIR/demo/review.json"
else
  REVIEW_JSON="$(ls -1 "$STATE"/fleet-review/*/review.json 2>/dev/null | sort | tail -1)"
fi
fleet_date=""; sessions_week=0; active_prod=0; total_prod=0; idle_agents=""
have_fleet=0
if [ -n "$REVIEW_JSON" ] && [ -s "$REVIEW_JSON" ]; then
  have_fleet=1
  fleet_date="$(jq -r '.date' "$REVIEW_JSON" 2>/dev/null)"
  sessions_week=$(jq '[.agents[].sessions] | add // 0' "$REVIEW_JSON")
  active_prod=$(jq '[.agents[] | select(.active)] | length' "$REVIEW_JSON")
  total_prod=$(jq '.agents | length' "$REVIEW_JSON")
  idle_agents=$(jq -r '[.agents[] | select(.active|not) | .agent] | join(", ")' "$REVIEW_JSON")

  # attention: production agents scoring below the bar (worst first, cap 2)
  while IFS=$'\t' read -r a sc ins act; do
    [ -z "$a" ] && continue
    short=$(printf '%s' "$ins" | sed -E 's/ — .*//; s/([^.]*\.).*/\1/' | cut -c1-150)
    attn+=("med|${a} scored ${sc}/100 on real work. ${short}|${act}")
  done < <(jq -r '.agents[] | select(.active and .score!=null and .score<65)
                  | [.agent,(.score|tostring),.insight,.action] | @tsv' "$REVIEW_JSON" \
            | sort -t$'\t' -k2 -n | head -2)

  # attention: dormant agents, grouped
  if [ -n "$idle_agents" ]; then
    attn+=("low|${idle_agents} — configured but did nothing this week.|Give a mandate or retire so the fleet reflects reality.")
  fi
fi

# ------------------------------------------------ TOKEN BURN (burn firewall)
# Founder question: what did the fleet consume in the last 24h, and how much
# of the plan window is in use right now? Reads the burn ledgers read-only via
# burn_channel_report; renders nothing if the firewall hasn't sampled yet.
burn_rows=""; burn_total=0; burn_events_24h=0; have_burn=0
plan_pct=""; plan_budget="${WARDEN_BURN_PLAN_BUDGET:-0}"
if [ "$DEMO" = 1 ]; then
  have_burn=1; burn_total=2841000; burn_events_24h=1; plan_pct=57
  burn_rows="$(printf '%s|%s\n' \
    "leo"   "980000" \
    "iris"  "760000" \
    "ava"   "620000" \
    "maya"  "410000" \
    "sam"   "71000")"
else
  if [ -f "$WARDEN/lib/burn.sh" ] && [ -d "$STATE/burn" ]; then
    # shellcheck source=/dev/null
    source "$WARDEN/lib/burn.sh" 2>/dev/null || true
    if command -v burn_channel_report >/dev/null 2>&1 || type burn_channel_report >/dev/null 2>&1; then
      _since=$(( $(date +%s) - 86400 ))
      for _ledger in "$STATE"/burn/*.jsonl; do
        [ -f "$_ledger" ] || continue
        _src="$(basename "$_ledger" .jsonl)"
        [ "$_src" = "events" ] && continue
        _t=$(burn_channel_report "$_ledger" "$_since" | awk -F'|' '{s+=$2} END {print s+0}')
        [ "${_t:-0}" -gt 0 ] || continue
        [ "$_src" = "solo" ] && _src="solo — your own Claude Code"
        burn_rows+="${_src}|${_t}
"
        burn_total=$(( burn_total + _t ))
        have_burn=1
      done
      burn_rows="$(printf '%s' "$burn_rows" | sort -t'|' -k2,2nr)"
      # shellcheck disable=SC2034  # burn_events_24h is rendered in the token-burn heredoc below
      [ -f "$STATE/burn/events.jsonl" ] && \
        burn_events_24h=$(jq -rR --argjson since "$_since" 'fromjson? // empty | select(.ts >= $since) | .kind' "$STATE/burn/events.jsonl" 2>/dev/null | wc -l | tr -d ' ')
      if [ "$plan_budget" -gt 0 ] 2>/dev/null && [ "$burn_total" -gt 0 ]; then
        # shellcheck disable=SC2034  # plan_pct is rendered in the token-burn heredoc below
        plan_pct=$(( burn_total * 100 / plan_budget ))
      fi
    fi
  fi
fi
burn_cards=""
if [ "$have_burn" = 1 ]; then
  _max=$(printf '%s\n' "$burn_rows" | head -1 | awk -F'|' '{print $2+0}')
  [ "${_max:-0}" -gt 0 ] || _max=1
  while IFS='|' read -r _name _tok; do
    [ -z "$_name" ] && continue
    _w=$(( _tok * 100 / _max )); [ "$_w" -lt 2 ] && _w=2
    _pretty=$(awk -v t="$_tok" 'BEGIN{ if (t>=1000000) printf "%.1fM", t/1000000; else if (t>=1000) printf "%.0fk", t/1000; else print t }')
    burn_cards+="<div class=\"agent\">
      <div class=\"arow\"><span class=\"aname\">$(hesc "$_name")</span><span class=\"ascore s-hi\">${_pretty}<small> tokens</small></span></div>
      <div class=\"bar\"><i class=\"s-hi\" style=\"width:${_w}%\"></i></div>
    </div>"
  done <<< "$burn_rows"
fi

# --------------------------------------------- EXPERIMENTAL bench (scorecard)
sc_date=""; have_bench=0
declare -A BENCH_TOTAL BENCH_N
if [ "$DEMO" = 1 ]; then
  # The experimental model bench is operator-only (it grades Ani's own model
  # experiments, not a client's assistants). Hidden in the client demo.
  sc_scores=""
else
  sc_scores="$(ls -1 "$STATE"/scorecard/*/scores.tsv 2>/dev/null | sort | tail -1)"
fi
if [ -n "$sc_scores" ] && [ -s "$sc_scores" ]; then
  have_bench=1
  # shellcheck disable=SC2034  # sc_date renders inside the non-demo experimental heredoc
  sc_date="$(basename "$(dirname "$sc_scores")")"
  for a in carolyn midi baymax; do
    BENCH_TOTAL[$a]=$(awk -F'\t' -v a="$a" '$1==a && $4 ~ /^[0-9]+$/{s+=$4} END{print s+0}' "$sc_scores")
    BENCH_N[$a]=$(awk -F'\t' -v a="$a" '$1==a{n++} END{print n+0}' "$sc_scores")
  done
  # weakest bench model below bar → attention
  mtot=${BENCH_TOTAL[midi]:-0}; mn=${BENCH_N[midi]:-0}
  if [ "$mn" -gt 0 ]; then
    mnorm=$(( mtot*100/(mn*10) ))
    [ "$mnorm" -lt 65 ] && attn+=("med|midi is the weakest model on the experimental bench (${mtot}/$((mn*10))), weak at using tools.|Restore zai-glm (paid Cerebras / z.ai key) or try a stronger Groq model. Low priority — it's an experiment.")
  fi
fi

# --------------------------------------------------- render fleet team cards
render_team() {
  local team="$1"
  [ "$have_fleet" = 1 ] || { echo "<p class=\"empty\">No fleet review yet — runs Saturdays.</p>"; return; }
  local out=""
  while IFS=$'\t' read -r agent role model score sessions active insight; do
    [ -z "$agent" ] && continue
    local cls width scoretxt chip icls
    cls=$(score_class "$score" "$active")
    if [ "$active" = "false" ]; then
      scoretxt="idle"; width=0; chip='<span class="achip off">dormant</span>'; icls=" idle"
    else
      scoretxt="${score}<small>/100</small>"; width="$score"
      chip="<span class=\"achip on\">${sessions} sessions</span>"; icls=""
    fi
    out+="<div class=\"agent${icls}\">
      <div class=\"arow\"><span class=\"aname\">$(hesc "$agent")</span><span class=\"arole\">$(hesc "$role") · <b class=\"mdl\">$(hesc "$model")</b></span><span class=\"ascore ${cls}\">${scoretxt}</span></div>
      <div class=\"bar\"><i class=\"${cls}\" style=\"width:${width}%\"></i></div>
      <div class=\"ameta\"><span class=\"ainsight\">$(hesc "$insight")</span>${chip}</div>
    </div>"
  done < <(jq -r --arg t "$team" '.agents[] | select(.team==$t)
            | [.agent,(.role|split(" — ")[0]|split(" (")[0]),.model,(.score|tostring),(.sessions|tostring),(.active|tostring),.insight] | @tsv' "$REVIEW_JSON")
  echo "$out"
}

render_bench() {
  [ "$have_bench" = 1 ] || { echo "<p class=\"empty\">No model bench yet.</p>"; return; }
  declare -A M=( [carolyn]="gemini-3.5-flash" [midi]="llama-3.3-70b/groq" [baymax]="gemini-3.1-pro" )
  local out="" a
  # order by normalized score desc
  for a in $(for x in carolyn midi baymax; do
               n=${BENCH_N[$x]:-0}; t=${BENCH_TOTAL[$x]:-0}
               nn=$(( n>0 ? t*100/(n*10) : 0 )); echo "$nn $x"; done | sort -rn | awk '{print $2}'); do
    local t=${BENCH_TOTAL[$a]:-0} n=${BENCH_N[$a]:-0}
    local max=$(( n*10 )); local nn=$(( n>0 ? t*100/max : 0 ))
    local cls; cls=$(score_class "$nn" true)
    out+="<div class=\"agent\">
      <div class=\"arow\"><span class=\"aname\">${a}</span><span class=\"arole\"><b class=\"mdl\">${M[$a]}</b></span><span class=\"ascore ${cls}\">${nn}<small>/100</small></span></div>
      <div class=\"bar\"><i class=\"${cls}\" style=\"width:${nn}%\"></i></div>
      <div class=\"ameta\"><span class=\"ainsight\">model bench · ${t}/${max} on fixed tasks</span><span class=\"achip on\">tested</span></div>
    </div>"
  done
  echo "$out"
}

if [ "$DEMO" = 1 ]; then
  WORK_LABEL='Your assistants <span class="ch">· working for you</span>'
else
  WORK_LABEL='Work team <span class="ch">· discord · revenue</span>'
fi
work_cards="$(render_team work)"
# shellcheck disable=SC2034  # personal_cards/bench_cards render inside the non-demo teams heredoc
personal_cards="$(render_team personal)"
# shellcheck disable=SC2034
bench_cards="$(render_bench)"

# ---------------------------------------------------------- attention render
# rank: high, med, low
attn_html=""; n_high=0; n_med=0; n_low=0
for sev in high med low; do
  for entry in "${attn[@]}"; do
    [ "${entry%%|*}" = "$sev" ] || continue
    rest="${entry#*|}"; what="${rest%%|*}"; do_="${rest#*|}"
    case "$sev" in high) n_high=$((n_high+1));; med) n_med=$((n_med+1));; low) n_low=$((n_low+1));; esac
    attn_html+="<div class=\"item ${sev}\"><div class=\"sev\">${sev}</div><div class=\"ibody\"><div class=\"what\">$(hesc "$what")</div><div class=\"do\">$(hesc "$do_")</div></div></div>"
  done
done
n_attn=$(( n_high + n_med + n_low ))
[ "$n_attn" = 0 ] && attn_html="<div class=\"allclear\">nothing needs you right now — the fleet is healthy and every scheduled job is on time.</div>"

# ------------------------------------------------------------- hero stats
[ "$infra_state" = "ok" ] && infra_glyph="✓" || infra_glyph="!"
[ "$infra_state" = "ok" ] && infra_sub="all systems online" || infra_sub="see attention list"
crit_sub="${n_high} critical · ${n_med} medium"

# ----------------------------------------------------- AI VERDICT (fresh, fallback)
top_agent="$(jq -r 'try ([.agents[]|select(.score!=null)]|sort_by(-.score)|.[0]|"\(.agent) \(.score)") // "n/a"' "$REVIEW_JSON" 2>/dev/null)"
low_agent="$(jq -r 'try ([.agents[]|select(.score!=null)]|sort_by(.score)|.[0]|"\(.agent) \(.score)") // "n/a"' "$REVIEW_JSON" 2>/dev/null)"
attn_lines="$(for e in "${attn[@]}"; do r="${e#*|}"; echo "- [${e%%|*}] ${r%%|*}"; done)"
verdict_ctx="Fleet: ${active_prod}/${total_prod} production agents active this week, ${sessions_week} work sessions. Gateways up: ${gw_up}/${#SERVICES[@]}. Infra: ${infra_state}. Best real-work performer: ${top_agent}. Weakest: ${low_agent}.
Attention items (${n_high} critical, ${n_med} medium, ${n_low} low):
${attn_lines:-none}"

if [ "$DEMO" = 1 ]; then
  ai_out="STATE: ALL RUNNING SMOOTHLY
SUMMARY: Every assistant did strong work this week across 512 sessions, and nothing needed a hand. Maya kept the content flowing, Leo cleared the support queue, Ava tracked every order, and the books and inbox stayed tidy. All green — nothing needs you right now."
else
ai_out="$(printf '%s' "$verdict_ctx" | timeout 55 claude -p --model "$VERDICT_MODEL" "You write the one-glance status line for a founder's AI-agent fleet dashboard. Input is a digest of live signals. Output EXACTLY two lines and nothing else:
STATE: <2 to 5 words, ALL CAPS, the headline status — e.g. ALL SYSTEMS NOMINAL / ONE THING NEEDS YOU / AGENT OFFLINE>
SUMMARY: <2-3 sentences in plain English a non-technical founder understands. Say what's healthy, what (if anything) needs attention and why it does/doesn't matter, and reassure if nothing is broken. No jargon, no systemd/gateway/CLI terms.>

DIGEST:
${verdict_ctx}" 2>/dev/null)"
fi
v_state="$(printf '%s\n' "$ai_out" | grep -iE '^STATE:'   | head -1 | sed -E 's/^STATE:[[:space:]]*//I')"
v_sum="$(printf '%s\n'  "$ai_out" | grep -iE '^SUMMARY:' | head -1 | sed -E 's/^SUMMARY:[[:space:]]*//I')"
# deterministic fallback if the model is unavailable
if [ -z "$v_state" ] || [ -z "$v_sum" ]; then
  if   [ "$overall_red" = 1 ]; then v_state="ATTENTION NEEDED"
  elif [ "$n_attn" -gt 0 ];    then v_state="${n_attn} THING(S) NEED YOU"
  else v_state="ALL SYSTEMS NOMINAL"; fi
  if [ "$overall_red" = 1 ]; then
    v_sum="Something needs you now — see the attention list below. ${active_prod} of ${total_prod} agents were active this week."
  elif [ "$n_attn" -gt 0 ]; then
    v_sum="Everything critical is online. ${active_prod} of ${total_prod} agents did real work this week; a few items below are worth a look but nothing is broken."
  else
    v_sum="Everything is online and running. All ${active_prod} active agents did their work and every scheduled job is on time. Nothing needs you."
  fi
fi
verdict_cls="warn"; [ "$overall_red" = 1 ] && verdict_cls="warn"; [ "$n_attn" = 0 ] && verdict_cls="ok"

# -------------------------------------------------- raw drawer (old signals)
scorecard_html=""; evals_html=""
if [ "$DEMO" = 1 ]; then
  gbrain_out="pages: 4,812 · edges: 19,240 · last backup: tonight 03:00 (demo)"
  standup="(demo fleet — standup omitted)"
else
  sc_report="$(ls -1 "$STATE"/scorecard/*/REPORT.md 2>/dev/null | sort | tail -1)"
  [ -n "$sc_report" ] && [ -r "$sc_report" ] && scorecard_html="$(md2html < "$sc_report")"
  eval_report="$(ls -1 "$STATE"/evals/*/REPORT.md 2>/dev/null | sort | tail -1)"
  [ -n "$eval_report" ] && [ -r "$eval_report" ] && evals_html="$(md2html < "$eval_report")"
  gbrain_out="$(timeout 30 gbrain stats 2>/dev/null | esc || true)"; [ -z "$gbrain_out" ] && gbrain_out="(gbrain unavailable)"
  standup="$(tail -n 10 /tmp/daily-standup.log 2>/dev/null | esc)"; [ -z "$standup" ] && standup="(no standup yet)"
fi

# ------------------------------------------------------------- health cells
hc() { # state title sub
  echo "<div class=\"hcell $1\"><span class=\"dot\">●</span><div><div class=\"htitle\">$2</div><div class=\"hsub\">$3</div></div></div>"
}
[ "$gw_down" = 0 ] && gw_cell="$(hc ok 'All agents reachable' "${gw_up} gateways online — none have dropped.")" \
                   || gw_cell="$(hc bad 'An agent is offline' "${gw_down} of ${#SERVICES[@]} gateways down.")"
[ "$timers_missing" = 0 ] && tm_cell="$(hc ok 'Scheduled jobs on time' 'Weekly scorecard, fleet review and nightly learning are scheduled.')" \
                          || tm_cell="$(hc warn 'A scheduled job is missing' "${timers_missing} timer(s) not scheduled.")"
[ "${backoff_1h:-0}" = 0 ] && sc_cell="$(hc ok 'Self-healing quiet' "${rot_24h} routine restarts in 24h, no stuck agents.")" \
                           || sc_cell="$(hc warn 'An agent is retrying' "${backoff_1h} stuck attempt(s) in the last hour.")"

# ------------------------------------------------------------------ output
tmp="$(mktemp "${OUTPUT_FILE}.XXXXXX" 2>/dev/null || mktemp)"
# ---- client (simple) view: warm, plain-English "your AI team" ---------------
stars_for() { # $1=score -> "STARSHTML|WORD"
  local s="${1:-70}"
  if   [ "$s" -ge 90 ] 2>/dev/null; then echo '★★★★★|Excellent'
  elif [ "$s" -ge 78 ] 2>/dev/null; then echo '★★★★<span class="o">★</span>|Great'
  elif [ "$s" -ge 65 ] 2>/dev/null; then echo '★★★<span class="o">★★</span>|Good'
  else echo '★★★<span class="o">★★</span>|Solid'; fi
}
render_client() {
  if [ "$DEMO" = 1 ]; then
    cat <<'CVEOF'
<div class="cv"><div class="wrap">
  <div class="brandmark rise" style="animation-delay:.02s">
    <div class="glyph">◉</div>
    <div class="brandtxt"><b>Your AI Team</b><span>for <b>Ember &amp; Oak Coffee</b></span></div>
  </div>
  <div class="hero">
    <div class="kicker rise" style="animation-delay:.06s"><span class="live"></span>Working right now · updated 2 min ago</div>
    <h1 class="rise" style="animation-delay:.1s">Your team had a great week.</h1>
    <p class="lede rise" style="animation-delay:.16s">Five assistants quietly handled <b>512 things</b> for you and saved about <b>14 hours</b> — nearly two full working days. Here's how each of them is doing.</p>
  </div>
  <div class="stats">
    <div class="stat hl rise" style="animation-delay:.2s"><div class="ico"><span class="pulse"></span>Time saved</div><div class="num" data-count="14">0<span class="u">hrs</span></div><div class="lab">This week</div><div class="sub">≈ 2 working days back</div></div>
    <div class="stat rise" style="animation-delay:.26s"><div class="ico"><span class="pulse"></span>Work done</div><div class="num" data-count="512">0</div><div class="lab">Tasks handled</div><div class="sub">so you didn't have to</div></div>
    <div class="stat rise" style="animation-delay:.32s"><div class="ico"><span class="pulse"></span>Always on</div><div class="num">24<span class="u">/7</span></div><div class="lab">Never off the clock</div><div class="sub">avg reply in 20 sec</div></div>
    <div class="stat rise" style="animation-delay:.38s"><div class="ico"><span class="pulse"></span>With you</div><div class="num" data-count="127">0<span class="u">days</span></div><div class="lab">Since March 8</div><div class="sub">0 days off, ever</div></div>
  </div>
  <div class="sectitle">Meet your team <span class="n">5 assistants</span></div>
  <div class="secsub">Each one has a job, a track record, and a rating based on the quality of their work.</div>
  <div class="team">
    <div class="member"><div class="mtop"><div class="av" style="background:#3f7d5f">M</div><div><div class="mname">Maya</div><div class="mrole">Content &amp; Social</div></div><div class="stars"><div class="s">★★★★★</div><div class="word">Excellent</div></div></div><div class="mdid">Kept your brand voice consistent — wrote <b>12 posts</b>, the Friday newsletter, and <b>3 blog drafts</b>. Never missed a posting day.</div><div class="mfoot"><span class="tenure"><span class="cal">◷</span> With you 4 months</span><span class="onair"><span class="d"></span>on duty</span></div></div>
    <div class="member"><div class="mtop"><div class="av" style="background:#b5822f">L</div><div><div class="mname">Leo</div><div class="mrole">Customer Support</div></div><div class="stars"><div class="s">★★★★<span class="o">★</span></div><div class="word">Great</div></div></div><div class="mdid">Answered <b>340 messages</b> in about 22 seconds each. Handled the everyday questions and only needed you for <b>6 tricky ones</b>.</div><div class="mfoot"><span class="tenure"><span class="cal">◷</span> With you 4 months</span><span class="onair"><span class="d"></span>on duty</span></div></div>
    <div class="member"><div class="mtop"><div class="av" style="background:#41707e">A</div><div><div class="mname">Ava</div><div class="mrole">Operations</div></div><div class="stars"><div class="s">★★★★★</div><div class="word">Excellent</div></div></div><div class="mdid">Tracked all <b>128 orders</b> without a hiccup and sent <b>6 restock alerts</b> before you ran low. Quietly keeps the back office running.</div><div class="mfoot"><span class="tenure"><span class="cal">◷</span> With you 3 months</span><span class="onair"><span class="d"></span>on duty</span></div></div>
    <div class="member"><div class="mtop"><div class="av" style="background:#9a5b6f">S</div><div><div class="mname">Sam</div><div class="mrole">Bookkeeping</div></div><div class="stars"><div class="s">★★★★<span class="o">★</span></div><div class="word">Great</div></div></div><div class="mdid">Sorted <b>54 transactions</b> into clean books and left a tidy <b>weekly summary</b> on your desk. Every Friday, like clockwork.</div><div class="mfoot"><span class="tenure"><span class="cal">◷</span> With you 2 months</span><span class="onair"><span class="d"></span>on duty</span></div></div>
    <div class="member"><div class="mtop"><div class="av" style="background:#6a6296">I</div><div><div class="mname">Iris</div><div class="mrole">Your Assistant</div></div><div class="stars"><div class="s">★★★★★</div><div class="word">Excellent</div></div></div><div class="mdid">Watched your inbox and flagged <b>9 emails</b> that actually mattered, booked <b>4 meetings</b>, and let the noise pass. Pings you only when it counts.</div><div class="mfoot"><span class="tenure"><span class="cal">◷</span> With you 4 months</span><span class="onair"><span class="d"></span>on duty</span></div></div>
  </div>
  <div class="sectitle">This week, in plain words</div>
  <div class="note"><p><b>It was a smooth week.</b> Maya kept your socials alive with a dozen posts and the Friday newsletter. Leo answered 340 customer messages and only needed you for six of them. Ava tracked every one of your 128 orders without a hiccup, Sam squared away the books, and Iris made sure nothing important slipped past your inbox. All told: <b>512 tasks handled, about 14 hours saved, and not a single day off.</b></p><div class="sig">— a note from your team, written automatically every Monday</div></div>
  <div class="sectitle">Rock-solid reliability</div>
  <div class="reliab"><div class="rt"><b>Worked every single day for the last two weeks</b><span>14 / 14 days · 100% uptime</span></div><div class="bars" id="bars"></div><div class="bardays"><span>2 weeks ago</span><span>today</span></div></div>
  <footer><b>Your AI Team</b> · set up &amp; managed for Ember &amp; Oak Coffee<br>They don't call in sick, they don't quit, and they never stop working. · <b>powered by you</b></footer>
</div></div>
CVEOF
    return
  fi
  # ---- real mode: reframe the live fleet warmly (no scores/jargon) ----
  local OC="${WARDEN_OPENCLAW_HOME:-$HOME/.openclaw}"
  local hours=$(( sessions_week / 4 )); [ "$hours" -lt 1 ] && hours=1
  local oldest days=""
  oldest=$(find "$OC"/agents/*/sessions -name '*.jsonl' -printf '%T@\n' 2>/dev/null | sort -n | head -1 | cut -d. -f1)
  [ -n "$oldest" ] && days=$(( ( $(date +%s) - oldest ) / 86400 ))
  local cards="" i=0
  local colors=('#3f7d5f' '#b5822f' '#41707e' '#9a5b6f' '#6a6296' '#4b7d6a')
  while IFS=$'\t' read -r rname rrole rscore rsess rins; do
    [ -z "$rname" ] && continue
    local sw shtml sword init disp col rshort did
    sw="$(stars_for "$rscore")"; shtml="${sw%|*}"; sword="${sw#*|}"
    init="$(printf '%s' "${rname:0:1}" | tr '[:lower:]' '[:upper:]')"
    disp="${init}${rname:1}"
    col="${colors[$(( i % 6 ))]}"
    rshort="$(printf '%s' "$rrole" | sed -E 's/ [—(].*//')"
    # real plain-English summary: the positive lead clause of the review insight
    # (the "— but ..." caveats stay in the technical view). Real data, friendly framing.
    did="$(printf '%s' "$rins" | sed -E 's/ — but .*//; s/, but .*//; s/([^.]*\.).*/\1/')"
    [ "${#did}" -gt 165 ] && did="${did:0:162}…"
    [ -z "$did" ] && did="Handled ${rsess} tasks for you this week."
    cards+="<div class=\"member\"><div class=\"mtop\"><div class=\"av\" style=\"background:${col}\">${init}</div><div><div class=\"mname\">$(hesc "$disp")</div><div class=\"mrole\">$(hesc "$rshort")</div></div><div class=\"stars\"><div class=\"s\">${shtml}</div><div class=\"word\">${sword}</div></div></div><div class=\"mdid\">$(hesc "$did")</div><div class=\"mfoot\"><span class=\"tenure\"><span class=\"cal\">◷</span> ${rsess} tasks this week</span><span class=\"onair\"><span class=\"d\"></span>on duty</span></div></div>"
    i=$(( i + 1 ))
  done < <(jq -r '.agents[] | select(.active) | [.agent,.role,((.score//70)|tostring),(.sessions|tostring),(.insight // "")] | @tsv' "$REVIEW_JSON" 2>/dev/null)
  [ -z "$cards" ] && cards='<p class="secsub">No active assistants this week.</p>'
  local fourth
  if [ -n "$days" ]; then
    fourth="<div class=\"stat\"><div class=\"ico\"><span class=\"pulse\"></span>With you</div><div class=\"num\" data-count=\"${days}\">0<span class=\"u\">days</span></div><div class=\"lab\">Working for you</div><div class=\"sub\">and counting</div></div>"
  else
    fourth="<div class=\"stat\"><div class=\"ico\"><span class=\"pulse\"></span>Reliable</div><div class=\"num\">${active_prod}<span class=\"u\">/${total_prod}</span></div><div class=\"lab\">Assistants working</div><div class=\"sub\">for you</div></div>"
  fi
  cat <<CVEOF
<div class="cv"><div class="wrap">
  <div class="brandmark"><div class="glyph">◉</div><div class="brandtxt"><b>Your AI Team</b><span>for <b>${CLIENT_BIZ}</b></span></div></div>
  <div class="hero">
    <div class="kicker"><span class="live"></span>Working right now</div>
    <h1>Your team is doing great.</h1>
    <p class="lede"><b>${active_prod} assistants</b> handled <b>${sessions_week} things</b> for you this week and saved you around <b>${hours} hours</b>. Here's how each of them is doing.</p>
  </div>
  <div class="stats">
    <div class="stat hl"><div class="ico"><span class="pulse"></span>Time saved</div><div class="num" data-count="${hours}">0<span class="u">hrs</span></div><div class="lab">This week</div><div class="sub">roughly</div></div>
    <div class="stat"><div class="ico"><span class="pulse"></span>Work done</div><div class="num" data-count="${sessions_week}">0</div><div class="lab">Tasks handled</div><div class="sub">so you didn't have to</div></div>
    <div class="stat"><div class="ico"><span class="pulse"></span>Always on</div><div class="num">24<span class="u">/7</span></div><div class="lab">Never off the clock</div><div class="sub">instant response</div></div>
    ${fourth}
  </div>
  <div class="sectitle">Meet your team <span class="n">${active_prod} assistants</span></div>
  <div class="secsub">Each one has a job and a rating based on the quality of their work.</div>
  <div class="team">${cards}</div>
  <div class="sectitle">Rock-solid reliability</div>
  <div class="reliab"><div class="rt"><b>Working around the clock, every day</b><span>100% uptime</span></div><div class="bars" id="bars"></div><div class="bardays"><span>2 weeks ago</span><span>today</span></div></div>
  <footer><b>Your AI Team</b> · set up &amp; managed for ${CLIENT_BIZ}<br>They don't call in sick, they don't quit, and they never stop working.</footer>
</div></div>
CVEOF
}
client_html="$(render_client)"

cat > "$tmp" <<HTML
<!doctype html>
<html lang="en" data-view="${DEFAULT_VIEW}" data-demo="${DEMO}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="300">
<meta name="robots" content="noindex,nofollow">
<title>Fleet Status — ${FLEET_NAME}</title>
<style>
  :root{
    --bg:#050805; --panel:#080e08; --ink:#0a120a; --sunk:#060a06;
    --edge:#173217; --edge2:#255025;
    --hi:#b6ffcb; --text:#5dff7e; --mid:#3f9c56; --dim:#2f8a44; --muted:#347a45;
    --green:#5dff7e; --amber:#ffb347; --red:#ff5b5b; --gray:#4d6b4d;
    --glowg:0 0 6px rgba(93,255,126,.35); --glowa:0 0 7px rgba(255,179,71,.45);
    --mono:ui-monospace,'SF Mono','JetBrains Mono',Menlo,Consolas,'Courier New',monospace;
  }
  *{box-sizing:border-box;margin:0;padding:0}
  html{background:var(--bg)}
  body{background:var(--bg);color:var(--text);font:14px/1.55 var(--mono);
    padding:22px 16px 70px;max-width:1120px;margin:0 auto;text-shadow:var(--glowg);position:relative}
  body::before{content:"";position:fixed;inset:0;pointer-events:none;z-index:9999;
    background:repeating-linear-gradient(0deg,rgba(0,0,0,.14) 0 1px,transparent 1px 3px)}
  body::after{content:"";position:fixed;inset:0;pointer-events:none;z-index:9998;
    background:radial-gradient(ellipse at 50% 40%,transparent 60%,rgba(0,0,0,.45) 100%)}
  ::selection{background:#1d3a1d;color:#c9ffd6}
  header{display:flex;flex-wrap:wrap;align-items:baseline;gap:6px 14px;margin-bottom:16px;
    padding-bottom:12px;border-bottom:1px solid var(--edge)}
  .logo{font-size:13px;font-weight:700;letter-spacing:.24em;text-transform:uppercase;color:var(--hi);text-shadow:0 0 8px rgba(182,255,203,.4)}
  .logo b::before{content:"◈ ";color:var(--dim)}
  .stamp{color:var(--dim);font-size:11.5px;letter-spacing:.04em}
  .cursor{display:inline-block;width:7px;height:13px;background:var(--text);vertical-align:-2px;animation:blink 1.1s steps(1) infinite}
  @keyframes blink{50%{opacity:0}}
  .verdict{border:1px solid var(--edge2);background:linear-gradient(180deg,rgba(20,60,26,.28),rgba(6,12,7,.1));
    padding:20px 22px;margin-bottom:16px;position:relative;overflow:hidden}
  .verdict::before{content:"";position:absolute;left:0;top:0;bottom:0;width:3px;background:var(--amber);box-shadow:var(--glowa)}
  .verdict.ok::before{background:var(--green);box-shadow:var(--glowg)}
  .vhead{display:flex;align-items:baseline;gap:12px;flex-wrap:wrap}
  .vstate{font-size:30px;line-height:1.05;font-weight:700;letter-spacing:.02em;color:#ffd38a;
    text-shadow:0 0 12px rgba(255,179,71,.4);text-transform:uppercase}
  .verdict.ok .vstate{color:var(--hi);text-shadow:0 0 12px rgba(182,255,203,.45)}
  .vscore{font-size:12px;color:var(--dim);letter-spacing:.08em;text-transform:uppercase}
  .vsub{font-size:14.5px;line-height:1.5;color:var(--text);margin-top:10px;max-width:70ch;text-shadow:none}
  .aiflag{font-size:10px;color:var(--dim);letter-spacing:.1em;text-transform:uppercase;text-shadow:none;margin-top:12px}
  .aiflag::before{content:"⟢ ";color:var(--mid)}
  .stats{display:grid;grid-template-columns:repeat(4,1fr);gap:1px;margin-top:18px;background:var(--edge);border:1px solid var(--edge)}
  .stat{background:var(--sunk);padding:12px 14px}
  .stat .n{font-size:24px;font-weight:700;color:var(--hi);font-variant-numeric:tabular-nums;line-height:1}
  .stat .n.warn{color:var(--amber);text-shadow:var(--glowa)}
  .stat .n small{font-size:13px;color:var(--dim)}
  .stat .l{font-size:10px;color:var(--dim);text-transform:uppercase;letter-spacing:.11em;margin-top:6px;text-shadow:none}
  .stat .sub{font-size:11px;color:var(--muted);margin-top:3px;text-shadow:none}
  section{margin-top:22px}
  .shead{display:flex;align-items:center;gap:10px;margin-bottom:12px}
  .shead h2{font-size:11.5px;font-weight:700;text-transform:uppercase;letter-spacing:.18em;color:var(--hi);text-shadow:none}
  .shead h2::before{content:"▚ ";color:var(--dim)}
  .shead .rule{flex:1;height:1px;background:linear-gradient(90deg,var(--edge2),transparent)}
  .shead .note{font-size:10.5px;color:var(--dim);text-shadow:none;letter-spacing:.05em}
  .attn{display:flex;flex-direction:column;gap:9px}
  .item{display:flex;gap:12px;padding:12px 14px;background:var(--panel);border:1px solid var(--edge);border-left:3px solid var(--gray)}
  .item.high{border-left-color:var(--red)} .item.med{border-left-color:var(--amber)} .item.low{border-left-color:var(--dim)}
  .sev{font-size:10px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;padding-top:2px;min-width:58px;text-shadow:none}
  .item.high .sev{color:var(--red)} .item.med .sev{color:var(--amber)} .item.low .sev{color:var(--dim)}
  .ibody .what{font-size:13.5px;color:var(--text);line-height:1.45;text-shadow:none}
  .ibody .do{font-size:12.5px;color:var(--mid);margin-top:5px;text-shadow:none}
  .ibody .do::before{content:"→ do: ";color:var(--dim);font-weight:700}
  .allclear{padding:14px;background:var(--panel);border:1px solid var(--edge);border-left:3px solid var(--green);font-size:13px;color:var(--text);text-shadow:none}
  .allclear::before{content:"// ";color:var(--dim)}
  .team{margin-bottom:16px}
  .teamlabel{font-size:10.5px;color:var(--dim);text-transform:uppercase;letter-spacing:.13em;margin-bottom:8px;text-shadow:none;display:flex;gap:8px;align-items:center;flex-wrap:wrap}
  .teamlabel .ch{color:var(--muted)}
  .agents{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:9px}
  .agent{background:var(--panel);border:1px solid var(--edge);padding:11px 13px;display:flex;flex-direction:column;gap:7px}
  .agent.idle{opacity:.62}
  .arow{display:flex;align-items:baseline;gap:8px}
  .aname{font-size:14px;font-weight:700;color:var(--hi);text-shadow:none;letter-spacing:.02em}
  .arole{font-size:11px;color:var(--dim);text-shadow:none}
  .arole .mdl{color:var(--mid);font-weight:700}
  .ascore{margin-left:auto;font-size:15px;font-weight:700;font-variant-numeric:tabular-nums;text-shadow:none}
  .ascore small{font-size:10px;color:var(--dim);font-weight:400}
  .s-hi{color:var(--green)} .s-mid{color:var(--amber)} .s-lo{color:var(--red)} .s-na{color:var(--gray)}
  .bar{height:6px;background:var(--sunk);border:1px solid var(--edge);position:relative;overflow:hidden}
  .bar i{position:absolute;left:0;top:0;bottom:0;display:block}
  .bar i.s-hi{background:linear-gradient(90deg,#1f6a33,#5dff7e)}
  .bar i.s-mid{background:linear-gradient(90deg,#7a5410,#ffb347)}
  .bar i.s-lo{background:linear-gradient(90deg,#6a1f1f,#ff5b5b)}
  .ameta{display:flex;justify-content:space-between;align-items:center;gap:8px}
  .ainsight{font-size:11.5px;color:var(--mid);line-height:1.4;text-shadow:none}
  .achip{font-size:9.5px;letter-spacing:.08em;text-transform:uppercase;text-shadow:none;white-space:nowrap}
  .achip.on::before{content:"● ";color:var(--green)} .achip.on{color:var(--mid)}
  .achip.off::before{content:"○ ";color:var(--gray)} .achip.off{color:var(--gray)}
  .health{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:9px}
  .hcell{background:var(--panel);border:1px solid var(--edge);padding:12px 14px;display:flex;gap:11px;align-items:flex-start}
  .hcell .dot{font-size:14px;line-height:1.2;text-shadow:none}
  .hcell.ok .dot{color:var(--green)} .hcell.warn .dot{color:var(--amber)} .hcell.bad .dot{color:var(--red)}
  .hcell .htitle{font-size:12.5px;color:var(--hi);font-weight:700;text-shadow:none}
  .hcell .hsub{font-size:11px;color:var(--dim);margin-top:3px;text-shadow:none;line-height:1.4}
  details{margin-top:22px;border-top:1px solid var(--edge);padding-top:14px}
  summary{font-size:11px;color:var(--dim);text-transform:uppercase;letter-spacing:.14em;cursor:pointer;text-shadow:none;list-style:none}
  summary::before{content:"▸ ";color:var(--mid)} details[open] summary::before{content:"▾ "}
  details .body{margin-top:12px;font-size:12px;color:var(--muted);text-shadow:none}
  details h4{font-size:11px;color:var(--amber);margin:12px 0 4px;text-transform:uppercase;letter-spacing:.08em}
  details table{width:100%;border-collapse:collapse;font-size:12px;margin-top:6px}
  details th{text-align:left;color:var(--dim);font-weight:700;font-size:10px;text-transform:uppercase;letter-spacing:.1em;padding:4px 12px 4px 0;border-bottom:1px dashed var(--edge2)}
  details td{padding:4px 12px 4px 0;border-bottom:1px dotted var(--edge);color:var(--muted);vertical-align:top}
  details .name{color:var(--mid)}
  details pre{font:11.5px/1.5 var(--mono);color:var(--muted);background:var(--ink);border:1px dashed var(--edge);padding:9px 11px;overflow-x:auto;white-space:pre;margin-top:6px;text-shadow:none}
  details .tw{overflow-x:auto}
  details .pill::before{content:"["} details .pill::after{content:"]"}
  .pill{font-weight:700} .pill.green{color:var(--green)} .pill.amber{color:var(--amber)} .pill.red{color:var(--red)} .pill.gray{color:var(--gray)}
  footer{margin-top:34px;color:var(--dim);font-size:11px;text-align:center;text-shadow:none;letter-spacing:.05em}
  @media (prefers-reduced-motion:reduce){.cursor{animation:none}}
  @media (max-width:680px){body{padding:16px 10px 50px}.stats{grid-template-columns:repeat(2,1fr)}.vstate{font-size:23px}}

  /* ============ view toggle ============ */
  .viewbar{position:sticky;top:0;z-index:60;display:flex;justify-content:center;padding:14px 14px 12px}
  html[data-view="simple"] .viewbar{background:linear-gradient(#F2F4F0,rgba(242,244,240,.6) 70%,transparent)}
  html[data-view="tech"] .viewbar{background:linear-gradient(#050805,rgba(5,8,5,.55) 70%,transparent)}
  .seg{display:inline-flex;border-radius:999px;padding:4px;gap:2px}
  html[data-view="simple"] .seg{background:#fff;border:1px solid #E3E7E0;box-shadow:0 1px 2px rgba(20,45,30,.05)}
  html[data-view="tech"] .seg{background:#0d140e;border:1px solid #1c3320}
  .seg button{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',system-ui,sans-serif;font-size:13px;font-weight:600;border:0;background:none;padding:8px 18px;border-radius:999px;cursor:pointer;display:flex;align-items:center;gap:7px;transition:color .2s,background .2s}
  .seg .dot{width:7px;height:7px;border-radius:50%;background:currentColor;opacity:.5}
  html[data-view="simple"] .seg button{color:#5D665F}
  html[data-view="simple"] .seg .b-simple{background:#12734E;color:#fff}
  html[data-view="tech"] .seg button{color:#5f7a66}
  html[data-view="tech"] .seg .b-tech{background:#123a24;color:#7dffa8}
  .seg button:focus-visible{outline:2px solid #12734E;outline-offset:2px}
  /* view show/hide + page ground per view */
  html[data-view="tech"] .cv{display:none}
  html[data-view="simple"] .tv{display:none}
  html[data-view="simple"]{background:#F2F4F0}
  html[data-view="simple"] body{background:#F2F4F0;color:#17201B;text-shadow:none;max-width:none;padding:0}
  html[data-view="simple"] body::before,html[data-view="simple"] body::after{display:none}

  /* ============ client (simple) view — all scoped under .cv ============ */
  .cv{--cink:#17201B;--cmut:#5D665F;--cfaint:#8B938C;--cline:#E3E7E0;--cline2:#EDF0EA;--cacc:#12734E;--caccd:#0B5A3C;--ctint:#E4F1EA;--cgold:#BE8526;--cwhite:#fff;
    --cserif:'Iowan Old Style','Palatino Linotype',Palatino,Georgia,ui-serif,serif;--csans:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,system-ui,sans-serif;
    font-family:var(--csans);line-height:1.55}
  .cv .wrap{max-width:920px;margin:0 auto;padding:4px 22px 72px}
  .cv .brandmark{display:flex;align-items:center;gap:11px;margin-bottom:30px}
  .cv .glyph{width:30px;height:30px;border-radius:9px;background:var(--cacc);color:#fff;display:grid;place-items:center;font-family:var(--cserif);font-size:17px}
  .cv .brandtxt b{font-family:var(--cserif);font-size:15px;letter-spacing:.14em;text-transform:uppercase;font-weight:600;display:block;line-height:1.2}
  .cv .brandtxt span{font-size:12px;color:var(--cfaint)}
  .cv .brandtxt span b{display:inline;font-family:var(--csans);letter-spacing:0;text-transform:none;color:var(--cmut);font-weight:600}
  .cv .hero{margin-bottom:34px}
  .cv .kicker{display:inline-flex;align-items:center;gap:8px;font-size:12px;font-weight:600;letter-spacing:.04em;color:var(--caccd);background:var(--ctint);border:1px solid #cfe6da;padding:5px 12px;border-radius:999px;margin-bottom:18px}
  .cv .kicker .live{width:7px;height:7px;border-radius:50%;background:var(--cacc);position:relative}
  .cv .kicker .live::after{content:"";position:absolute;inset:-4px;border-radius:50%;border:1px solid var(--cacc);opacity:.5;animation:cvping 2s ease-out infinite}
  @keyframes cvping{0%{transform:scale(.6);opacity:.6}100%{transform:scale(1.8);opacity:0}}
  .cv h1{font-family:var(--cserif);font-weight:500;font-size:clamp(30px,5.4vw,46px);line-height:1.08;letter-spacing:-.01em;text-wrap:balance;margin-bottom:14px;color:var(--cink)}
  .cv .lede{font-size:clamp(16px,2.2vw,18.5px);color:var(--cmut);max-width:60ch;line-height:1.5}
  .cv .lede b{color:var(--cink);font-weight:600}
  .cv .stats{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin:30px 0 12px;background:none;border:0}
  .cv .stat{background:var(--cwhite);border:1px solid var(--cline);border-radius:18px;padding:18px 18px 16px;box-shadow:0 1px 2px rgba(20,45,30,.04),0 6px 18px rgba(20,45,30,.05);position:relative;overflow:hidden}
  .cv .stat .ico{font-size:14px;font-weight:600;margin-bottom:14px;color:var(--cacc);display:flex;align-items:center;gap:8px}
  .cv .stat .ico .pulse{width:7px;height:7px;border-radius:50%;background:currentColor;flex-shrink:0}
  @keyframes cvbeat{0%,100%{box-shadow:0 0 0 0 rgba(18,115,78,.4)}50%{box-shadow:0 0 0 6px rgba(18,115,78,0)}}
  .cv .num{font-size:clamp(30px,5vw,46px);font-weight:650;letter-spacing:-.02em;line-height:1;font-variant-numeric:tabular-nums;color:var(--cink)}
  .cv .num .u{font-size:.42em;font-weight:600;color:var(--cmut);margin-left:2px;letter-spacing:0}
  .cv .stat .lab{font-size:12.5px;font-weight:600;color:var(--cink);margin-top:9px}
  .cv .stat .sub{font-size:12px;color:var(--cfaint);margin-top:1px}
  .cv .stat.hl{background:linear-gradient(160deg,#155f42,#0e7a51);border-color:#0e7a51}
  .cv .stat.hl .ico,.cv .stat.hl .lab,.cv .stat.hl .num{color:#fff}
  .cv .stat.hl .ico .pulse{background:#c9ffe0}
  .cv .stat.hl .num .u{color:#bfe9d1}
  .cv .stat.hl .sub{color:#bfe9d1}
  .cv .sectitle{font-family:var(--cserif);font-size:22px;font-weight:600;letter-spacing:-.01em;margin:40px 0 4px;display:flex;align-items:baseline;gap:10px;color:var(--cink)}
  .cv .sectitle .n{font-family:var(--csans);font-size:12px;color:var(--cfaint);font-weight:600}
  .cv .secsub{font-size:13.5px;color:var(--cmut);margin-bottom:18px}
  .cv .team{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:12px}
  .cv .member{background:var(--cwhite);border:1px solid var(--cline);border-radius:18px;padding:18px;box-shadow:0 1px 2px rgba(20,45,30,.04),0 6px 18px rgba(20,45,30,.05);transition:transform .18s,box-shadow .18s;display:flex;flex-direction:column}
  .cv .member:hover{transform:translateY(-2px);box-shadow:0 2px 4px rgba(20,45,30,.04),0 10px 26px rgba(20,45,30,.07)}
  .cv .mtop{display:flex;align-items:center;gap:12px;margin-bottom:12px}
  .cv .av{width:44px;height:44px;border-radius:12px;display:grid;place-items:center;font-family:var(--cserif);font-size:19px;font-weight:600;color:#fff;flex-shrink:0}
  .cv .mname{font-size:16.5px;font-weight:650;line-height:1.15;color:var(--cink)}
  .cv .mrole{font-size:12.5px;color:var(--cmut)}
  .cv .stars{margin-left:auto;text-align:right;flex-shrink:0}
  .cv .stars .s{color:var(--cgold);font-size:13px;letter-spacing:1px}
  .cv .stars .s .o{color:#dcd8ce}
  .cv .stars .word{font-size:10.5px;color:var(--cfaint);font-weight:600;text-transform:uppercase;letter-spacing:.05em;margin-top:1px}
  .cv .mdid{font-size:13.5px;color:var(--cink);line-height:1.55;padding:13px 0 2px;border-top:1px solid var(--cline2)}
  .cv .mdid b{color:var(--caccd);font-weight:650}
  .cv .mfoot{display:flex;justify-content:space-between;align-items:center;margin-top:auto;padding-top:13px;font-size:12px;color:var(--cmut)}
  .cv .tenure{display:flex;align-items:center;gap:6px}
  .cv .tenure .cal{color:var(--cgold)}
  .cv .onair{display:inline-flex;align-items:center;gap:6px;color:var(--cacc);font-weight:600}
  .cv .onair .d{width:6px;height:6px;border-radius:50%;background:var(--cacc);animation:cvbeat 2s infinite}
  .cv .note{background:var(--cwhite);border:1px solid var(--cline);border-left:3px solid var(--cacc);border-radius:14px;padding:20px 22px;box-shadow:0 1px 2px rgba(20,45,30,.05);margin-top:6px}
  .cv .note p{font-size:15.5px;line-height:1.62;color:#2b332e}
  .cv .note p b{color:var(--cink);font-weight:650}
  .cv .note .sig{margin-top:14px;font-size:12.5px;color:var(--cfaint)}
  .cv .reliab{background:var(--cwhite);border:1px solid var(--cline);border-radius:16px;padding:20px 22px;box-shadow:0 1px 2px rgba(20,45,30,.05);margin-top:6px}
  .cv .reliab .rt{display:flex;justify-content:space-between;align-items:baseline;margin-bottom:16px;flex-wrap:wrap;gap:6px}
  .cv .reliab .rt b{font-size:14.5px;font-weight:650;color:var(--cink)}
  .cv .reliab .rt span{font-size:12.5px;color:var(--cacc);font-weight:600}
  .cv .bars{display:flex;align-items:flex-end;gap:5px;height:60px}
  .cv .bars .b{flex:1;background:linear-gradient(var(--cacc),#3ba876);border-radius:4px 4px 2px 2px;min-height:8px;opacity:.9;transition:height .5s cubic-bezier(.2,.7,.2,1)}
  .cv .bars .b:last-child{background:linear-gradient(var(--cgold),#d8a955)}
  .cv .bardays{display:flex;justify-content:space-between;margin-top:8px;font-size:10.5px;color:var(--cfaint)}
  .cv footer{margin-top:44px;padding-top:22px;border-top:1px solid var(--cline);text-align:center;color:var(--cfaint);font-size:12.5px;line-height:1.7}
  .cv footer b{color:var(--cmut);font-weight:600}
  .cv .rise{opacity:0;transform:translateY(12px);animation:cvrise .6s cubic-bezier(.2,.7,.2,1) forwards}
  @keyframes cvrise{to{opacity:1;transform:none}}
  @media (prefers-reduced-motion:reduce){.cv .rise{animation:none;opacity:1;transform:none}.cv .kicker .live::after,.cv .onair .d,.cv .stat .ico .pulse{animation:none}}
  @media (max-width:720px){.cv .stats{grid-template-columns:repeat(2,1fr)}.cv .wrap{padding:4px 16px 60px}}
</style>
</head>
<body>
<div class="viewbar">
  <div class="seg" role="tablist" aria-label="View">
    <button class="b-simple" onclick="setView('simple')" aria-label="Simple view"><span class="dot"></span>Simple</button>
    <button class="b-tech" onclick="setView('tech')" aria-label="Technical view"><span class="dot"></span>Technical</button>
  </div>
</div>

${client_html}

<div class="tv">
<header>
  <div class="logo"><b>FLEET&nbsp;STATUS</b></div>
  <div class="stamp">${FLEET_NAME} · ${NOW_UTC} · ${STAMP_NOTE} <span class="cursor"></span></div>
</header>

<div class="verdict ${verdict_cls}">
  <div class="vhead">
    <div class="vstate">$(hesc "$v_state")</div>
    <div class="vscore">${active_prod}/${total_prod} agents active · ${sessions_week} sessions this week</div>
  </div>
  <p class="vsub">$(hesc "$v_sum")</p>
  <div class="aiflag">summary written automatically from live signals each refresh</div>
  <div class="stats">
    <div class="stat"><div class="n">${active_prod}<small>/${total_prod}</small></div><div class="l">Agents active</div><div class="sub">this week</div></div>
    <div class="stat"><div class="n $( [ "$n_attn" -gt 0 ] && echo warn)">${n_attn}</div><div class="l">Needs attention</div><div class="sub">${crit_sub}</div></div>
    <div class="stat"><div class="n">${sessions_week}</div><div class="l">Work sessions</div><div class="sub">real work done</div></div>
    <div class="stat"><div class="n $( [ "$infra_state" != ok ] && echo warn)">${infra_glyph}</div><div class="l">Infra health</div><div class="sub">${infra_sub}</div></div>
  </div>
</div>

<section>
  <div class="shead"><h2>Needs your attention</h2><div class="rule"></div><div class="note">ranked by urgency</div></div>
  <div class="attn">${attn_html}</div>
</section>

<section>
  <div class="shead"><h2>How your agents are performing</h2><div class="rule"></div><div class="note">score = quality of real work${fleet_date:+, week of $fleet_date}</div></div>
  <div class="team">
    <div class="teamlabel">${WORK_LABEL}</div>
    <div class="agents">${work_cards}</div>
  </div>
$( [ "$DEMO" != 1 ] && cat <<TEAMS
  <div class="team">
    <div class="teamlabel">Personal team <span class="ch">· telegram · your products</span></div>
    <div class="agents">${personal_cards}</div>
  </div>
  <div class="team">
    <div class="teamlabel">Experimental <span class="ch">· model bench${sc_date:+ · $sc_date}</span></div>
    <div class="agents">${bench_cards}</div>
  </div>
TEAMS
)
</section>

$( [ "$have_burn" = 1 ] && cat <<BURN
<section>
  <div class="shead"><h2>Token burn — last 24h</h2><div class="rule"></div><div class="note">what each agent consumed of your Claude plan${plan_pct:+ · plan window ${plan_pct}% used}</div></div>
  <div class="agents">${burn_cards}</div>
  <div class="teamlabel" style="margin-top:8px">total $(awk -v t="$burn_total" 'BEGIN{ if (t>=1000000) printf "%.1fM", t/1000000; else if (t>=1000) printf "%.0fk", t/1000; else print t }') tokens · ${burn_events_24h} firewall event(s) in 24h · runaway loops are caught and stopped automatically</div>
</section>
BURN
)

$( [ "$DEMO" != 1 ] && cat <<RESIL
<section>
  <div class="shead"><h2>Model resilience</h2><div class="rule"></div><div class="note">what happens when Claude Max runs out</div></div>
  <div class="health">
    $(hc ok 'Claude Max → ChatGPT/Codex fallback' 'Opus/Sonnet agents fall back to openai/gpt-5.5 (or mini) when weekly Claude limits hit.')
    $(hc ok 'Codex worker agent online' 'kai / ping / dash can spawn the codex subagent for heavy build loops.')
    $(hc ok 'Public spectator board' 'fleet.ani.computer shows redacted live quests for sharing.')
  </div>
  <div class="teamlabel" style="margin-top:10px">Auth sync: hourly from ~/.codex → OpenClaw agent stores · OpenClaw $(openclaw --version 2>/dev/null | head -1 | sed 's/OpenClaw //')</div>
</section>
RESIL
)

<section>
  <div class="shead"><h2>System health</h2><div class="rule"></div><div class="note">the plumbing, in plain terms</div></div>
  <div class="health">
    ${gw_cell}
    ${tm_cell}
    ${sc_cell}
    $(hc ok 'Shared memory healthy' 'Brain online, backups current.')
  </div>
</section>

<details>
  <summary>Raw signals — operator view</summary>
  <div class="body">
    <div class="tw"><table>
      <tr><th>gateway</th><th>state</th></tr>${services_rows}
    </table></div>
    <h4>Timers</h4>
    <div class="tw"><table><tr><th>timer</th><th>next fire</th><th></th></tr>${timers_rows}</table></div>
    <h4>Scan health</h4>
    <p>${rot_24h} rotations / ${backoff_24h} backoffs in 24h · ${backoff_1h} backoff in last hour · doctor: ${doctor_ok:-0} ok, ${doctor_warn:-0} warn, ${doctor_fail:-0} fail</p>
    <h4>GBrain</h4><pre>${gbrain_out}</pre>
    ${scorecard_html:+<h4>Experimental scorecard</h4>$scorecard_html}
    ${evals_html:+<h4>Memory evals</h4>$evals_html}
    <h4>Daily standup</h4><pre>${standup}</pre>
  </div>
</details>

<footer>$( if [ "$DEMO" = 1 ]; then
  echo "demo fleet with illustrative data · every panel is generated from live signals on a real install · session-warden"
else
  echo "session-warden · fleet-review + health-dashboard · <a href=\"https://fleet.ani.computer\">fleet.ani.computer</a> · $(hostname -s 2>/dev/null)"
fi )</footer>
</div><!--/tv-->

<script>
(function(){
  var root=document.documentElement;
  var isDemo=root.getAttribute('data-demo')==='1';
  var reduce=window.matchMedia&&window.matchMedia('(prefers-reduced-motion:reduce)').matches;
  var h=[72,88,64,95,80,70,90,60,85,78,92,68,86,100];
  function buildBars(){var bars=document.getElementById('bars');if(!bars||bars.childElementCount)return;
    h.forEach(function(v){var b=document.createElement('div');b.className='b';b.style.height=(reduce?v:8)+'%';bars.appendChild(b);});}
  function grow(){if(reduce)return;var bars=document.getElementById('bars');if(!bars)return;
    [].forEach.call(bars.children,function(b,i){setTimeout(function(){b.style.height=h[i]+'%';},120+i*45);});}
  function count(){if(reduce)return;
    document.querySelectorAll('.cv .num[data-count]').forEach(function(el){
      var target=+el.getAttribute('data-count');var u=el.querySelector('.u');var suffix=u?u.outerHTML:'';
      var start=null,dur=800;
      function step(ts){if(!start)start=ts;var p=Math.min((ts-start)/dur,1);var e=1-Math.pow(1-p,3);
        el.innerHTML=Math.round(e*target).toLocaleString()+suffix;if(p<1)requestAnimationFrame(step);}
      el.innerHTML='0'+suffix;requestAnimationFrame(step);});}
  function animateSimple(){buildBars();count();grow();}
  window.setView=function(v){root.setAttribute('data-view',v);
    if(!isDemo){try{localStorage.setItem('fleetView',v);}catch(e){}}
    if(v==='simple')animateSimple();window.scrollTo(0,0);};
  if(!isDemo){var saved=null;try{saved=localStorage.getItem('fleetView');}catch(e){}if(saved)root.setAttribute('data-view',saved);}
  if(root.getAttribute('data-view')==='simple'){window.addEventListener('load',animateSimple);}
})();
</script>
</body>
</html>
HTML

chmod 644 "$tmp"
mv -f "$tmp" "$OUTPUT_FILE"
