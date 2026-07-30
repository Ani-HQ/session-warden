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
# ----------------------------------------------------- PAYROLL (cost ledger)
# Month-to-date per-agent cost from contrib/costs/costs.py: what each agent's
# tokens would cost at public API list prices vs the flat subscription
# payroll they actually run on. Read-only; skipped when stale (>6h).
COSTS_JSON="$STATE/costs/costs.json"
have_pay=0
pay_label=""; pay_would=0; pay_actual=0; pay_saved=0; pay_pct=0
pay_tokens=0; pay_plans=""; pay_rows=""; pay_detail_rows=""; pay_bar=0; pay_chips=""
declare -A PAY_WAGE PAY_WORTH PAY_TOK PAY_MODEL
money() { python3 -c 'import sys; v=float(sys.argv[1] or 0); print(f"${v:,.0f}" if v>=1000 else f"${v:,.2f}")' "${1:-0}"; }
tokfmt() { python3 -c 'import sys; t=float(sys.argv[1] or 0); print(f"{t/1e9:.1f}B" if t>=1e9 else (f"{t/1e6:.1f}M" if t>=1e6 else (f"{t/1e3:.0f}k" if t>=1e3 else str(int(t)))))' "${1:-0}"; }
if [ "$DEMO" = 1 ]; then
  have_pay=1
  pay_label="Jul 2026"; pay_would=1240; pay_actual=220; pay_saved=1020; pay_pct=82
  pay_tokens=512000000; pay_bar=18
  pay_plans="Claude Max \$200/mo · ChatGPT Plus \$20/mo · Gemini API \$0.00 used"
  pay_chips='<span class="pchip">Claude Max · <b>$200/mo</b></span><span class="pchip">ChatGPT Plus · <b>$20/mo</b></span><span class="pchip">Gemini API · <b>$0.00 used</b></span>'
  pay_rows="$(printf '%s\n' \
    '<tr><td class="name">maya</td><td class="mono">claude-sonnet</td><td class="mono">184M</td><td class="mono">$412</td><td class="mono">$75.90</td><td class="mono">$336.10</td></tr>' \
    '<tr><td class="name">leo</td><td class="mono">claude-sonnet</td><td class="mono">142M</td><td class="mono">$318</td><td class="mono">$54.90</td><td class="mono">$263.10</td></tr>' \
    '<tr><td class="name">ava</td><td class="mono">claude-opus</td><td class="mono">96M</td><td class="mono">$264</td><td class="mono">$45.10</td><td class="mono">$218.90</td></tr>' \
    '<tr><td class="name">iris</td><td class="mono">claude-sonnet</td><td class="mono">61M</td><td class="mono">$152</td><td class="mono">$28.10</td><td class="mono">$123.90</td></tr>' \
    '<tr><td class="name">sam</td><td class="mono">gpt-5.6</td><td class="mono">29M</td><td class="mono">$94</td><td class="mono">$16.00</td><td class="mono">$78.00</td></tr>')"
else
  if [ -s "$COSTS_JSON" ]; then
    c_gen=$(jq -r '.generatedAt // 0' "$COSTS_JSON" 2>/dev/null)
    now_ms=$(( $(date +%s) * 1000 ))
    if [ "${c_gen:-0}" -gt 0 ] && [ $(( now_ms - c_gen )) -lt 21600000 ] 2>/dev/null; then
      have_pay=1
      pay_label=$(jq -r '.window.label // ""' "$COSTS_JSON")
      pay_would=$(jq -r '.totals.wouldCost // 0' "$COSTS_JSON")
      pay_actual=$(jq -r '.totals.actualCost // 0' "$COSTS_JSON")
      pay_saved=$(jq -r '.totals.savings // 0' "$COSTS_JSON")
      pay_pct=$(jq -r '.totals.savingsPct // 0' "$COSTS_JSON")
      pay_tokens=$(jq -r '.totals.tokens // 0' "$COSTS_JSON")
      pay_plans=$(jq -r '.plans | to_entries[] | .value
        | if .billed == "subscription" then "\(.label) $\(.monthlyUsd | floor)/mo"
          else "\(.label) $\(.poolWould) used" end' "$COSTS_JSON" \
        | awk 'BEGIN{ORS=""} NR>1{printf " · "} {printf "%s",$0} END{print ""}')
      [ "$(awk -v w="$pay_would" 'BEGIN{print (w>0)?1:0}')" = 1 ] && \
        pay_bar=$(awk -v a="$pay_actual" -v w="$pay_would" 'BEGIN{p=a*100/w; if(p<2)p=2; if(p>100)p=100; printf "%.0f", p}')
      active_roster=" ping dash bloop isaac zara codex "
      while IFS=$'\t' read -r a would actual saved toks topm; do
        [ -z "$a" ] && continue
        note=""
        case "$active_roster" in *" $a "*) ;; *) note=' <span class="achip off">retired</span>' ;; esac
        pay_rows+="<tr><td class=\"name\">$(hesc "$a")$note</td><td class=\"mono\">$(hesc "$topm")</td><td class=\"mono\">$(tokfmt "$toks")</td><td class=\"mono\">$(money "$would")</td><td class=\"mono\">$(money "$actual")</td><td class=\"mono\">$(money "$saved")</td></tr>"
        PAY_WAGE[$a]="$actual"; PAY_WORTH[$a]="$would"; PAY_TOK[$a]="$toks"; PAY_MODEL[$a]="$topm"
      done < <(jq -r '.agents[] | [.id, (.wouldCost|tostring), (.actualCost|tostring), (.savings|tostring), (.tokens|tostring), (.topModel // "")] | @tsv' "$COSTS_JSON" | sort -t$'\t' -k2 -nr)
      while IFS=$'\t' read -r a prov toks would actual; do
        [ -z "$a" ] && continue
        pay_detail_rows+="<tr><td class=\"name\">$(hesc "$a")</td><td class=\"mono\">$(hesc "$prov")</td><td class=\"mono\">$(tokfmt "$toks")</td><td class=\"mono\">$(money "$would")</td><td class=\"mono\">$(money "$actual")</td></tr>"
      done < <(jq -r '.agents[] | .id as $a | .byProvider | to_entries[]
        | [$a, .key, (.value.tokens|tostring), (.value.would|tostring), (.value.actual|tostring)] | @tsv' "$COSTS_JSON")
      while IFS=$'\t' read -r plabel pbilled pmonthly pused; do
        [ -z "$plabel" ] && continue
        if [ "$pbilled" = "subscription" ]; then
          pay_chips+="<span class=\"pchip\">$(hesc "$plabel") · <b>\$${pmonthly}/mo</b></span>"
        else
          pay_chips+="<span class=\"pchip\">$(hesc "$plabel") · <b>\$${pused} used</b></span>"
        fi
      done < <(jq -r '.plans | to_entries[] | .value | [.label, .billed, (.monthlyUsd|floor|tostring), (.poolWould|tostring)] | @tsv' "$COSTS_JSON")
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
# ---- client (simple) view: Linear + Liveline dashboard ---------------
stars_for() { # $1=score -> "WORD|TIER"
  local s="${1:-70}"
  if   [ "$s" -ge 90 ] 2>/dev/null; then echo 'Excellent|exc'
  elif [ "$s" -ge 78 ] 2>/dev/null; then echo 'Great|grt'
  elif [ "$s" -ge 65 ] 2>/dev/null; then echo 'Good|gd'
  else echo 'Solid|ok'; fi
}

# 14-day session activity series for the Liveline chart (mtime proxy).
activity_series_json() {
  python3 - <<'APY'
from pathlib import Path
from collections import Counter
from datetime import datetime, timezone, timedelta
import json
home = Path.home() / ".openclaw/agents"
roster=set()
rf=Path.home()/"session-warden/config/fleet-roster.tsv"
if rf.exists():
    for line in rf.read_text().splitlines():
        if not line.strip() or line.startswith("#"): continue
        roster.add(line.split("\t")[0].strip())
if not roster: roster={"ping","bloop","dash","isaac","zara"}
now = datetime.now(timezone.utc)
days = [(now - timedelta(days=i)) for i in range(13, -1, -1)]
day_keys = [d.strftime("%Y-%m-%d") for d in days]
total = Counter()
per = {}
for ag in sorted(home.iterdir()):
    if not ag.is_dir() or ag.name not in roster: continue
    cnt = Counter()
    sess = ag / "sessions"
    if sess.exists():
        for f in sess.glob("*.jsonl"):
            m = datetime.fromtimestamp(f.stat().st_mtime, timezone.utc).strftime("%Y-%m-%d")
            if m in day_keys:
                total[m] += 1
                cnt[m] += 1
    per[ag.name] = [cnt[d] for d in day_keys]
series = [{"time": int(d.replace(hour=12).timestamp()*1000), "value": total[k]} for d,k in zip(days, day_keys)]
print(json.dumps({"series": series, "per": per, "days": day_keys}))
APY
}

render_client() {
  if [ "$DEMO" = 1 ]; then
    cat <<'CVEOF'
<div class="cv"><div class="wrap">
  <header class="top rise" style="--d:.02s">
    <div class="brand"><span class="mark"></span><div><b>Fleet</b><span>Ember &amp; Oak Coffee</span></div></div>
    <div class="livepill"><span class="dot"></span>Live · updated 2 min ago</div>
  </header>
  <section class="hero rise" style="--d:.06s">
    <h1>Your team is healthy.</h1>
    <p class="lede"><b>5 assistants</b> handled <b>512</b> tasks this week and returned about <b>14 hours</b>.</p>
  </section>
  <section class="panel rise" style="--d:.1s">
    <div class="phead">
      <div>
        <div class="plabel">Activity</div>
        <div class="pval" id="liveVal">512</div>
        <div class="pmeta">tasks · last 14 days</div>
      </div>
      <div class="wins" role="tablist" aria-label="Time window">
        <button class="w on" data-secs="1209600" type="button">14d</button>
        <button class="w" data-secs="604800" type="button">7d</button>
        <button class="w" data-secs="259200" type="button">3d</button>
      </div>
    </div>
    <div class="chart" id="mainChart" aria-hidden="true"></div>
  </section>
  <section class="metrics rise" style="--d:.14s">
    <div class="metric"><span class="mlab">Time saved</span><span class="mnum">14<span>hrs</span></span></div>
    <div class="metric"><span class="mlab">Work done</span><span class="mnum">512</span></div>
    <div class="metric"><span class="mlab">Uptime</span><span class="mnum">24<span>/7</span></span></div>
    <div class="metric"><span class="mlab">With you</span><span class="mnum">127<span>d</span></span></div>
  </section>
  <section class="panel rise payband" style="--d:.16s">
    <div class="phead">
      <div>
        <div class="plabel">Payroll · Jul 2026</div>
        <div class="pval">$220<span class="psuffix">/mo</span></div>
        <div class="pmeta">flat subscriptions — the meter never runs</div>
      </div>
      <div class="paynums">
        <div class="pnum first"><span>work delivered</span><b>$1,240</b><i>at API list prices</i></div>
        <div class="pnum"><span>kept in pocket</span><b>82%</b><i>saved $1,020</i></div>
      </div>
    </div>
    <div class="paybar" aria-hidden="true"><i style="width:18%"></i></div>
    <div class="payplans"><span class="pchip">Claude Max · <b>$200/mo</b></span><span class="pchip">ChatGPT Plus · <b>$20/mo</b></span><span class="pchip">Gemini API · <b>$0.00 used</b></span></div>
  </section>
  <section class="rise" style="--d:.18s">
    <div class="shead"><h2>Team</h2><span class="scount">5</span></div>
    <div class="roster">
      <div class="row"><div class="who"><div><b>Maya</b><span>Content &amp; Social · wage $55/mo</span></div></div><canvas class="spark" data-spark="[3,4,5,4,6,5,7,6,5,8,7,6,8,9]" width="96" height="28"></canvas><div class="score"><b>94</b><span class="t-exc">Excellent</span></div><span class="st on">on</span></div>
      <div class="row"><div class="who"><div><b>Leo</b><span>Customer Support · wage $51/mo</span></div></div><canvas class="spark" data-spark="[8,7,9,8,10,9,8,11,10,9,12,11,10,9]" width="96" height="28"></canvas><div class="score"><b>88</b><span class="t-grt">Great</span></div><span class="st on">on</span></div>
      <div class="row"><div class="who"><div><b>Ava</b><span>Operations · wage $48/mo</span></div></div><canvas class="spark" data-spark="[2,3,2,4,3,5,4,3,4,5,4,6,5,4]" width="96" height="28"></canvas><div class="score"><b>92</b><span class="t-exc">Excellent</span></div><span class="st on">on</span></div>
      <div class="row"><div class="who"><div><b>Sam</b><span>Bookkeeping · wage $33/mo</span></div></div><canvas class="spark" data-spark="[1,2,1,2,3,2,2,3,2,3,4,3,3,2]" width="96" height="28"></canvas><div class="score"><b>85</b><span class="t-grt">Great</span></div><span class="st on">on</span></div>
      <div class="row"><div class="who"><div><b>Iris</b><span>Your Assistant · wage $33/mo</span></div></div><canvas class="spark" data-spark="[4,3,5,4,4,5,6,5,4,5,6,5,7,6]" width="96" height="28"></canvas><div class="score"><b>91</b><span class="t-exc">Excellent</span></div><span class="st on">on</span></div>
    </div>
  </section>
  <footer class="foot rise" style="--d:.22s">Fleet · Ember &amp; Oak Coffee · managed for you</footer>
</div>
<script type="application/json" id="activityData">{"series":[{"time":0,"value":22},{"time":1,"value":28},{"time":2,"value":31},{"time":3,"value":27},{"time":4,"value":35},{"time":5,"value":42},{"time":6,"value":38},{"time":7,"value":45},{"time":8,"value":40},{"time":9,"value":48},{"time":10,"value":44},{"time":11,"value":50},{"time":12,"value":47},{"time":13,"value":52}],"per":{}}</script>
</div>
CVEOF
    return
  fi

  local OC="${WARDEN_OPENCLAW_HOME:-$HOME/.openclaw}"
  local hours=$(( sessions_week / 4 )); [ "$hours" -lt 1 ] && hours=1
  local oldest days=""
  oldest=$(find "$OC"/agents/*/sessions -name '*.jsonl' -printf '%T@\n' 2>/dev/null | sort -n | head -1 | cut -d. -f1)
  [ -n "$oldest" ] && days=$(( ( $(date +%s) - oldest ) / 86400 ))
  local act_json
  act_json="$(activity_series_json 2>/dev/null || echo '{"series":[],"per":{},"days":[]}')"

  local rows="" i=0
  while IFS=$'\t' read -r rname rrole rscore rsess rins; do
    [ -z "$rname" ] && continue
    local sw sword tier init disp rshort did spark delay
    sw="$(stars_for "$rscore")"; sword="${sw%|*}"; tier="${sw#*|}"
    init="$(printf '%s' "${rname:0:1}" | tr '[:lower:]' '[:upper:]')"
    disp="${init}${rname:1}"
    rshort="$(printf '%s' "$rrole" | sed -E 's/ [—(].*//; s/ —.*//')"
    if [ "$have_pay" = 1 ] && [ -n "${PAY_WAGE[$rname]:-}" ]; then
      rshort="${rshort} · wage $(money "${PAY_WAGE[$rname]}")/mo"
    fi
    did="$(printf '%s' "$rins" | sed -E 's/ — but .*//; s/, but .*//; s/([^.]*\.).*/\1/')"
    [ "${#did}" -gt 120 ] && did="${did:0:117}…"
    [ -z "$did" ] && did="${rsess} sessions this week."
    spark="$(printf '%s' "$act_json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(','.join(map(str,d.get('per',{}).get('$rname',[0]*14))))" 2>/dev/null)"
    [ -z "$spark" ] && spark="0,0,0,0,0,0,0,0,0,0,0,0,0,0"
    delay="$(python3 -c "print(f'{0.18 + 0.03 * $i:.2f}')")"
    rows+="<div class=\"row rise\" style=\"--d:${delay}s\" title=\"$(hesc "$did")\">"
    rows+="<div class=\"who\"><div><b>$(hesc "$disp")</b><span>$(hesc "$rshort")</span></div></div>"
    rows+="<canvas class=\"spark\" data-spark=\"[${spark}]\" width=\"96\" height=\"28\" aria-hidden=\"true\"></canvas>"
    rows+="<div class=\"score\"><b>${rscore}</b><span class=\"t-${tier}\">${sword}</span></div>"
    rows+="<span class=\"st on\">on</span></div>"
    i=$(( i + 1 ))
  done < <(jq -r '.agents[] | select(.active) | [.agent,.role,((.score//70)|tostring),(.sessions|tostring),(.insight // "")] | @tsv' "$REVIEW_JSON" 2>/dev/null)
  [ -z "$rows" ] && rows='<div class="empty">No active agents this week.</div>'

  local fourth_lab="With you" fourth_num="${days:-—}" fourth_u="d"
  if [ -z "$days" ]; then
    fourth_lab="Agents"; fourth_num="${active_prod}"; fourth_u="/${total_prod}"
  fi

  local verdict_line="Fleet is healthy."
  local attn_cta=""
  if [ "${gw_down:-0}" != 0 ] 2>/dev/null; then
    verdict_line="A gateway is offline."
    attn_cta="<button type=\"button\" class=\"cta\" onclick=\"setView('tech')\">See gateways in Technical <span aria-hidden=\"true\">→</span></button>"
  elif [ "${n_attn:-0}" -gt 0 ] 2>/dev/null; then
    if [ "${n_attn}" -eq 1 ]; then
      verdict_line="1 item needs attention."
    else
      verdict_line="${n_attn} items need attention."
    fi
    attn_cta="<button type=\"button\" class=\"cta\" onclick=\"setView('tech')\">See them in Technical <span aria-hidden=\"true\">→</span></button>"
  fi

  cat <<CVEOF
<div class="cv"><div class="wrap">
  <header class="top rise" style="--d:.02s">
    <div class="brand"><span class="mark"></span><div><b>Fleet</b><span>${CLIENT_BIZ}</span></div></div>
    <div class="livepill"><span class="dot"></span>Live · ${NOW_UTC}</div>
  </header>

  <section class="hero rise" style="--d:.06s">
    <h1>${verdict_line}</h1>
    ${attn_cta}
    <p class="lede"><b>${active_prod} agents</b> handled <b>${sessions_week}</b> sessions this week · about <b>${hours} hours</b> of work.</p>
  </section>

  <section class="panel rise" style="--d:.1s">
    <div class="phead">
      <div>
        <div class="plabel">Activity</div>
        <div class="pval" id="liveVal">${sessions_week}</div>
        <div class="pmeta">sessions · trailing window</div>
      </div>
      <div class="wins" role="tablist" aria-label="Time window">
        <button class="w on" data-secs="1209600" type="button">14d</button>
        <button class="w" data-secs="604800" type="button">7d</button>
        <button class="w" data-secs="259200" type="button">3d</button>
      </div>
    </div>
    <div class="chart" id="mainChart" aria-hidden="true"></div>
  </section>

  <section class="metrics rise" style="--d:.14s">
    <div class="metric"><span class="mlab">Time saved</span><span class="mnum">${hours}<span>hrs</span></span></div>
    <div class="metric"><span class="mlab">Sessions</span><span class="mnum">${sessions_week}</span></div>
    <div class="metric"><span class="mlab">Uptime</span><span class="mnum">24<span>/7</span></span></div>
    <div class="metric"><span class="mlab">${fourth_lab}</span><span class="mnum">${fourth_num}<span>${fourth_u}</span></span></div>
  </section>

$( [ "$have_pay" = 1 ] && cat <<PAYBAND
  <section class="panel rise payband" style="--d:.16s">
    <div class="phead">
      <div>
        <div class="plabel">Payroll · ${pay_label}</div>
        <div class="pval">$(money "$pay_actual")<span class="psuffix">/mo</span></div>
        <div class="pmeta">flat subscriptions — the meter never runs</div>
      </div>
      <div class="paynums">
        <div class="pnum first"><span>work delivered</span><b>$(money "$pay_would")</b><i>at API list prices</i></div>
        <div class="pnum"><span>kept in pocket</span><b>${pay_pct}%</b><i>saved $(money "$pay_saved")</i></div>
      </div>
    </div>
    <div class="paybar" aria-hidden="true"><i style="width:${pay_bar}%"></i></div>
    <div class="payplans">${pay_chips}</div>
  </section>
PAYBAND
)

  <section class="rise" style="--d:.18s">
    <div class="shead"><h2>Team</h2><span class="scount">${active_prod}</span></div>
    <div class="roster">${rows}</div>
  </section>

  <footer class="foot rise" style="--d:.24s">
    <a href="https://fleet.ani.computer">fleet.ani.computer</a>
    <span>·</span>
    <span>refreshes every 10 min</span>
  </footer>
</div>
<script type="application/json" id="activityData">${act_json}</script>
</div>
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
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans:wght@400;500;600&display=swap" rel="stylesheet">
<title>Fleet Status — ${FLEET_NAME}</title>
<style>
  :root{
    --ease:cubic-bezier(0.23,1,0.32,1);
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
  .tw{overflow-x:auto}
  .tw table{width:100%;border-collapse:collapse;font-size:12px;margin-top:6px}
  .tw th{text-align:left;color:var(--dim);font-weight:700;font-size:10px;text-transform:uppercase;letter-spacing:.1em;padding:4px 12px 4px 0;border-bottom:1px dashed var(--edge2)}
  .tw td{padding:6px 12px 6px 0;border-bottom:1px dotted var(--edge);color:var(--muted);vertical-align:top;text-shadow:none}
  .tw .name{color:var(--mid);font-weight:700}
  .paystats{margin-top:0;margin-bottom:4px}
  details .pill::before{content:"["} details .pill::after{content:"]"}
  .pill{font-weight:700} .pill.green{color:var(--green)} .pill.amber{color:var(--amber)} .pill.red{color:var(--red)} .pill.gray{color:var(--gray)}
  footer{margin-top:34px;color:var(--dim);font-size:11px;text-align:center;text-shadow:none;letter-spacing:.05em}
  @media (prefers-reduced-motion:reduce){.cursor{animation:none}}
  @media (max-width:680px){body{padding:16px 10px 50px}.stats{grid-template-columns:repeat(2,1fr)}.vstate{font-size:23px}}

  /* ============ view toggle ============ */
  /* Floating view toggle — fixed geometry; only colors change between views */
  .viewbar{
    position:fixed; top:14px; left:50%; transform:translateX(-50%);
    z-index:80; display:flex; justify-content:center; padding:0;
    pointer-events:none;
  }
  .seg{
    pointer-events:auto;
    display:inline-flex; gap:2px; padding:3px; border-radius:8px;
    font-family:'IBM Plex Sans',ui-sans-serif,system-ui,sans-serif;
    border:1px solid #1e1e24; background:#121216;
    box-shadow:0 8px 28px rgba(0,0,0,.35);
    transition:background 160ms var(--ease,cubic-bezier(.23,1,.32,1)), border-color 160ms var(--ease,cubic-bezier(.23,1,.32,1)), box-shadow 160ms var(--ease,cubic-bezier(.23,1,.32,1));
  }
  .seg button{
    appearance:none; border:0; background:transparent;
    font:500 12px/1 'IBM Plex Sans',ui-sans-serif,system-ui,sans-serif;
    padding:7px 12px; border-radius:6px; cursor:pointer; color:#6b6f76;
    transition:transform 160ms var(--ease,cubic-bezier(.23,1,.32,1)), background 160ms var(--ease,cubic-bezier(.23,1,.32,1)), color 160ms var(--ease,cubic-bezier(.23,1,.32,1));
  }
  .seg button:active{transform:scale(.97)}
  .seg button .dot{
    display:inline-block; width:5px; height:5px; border-radius:50%;
    margin-right:6px; opacity:.35; vertical-align:1px;
    background:currentColor;
    transition:opacity 160ms var(--ease,cubic-bezier(.23,1,.32,1)), background 160ms var(--ease,cubic-bezier(.23,1,.32,1));
  }
  html[data-view="simple"] .seg{background:#121216; border-color:#1e1e24; box-shadow:0 8px 28px rgba(0,0,0,.35)}
  html[data-view="simple"] .seg button{color:#6b6f76}
  html[data-view="simple"] .seg .b-simple{background:#1c1c22; color:#ededef}
  html[data-view="simple"] .seg .b-simple .dot{opacity:1; background:#82a7ff}
  html[data-view="tech"] .seg{background:#121216; border-color:#1e1e24; box-shadow:0 8px 28px rgba(0,0,0,.35)}
  html[data-view="tech"] .seg button{color:#6b6f76}
  html[data-view="tech"] .seg .b-tech{background:#1c1c22; color:#ededef}
  html[data-view="tech"] .seg .b-tech .dot{opacity:1; background:#7dffa8}
  html[data-view="tech"] .cv{display:none}
  .tv{padding-top:44px}
  html[data-view="simple"] .tv{display:none}
  html[data-view="simple"]{background:#09090b}
  html[data-view="simple"] body{background:#09090b;color:#ededef;text-shadow:none;max-width:none;padding:0;font-family:var(--cv-sans,'IBM Plex Sans',sans-serif)}
  html[data-view="simple"] body::before,html[data-view="simple"] body::after{display:none}

  /* ============ Simple view — Linear + Liveline ============ */
  .cv{
    --ink:#ededef; --mut:#8a8f98; --faint:#5c6169; --line:#1e1e24; --line2:#16161a;
    --panel:#0f0f12; --acc:#82a7ff; --ok:#3dd68c; --warn:#f5a524;
    --ease:cubic-bezier(0.23,1,0.32,1);
    --cv-sans:'IBM Plex Sans',ui-sans-serif,system-ui,sans-serif;
    --cv-mono:'IBM Plex Mono',ui-monospace,Menlo,monospace;
    font-family:var(--cv-sans); color:var(--ink); line-height:1.45;
    min-height:100vh; background:
      radial-gradient(900px 420px at 18% -10%, rgba(130,167,255,.07), transparent 60%),
      radial-gradient(700px 380px at 90% 0%, rgba(61,214,140,.04), transparent 55%),
      #09090b;
  }
  .cv .wrap{max-width:880px;margin:0 auto;padding:56px 24px 80px}
  .cv .rise{opacity:0;transform:translateY(8px) scale(.985);animation:cvin .55s var(--ease) forwards;animation-delay:var(--d,0s)}
  @keyframes cvin{to{opacity:1;transform:none}}

  .cv .top{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:18px 0 28px}
  .cv .brand{display:flex;align-items:center;gap:12px}
  .cv .mark{width:18px;height:18px;border-radius:5px;background:linear-gradient(135deg,#82a7ff,#5b7fd4);box-shadow:0 0 0 1px rgba(130,167,255,.25),0 0 20px rgba(130,167,255,.15)}
  .cv .brand b{display:block;font-size:13px;font-weight:600;letter-spacing:.02em}
  .cv .brand span{display:block;font-size:12px;color:var(--faint);margin-top:1px}
  .cv .livepill{display:inline-flex;align-items:center;gap:8px;font-size:12px;color:var(--mut);font-variant-numeric:tabular-nums}
  .cv .livepill .dot{width:6px;height:6px;border-radius:50%;background:var(--ok);box-shadow:0 0 0 0 rgba(61,214,140,.45);animation:cvpulse 2.4s var(--ease) infinite}
  @keyframes cvpulse{0%{box-shadow:0 0 0 0 rgba(61,214,140,.4)}70%{box-shadow:0 0 0 8px rgba(61,214,140,0)}100%{box-shadow:0 0 0 0 rgba(61,214,140,0)}}

  .cv .hero{margin-bottom:28px}
  .cv h1{font-size:clamp(28px,4.5vw,40px);font-weight:500;letter-spacing:-.035em;line-height:1.1;margin:0 0 10px}
  .cv .lede{font-size:15px;color:var(--mut);max-width:54ch;margin:0}
  .cv .lede b{color:var(--ink);font-weight:550}
  .cv .cta{
    display:inline-flex; align-items:center; gap:6px;
    margin:14px 0 16px; padding:8px 12px;
    border:1px solid var(--line); border-radius:8px;
    background:#141418; color:var(--ink);
    font:500 13px/1 var(--cv-sans); cursor:pointer;
    transition:transform 160ms var(--ease), background 160ms var(--ease), border-color 160ms var(--ease), color 160ms var(--ease);
  }
  .cv .cta span{color:var(--acc); transition:transform 160ms var(--ease)}
  .cv .cta:hover{background:#1a1a20; border-color:#2a2a32}
  .cv .cta:hover span{transform:translateX(2px)}
  .cv .cta:active{transform:scale(.97)}
  .cv h1 + .lede{margin-top:10px}
  .cv h1 + .cta + .lede{margin-top:0}

  .cv .panel{border:1px solid var(--line);border-radius:12px;background:var(--panel);padding:18px 18px 8px;margin-bottom:14px}
  .cv .phead{display:flex;justify-content:space-between;align-items:flex-start;gap:16px;margin-bottom:4px}
  .cv .plabel{font-size:11px;font-weight:500;letter-spacing:.08em;text-transform:uppercase;color:var(--faint);margin-bottom:6px}
  .cv .pval{font-size:34px;font-weight:500;letter-spacing:-.03em;font-variant-numeric:tabular-nums;line-height:1;font-family:var(--cv-mono)}
  .cv .pmeta{font-size:12px;color:var(--faint);margin-top:6px}
  .cv .wins{display:inline-flex;gap:2px;padding:3px;border:1px solid var(--line);border-radius:8px;background:#0a0a0d}
  .cv .wins .w{appearance:none;border:0;background:transparent;color:var(--faint);font:500 11px/1 var(--cv-mono);padding:6px 10px;border-radius:5px;cursor:pointer;transition:background 160ms var(--ease),color 160ms var(--ease),transform 140ms var(--ease)}
  .cv .wins .w:hover{color:var(--mut)}
  .cv .wins .w:active{transform:scale(.97)}
  .cv .wins .w.on{background:#1a1a20;color:var(--ink)}
  .cv .chart{height:168px;margin:0 -6px -2px;position:relative}

  .cv .payband .phead{margin-bottom:14px}
  .cv .psuffix{font-size:14px;color:var(--faint);margin-left:3px}
  .cv .paynums{display:flex;gap:26px}
  .cv .pnum{display:flex;flex-direction:column;align-items:flex-end;text-align:right}
  .cv .pnum span{font-size:11px;font-weight:500;letter-spacing:.06em;text-transform:uppercase;color:var(--faint)}
  .cv .pnum b{font-family:var(--cv-mono);font-size:20px;font-weight:500;letter-spacing:-.02em;color:var(--ok);margin:5px 0 3px;font-variant-numeric:tabular-nums}
  .cv .pnum.first b{color:var(--ink)}
  .cv .pnum i{font-style:normal;font-size:11px;color:var(--faint)}
  .cv .paybar{height:5px;border-radius:99px;background:#16161b;overflow:hidden;margin:0 0 12px}
  .cv .paybar i{display:block;height:100%;border-radius:99px;background:linear-gradient(90deg,#2f9e68,var(--ok))}
  .cv .payplans{display:flex;flex-wrap:wrap;gap:6px}
  .cv .pchip{border:1px solid var(--line);border-radius:999px;padding:4px 10px;font-size:11px;color:var(--mut);font-variant-numeric:tabular-nums}
  .cv .pchip b{color:var(--ink);font-weight:550}

  .cv .metrics{display:grid;grid-template-columns:repeat(4,1fr);border:1px solid var(--line);border-radius:12px;overflow:hidden;margin-bottom:28px;background:var(--panel)}
  .cv .metric{padding:16px 18px;border-right:1px solid var(--line)}
  .cv .metric:last-child{border-right:0}
  .cv .mlab{display:block;font-size:11px;font-weight:500;letter-spacing:.06em;text-transform:uppercase;color:var(--faint);margin-bottom:8px}
  .cv .mnum{display:block;font-size:22px;font-weight:500;letter-spacing:-.02em;font-variant-numeric:tabular-nums;font-family:var(--cv-mono);line-height:1}
  .cv .mnum span{font-size:12px;color:var(--faint);margin-left:3px;font-weight:500}

  .cv .shead{display:flex;align-items:baseline;gap:10px;margin:0 0 10px}
  .cv .shead h2{font-size:13px;font-weight:500;letter-spacing:.08em;text-transform:uppercase;color:var(--faint);margin:0}
  .cv .scount{font-size:12px;color:var(--mut);font-family:var(--cv-mono);font-variant-numeric:tabular-nums}

  .cv .roster{border:1px solid var(--line);border-radius:12px;overflow:hidden;background:var(--panel)}
  .cv .row{display:grid;grid-template-columns:minmax(160px,1.4fr) 96px 88px 40px;align-items:center;gap:14px;padding:14px 16px;border-bottom:1px solid var(--line);transition:background 160ms var(--ease)}
  .cv .row:last-child{border-bottom:0}
  .cv .row:hover{background:#121217}
  .cv .who{display:flex;align-items:center;gap:12px;min-width:0}
  .cv .who b{display:block;font-size:13.5px;font-weight:550;letter-spacing:-.01em}
  .cv .who span{display:block;font-size:12px;color:var(--faint);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:240px}
  .cv .spark{width:96px;height:28px;display:block}
  .cv .score{text-align:right}
  .cv .score b{display:block;font-size:14px;font-weight:550;font-family:var(--cv-mono);font-variant-numeric:tabular-nums}
  .cv .score span{font-size:11px;color:var(--faint)}
  .cv .score .t-exc{color:var(--ok)}
  .cv .score .t-grt{color:#8fd4a8}
  .cv .st{justify-self:end;font-size:11px;font-weight:500;letter-spacing:.04em;text-transform:uppercase;color:var(--faint)}
  .cv .st.on{color:var(--ok)}
  .cv .empty{padding:20px;color:var(--faint);font-size:13px}

  .cv .foot{display:flex;align-items:center;justify-content:center;gap:10px;margin-top:36px;padding-top:20px;border-top:1px solid var(--line);font-size:12px;color:var(--faint)}
  .cv .foot a{color:var(--mut);text-decoration:none;transition:color 160ms var(--ease)}
  .cv .foot a:hover{color:var(--ink)}

  @media (prefers-reduced-motion:reduce){
    .cv .rise{animation:none;opacity:1;transform:none}
    .cv .livepill .dot{animation:none}
  }
  @media (max-width:720px){
    .cv .wrap{padding:4px 16px 64px}
    .cv .metrics{grid-template-columns:repeat(2,1fr)}
    .cv .metric:nth-child(2){border-right:0}
    .cv .metric:nth-child(1),.cv .metric:nth-child(2){border-bottom:1px solid var(--line)}
    .cv .row{grid-template-columns:1fr 72px 40px;gap:10px}
    .cv .spark{display:none}
    .cv .score{display:none}
    .cv .chart{height:140px}
    .cv .phead{flex-direction:column;align-items:stretch}
    .cv .paynums{gap:14px}
    .cv .pnum{align-items:flex-start;text-align:left}
    .cv .pnum b{font-size:17px}
  }

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

$( [ "$have_pay" = 1 ] && cat <<PAY
<section>
  <div class="shead"><h2>Payroll — ${pay_label}</h2><div class="rule"></div><div class="note">would-cost = tokens × public API list prices · actual = flat subscriptions + metered API</div></div>
  <div class="stats paystats">
    <div class="stat"><div class="n">$(money "$pay_would")</div><div class="l">Work delivered</div><div class="sub">API list value, month to date</div></div>
    <div class="stat"><div class="n">$(money "$pay_actual")</div><div class="l">Actual payroll</div><div class="sub">$(hesc "$pay_plans")</div></div>
    <div class="stat"><div class="n">${pay_pct}<small>%</small></div><div class="l">Kept in pocket</div><div class="sub">saved $(money "$pay_saved") vs API</div></div>
    <div class="stat"><div class="n">$(tokfmt "$pay_tokens")</div><div class="l">Tokens</div><div class="sub">month to date</div></div>
  </div>
  <div class="tw" style="margin-top:12px"><table>
    <tr><th>agent</th><th>top model</th><th>tokens</th><th>would cost</th><th>actual</th><th>saved</th></tr>${pay_rows}
  </table></div>
  <div class="teamlabel" style="margin-top:8px">rate card: config/cost-rates.json · subscriptions allocated pro-rata by each agent's share of that provider's API-value pool · Gemini billed per token only when it actually runs</div>
</section>
PAY
)

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
    $(hc ok 'Codex worker agent online' 'bloop / isaac / ping / dash can spawn the codex subagent for heavy build loops.')
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
    $( [ "$have_pay" = 1 ] && [ -n "$pay_detail_rows" ] && printf '<h4>Payroll detail — by provider, month to date</h4><div class="tw"><table><tr><th>agent</th><th>provider</th><th>tokens</th><th>would cost</th><th>actual</th></tr>%s</table></div>' "$pay_detail_rows" )
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
  var EASE=0.08;

  function parseData(){
    var el=document.getElementById('activityData');
    if(!el) return {series:[], per:{}};
    try{return JSON.parse(el.textContent||'{}');}catch(e){return {series:[], per:{}};}
  }

  /* Mini Liveline: one canvas, lerp, fill, live tip — inspired by https://benji.org/liveline */
  function Liveline(host, opts){
    this.host=host; this.opts=opts||{};
    this.canvas=document.createElement('canvas');
    this.canvas.style.width='100%'; this.canvas.style.height='100%'; this.canvas.style.display='block';
    host.innerHTML=''; host.appendChild(this.canvas);
    this.ctx=this.canvas.getContext('2d');
    this.points=[]; this.disp=[]; this.ymin=0; this.ymax=1;
    this.dyMin=0; this.dyMax=1; this.value=0; this.dValue=0;
    this.windowSecs=opts.window||1209600;
    this.color=opts.color||'#82a7ff';
    this.raf=null; this._bound=this.frame.bind(this);
    this.resize();
    window.addEventListener('resize', this.resize.bind(this));
  }
  Liveline.prototype.resize=function(){
    var r=this.host.getBoundingClientRect();
    var dpr=Math.min(window.devicePixelRatio||1, 2);
    this.w=Math.max(1,r.width); this.h=Math.max(1,r.height);
    this.canvas.width=this.w*dpr; this.canvas.height=this.h*dpr;
    this.ctx.setTransform(dpr,0,0,dpr,0,0);
  };
  Liveline.prototype.setData=function(series, windowSecs){
    if(windowSecs) this.windowSecs=windowSecs;
    var now=series.length?series[series.length-1].time:Date.now();
    var cut=now-this.windowSecs*1000;
    var pts=series.filter(function(p){return p.time>=cut || series[0].time<1e10;});
    if(!pts.length) pts=series.slice();
    this.points=pts;
    if(!this.disp.length) this.disp=pts.map(function(p){return {t:p.time,v:p.value};});
    var vs=pts.map(function(p){return p.value});
    var mn=Math.min.apply(null,vs.concat([0]));
    var mx=Math.max.apply(null,vs.concat([1]));
    if(mx===mn){mx=mn+1;}
    var pad=(mx-mn)*0.18;
    this.ymin=Math.max(0,mn-pad); this.ymax=mx+pad;
    this.value=pts.length?pts[pts.length-1].value:0;
    if(!this.raf && !reduce) this.raf=requestAnimationFrame(this._bound);
    else if(reduce){ this.disp=pts.map(function(p){return {t:p.time,v:p.value};}); this.dyMin=this.ymin; this.dyMax=this.ymax; this.dValue=this.value; this.draw(); }
  };
  Liveline.prototype.frame=function(){
    var pts=this.points;
    while(this.disp.length<pts.length) this.disp.push({t:pts[this.disp.length].time,v:this.disp.length?this.disp[this.disp.length-1].v:pts[0].value});
    while(this.disp.length>pts.length) this.disp.pop();
    for(var i=0;i<pts.length;i++){
      this.disp[i].t=pts[i].time;
      this.disp[i].v+=(pts[i].value-this.disp[i].v)*EASE;
    }
    this.dyMin+=(this.ymin-this.dyMin)*EASE;
    this.dyMax+=(this.ymax-this.dyMax)*EASE;
    this.dValue+=(this.value-this.dValue)*EASE;
    var valEl=document.getElementById('liveVal');
    if(valEl && this.points.length){
      var sum=0; for(var j=0;j<this.points.length;j++) sum+=this.points[j].value;
      /* show trailing-window sum while lerping tip value for the badge feel */
      valEl.textContent=Math.round(sum).toLocaleString();
    }
    this.draw();
    this.raf=requestAnimationFrame(this._bound);
  };
  Liveline.prototype.draw=function(){
    var ctx=this.ctx, w=this.w, h=this.h, pad={t:12,r:12,b:22,l:8};
    ctx.clearRect(0,0,w,h);
    var pts=this.disp; if(pts.length<2) return;
    var t0=pts[0].t, t1=pts[pts.length-1].t; if(t1===t0) t1=t0+1;
    var y0=this.dyMin, y1=this.dyMax; if(y1===y0) y1=y0+1;
    function X(t){return pad.l + (t-t0)/(t1-t0)*(w-pad.l-pad.r);}
    function Y(v){return pad.t + (1-(v-y0)/(y1-y0))*(h-pad.t-pad.b);}
    ctx.strokeStyle='rgba(237,237,239,0.04)'; ctx.lineWidth=1;
    for(var g=0;g<3;g++){ var gy=pad.t+(h-pad.t-pad.b)*g/2; ctx.beginPath(); ctx.moveTo(pad.l,gy); ctx.lineTo(w-pad.r,gy); ctx.stroke(); }
    ctx.beginPath();
    for(var i=0;i<pts.length;i++){ var x=X(pts[i].t), y=Y(pts[i].v); i?ctx.lineTo(x,y):ctx.moveTo(x,y); }
    var last=pts[pts.length-1];
    ctx.lineTo(X(last.t), h-pad.b); ctx.lineTo(X(pts[0].t), h-pad.b); ctx.closePath();
    var grd=ctx.createLinearGradient(0,pad.t,0,h-pad.b);
    grd.addColorStop(0,'rgba(130,167,255,0.22)'); grd.addColorStop(1,'rgba(130,167,255,0)');
    ctx.fillStyle=grd; ctx.fill();
    ctx.beginPath();
    for(i=0;i<pts.length;i++){ x=X(pts[i].t); y=Y(pts[i].v); i?ctx.lineTo(x,y):ctx.moveTo(x,y); }
    ctx.strokeStyle=this.color; ctx.lineWidth=2; ctx.lineJoin='round'; ctx.lineCap='round'; ctx.stroke();
    var tipX=X(last.t), tipY=Y(last.v);
    ctx.beginPath(); ctx.arc(tipX,tipY,8,0,Math.PI*2); ctx.fillStyle='rgba(130,167,255,0.15)'; ctx.fill();
    ctx.beginPath(); ctx.arc(tipX,tipY,3.5,0,Math.PI*2); ctx.fillStyle='#fff'; ctx.fill();
    ctx.beginPath(); ctx.arc(tipX,tipY,2.2,0,Math.PI*2); ctx.fillStyle=this.color; ctx.fill();
  };

  function spark(canvas){
    var raw=canvas.getAttribute('data-spark')||'[]';
    var data; try{data=JSON.parse(raw);}catch(e){return;}
    if(!data.length) return;
    var dpr=Math.min(window.devicePixelRatio||1,2);
    var w=96, h=28;
    canvas.width=w*dpr; canvas.height=h*dpr; canvas.style.width=w+'px'; canvas.style.height=h+'px';
    var ctx=canvas.getContext('2d'); ctx.setTransform(dpr,0,0,dpr,0,0);
    var mn=Math.min.apply(null,data), mx=Math.max.apply(null,data); if(mx===mn) mx=mn+1;
    ctx.beginPath();
    for(var i=0;i<data.length;i++){
      var x=i/(data.length-1||1)*(w-2)+1;
      var y=h-3-((data[i]-mn)/(mx-mn))*(h-6);
      i?ctx.lineTo(x,y):ctx.moveTo(x,y);
    }
    ctx.strokeStyle='rgba(130,167,255,0.85)'; ctx.lineWidth=1.5; ctx.lineJoin='round'; ctx.stroke();
  }

  var chart=null;
  function bootChart(){
    var host=document.getElementById('mainChart'); if(!host) return;
    var data=parseData();
    var series=data.series||[];
    if(series.length && series[0].time<1e10){
      var base=Date.now()-series.length*86400000;
      series=series.map(function(p,i){return {time:base+i*86400000, value:p.value};});
    }
    if(!chart) chart=new Liveline(host,{window:1209600,color:'#82a7ff'});
    else chart.resize();
    chart.setData(series, 1209600);
    document.querySelectorAll('.cv .wins .w').forEach(function(btn){
      btn.onclick=function(){
        document.querySelectorAll('.cv .wins .w').forEach(function(b){b.classList.remove('on');});
        btn.classList.add('on');
        var secs=+btn.getAttribute('data-secs');
        chart.setData(series, secs);
      };
    });
  }

  function bootsparks(){document.querySelectorAll('.cv canvas.spark').forEach(spark);}

  function animateSimple(){bootChart(); bootsparks();}
  window.setView=function(v){
    root.setAttribute('data-view',v);
    if(!isDemo){try{localStorage.setItem('fleetView',v);}catch(e){}}
    if(v==='simple') animateSimple();
    window.scrollTo(0,0);
  };
  if(!isDemo){var saved=null;try{saved=localStorage.getItem('fleetView');}catch(e){} if(saved) root.setAttribute('data-view',saved);}
  if(root.getAttribute('data-view')==='simple'){ window.addEventListener('load', animateSimple); }
})();
</script>


</body>
</html>
HTML

chmod 644 "$tmp"
mv -f "$tmp" "$OUTPUT_FILE"
