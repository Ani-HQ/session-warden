#!/usr/bin/env bash
# health-dashboard/generate.sh — render a static ops dashboard for the agent fleet.
#
# Gathers (all read-only, every source optional):
#   - session-warden doctor summary
#   - systemd user services + timers
#   - latest eval / scorecard reports
#   - lessons pipeline counts (pending / applied / skill drafts)
#   - gbrain stats + reflect/harvest/dream-cycle last runs
#   - scan.log health (rotations, backoffs, last 24h)
#   - last daily standup output
#
# Output: $OUTPUT_FILE (default /var/www/health/index.html), written atomically.
# Intended to run from cron every 10 minutes:
#   */10 * * * * /opt/health-dashboard/generate.sh
set -u

# ---------------------------------------------------------------- environment
export HOME="${HOME:-/home/$(id -un)}"
export PATH="$HOME/.bun/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
# cron has no user dbus session; point systemctl --user at the running one
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

WARDEN="$HOME/session-warden"
STATE="$WARDEN/state"
OPENCLAW="$HOME/.openclaw"
OUTPUT_FILE="${OUTPUT_FILE:-/var/www/health/index.html}"
NOW_UTC="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
CUTOFF_24H="$(date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo '')"

SERVICES=(openclaw-gateway hermes-carolyn-gateway hermes-midi-gateway hermes-baymax-gateway knockknock)
TIMERS=(reflect harvest scorecard eval-memory dream-cycle snapshot)

# ------------------------------------------------------------------- helpers
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# pill CLASS TEXT
pill() { printf '<span class="pill %s">%s</span>' "$1" "$2"; }

# md2html: tiny markdown renderer (headings, tables, paragraphs) for REPORT.md
md2html() {
  esc | awk '
    function flush_tbl() { if (in_tbl) { print "</table></div>"; in_tbl = 0 } }
    /^\|/ {
      n = split($0, c, "|")
      # skip separator rows like |---|---|
      row = $0; gsub(/[-| :]/, "", row)
      if (row == "") next
      if (!in_tbl) { print "<div class=\"tblwrap\"><table>"; in_tbl = 1; hdr = 1 }
      tag = hdr ? "th" : "td"
      printf "<tr>"
      for (i = 2; i < n; i++) {
        v = c[i]; gsub(/^ +| +$/, "", v)
        printf "<%s>%s</%s>", tag, v, tag
      }
      print "</tr>"
      hdr = 0
      next
    }
    { flush_tbl() }
    /^### /  { print "<h4>" substr($0, 5) "</h4>"; next }
    /^## /   { print "<h4>" substr($0, 4) "</h4>"; next }
    /^# /    { next }  # top-level title: section card already has one
    /^[ \t]*$/ { next }
    { gsub(/`/, ""); print "<p class=\"md\">" $0 "</p>" }
    END { flush_tbl() }
  '
}

# tail_esc FILE N — last N lines, escaped, or empty
tail_esc() { [ -r "$1" ] && tail -n "$2" "$1" 2>/dev/null | esc; }

overall_red=0
overall_amber=0

# ------------------------------------------------------------- warden doctor
doctor_out="$(timeout 90 "$WARDEN/bin/doctor.sh" 2>&1 || true)"
doctor_ok=$(printf '%s\n' "$doctor_out" | grep -c '\[ok\]' || true)
doctor_warn=$(printf '%s\n' "$doctor_out" | grep -c '\[warn\]' || true)
doctor_fail=$(printf '%s\n' "$doctor_out" | grep -ci '\[fail\]' || true)
doctor_summary="$(printf '%s\n' "$doctor_out" | grep -E '^(HEALTHY|UNHEALTHY|DEGRADED)' | tail -1)"
[ -z "$doctor_summary" ] && doctor_summary="doctor.sh unavailable"
if [ "${doctor_fail:-0}" -gt 0 ]; then doctor_pill=$(pill red "FAIL"); overall_red=1
elif [ "${doctor_warn:-0}" -gt 0 ]; then doctor_pill=$(pill amber "WARN"); overall_amber=1
elif [ "${doctor_ok:-0}" -gt 0 ]; then doctor_pill=$(pill green "HEALTHY")
else doctor_pill=$(pill gray "N/A"); fi

# ------------------------------------------------------------------ services
services_rows=""
for s in "${SERVICES[@]}"; do
  st="$(systemctl --user is-active "$s" 2>/dev/null || true)"
  [ -z "$st" ] && st="unknown"
  case "$st" in
    active)   p=$(pill green "active") ;;
    unknown)  p=$(pill gray "unknown"); overall_amber=1 ;;
    *)        p=$(pill red "$st"); overall_red=1 ;;
  esac
  services_rows+="<tr><td class=\"name\">$s</td><td>$p</td></tr>"
done

# -------------------------------------------------------------------- timers
timers_raw="$(systemctl --user list-timers --all --no-legend --no-pager 2>/dev/null || true)"
timers_rows=""
for t in "${TIMERS[@]}"; do
  line="$(printf '%s\n' "$timers_raw" | grep -E "\\b${t}\\.timer" | head -1)"
  if [ -n "$line" ]; then
    next_fire="$(printf '%s' "$line" | grep -oE '[A-Z][a-z]{2} [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [A-Z]+' | head -1)"
    [ -z "$next_fire" ] && next_fire="—"
    timers_rows+="<tr><td class=\"name\">${t}</td><td class=\"mono\">${next_fire}</td><td>$(pill green scheduled)</td></tr>"
  else
    timers_rows+="<tr><td class=\"name\">${t}</td><td class=\"mono\">—</td><td>$(pill gray missing)</td></tr>"
  fi
done

# --------------------------------------------------------------------- evals
evals_html=""
eval_report="$(ls -1d "$STATE"/evals/*/ 2>/dev/null | sort | awk '{print $0 "REPORT.md"}' | xargs -r ls 2>/dev/null | tail -1)"
if [ -n "$eval_report" ] && [ -r "$eval_report" ]; then
  evals_html="<p class=\"src mono\">$(basename "$(dirname "$eval_report")")/REPORT.md</p>$(md2html < "$eval_report")"
else
  # fall back to newest rates.tsv if a run exists but hasn't produced a report
  rates="$(ls -1 "$STATE"/evals/*/rates.tsv 2>/dev/null | sort | tail -1)"
  if [ -n "$rates" ] && [ -s "$rates" ]; then
    evals_html="<p class=\"src mono\">$(basename "$(dirname "$rates")")/rates.tsv</p><pre>$(tail_esc "$rates" 20)</pre>"
  else
    evals_html="<p class=\"empty\">No eval report found.</p>"
  fi
fi

# ----------------------------------------------------------------- scorecard
scorecard_html=""
sc_report="$(ls -1 "$STATE"/scorecard/*/REPORT.md 2>/dev/null | sort | tail -1)"
if [ -n "$sc_report" ] && [ -r "$sc_report" ]; then
  scorecard_html="<p class=\"src mono\">$(basename "$(dirname "$sc_report")")/REPORT.md</p>$(md2html < "$sc_report")"
else
  scores="$(ls -1 "$STATE"/scorecard/*/scores.tsv 2>/dev/null | sort | tail -1)"
  if [ -n "$scores" ] && [ -s "$scores" ]; then
    n_agents=$(awk -F'\t' '{print $1}' "$scores" | sort -u | wc -l | tr -d ' ')
    n_tasks=$(wc -l < "$scores" | tr -d ' ')
    scorecard_html="<p class=\"src mono\">$(basename "$(dirname "$scores")")/scores.tsv</p><p class=\"md\"><span class=\"mono\">$n_tasks</span> scored task(s) across <span class=\"mono\">$n_agents</span> agent(s). No REPORT.md yet (dry run?).</p><pre>$(cut -f1-4 "$scores" | column -t -s$'\t' 2>/dev/null | esc)</pre>"
  else
    scorecard_html="<p class=\"empty\">No scorecard report found.</p>"
  fi
fi

# ----------------------------------------------------------- lessons pipeline
lessons_rows=""
total_pending=0
for d in "$OPENCLAW"/agents/*/; do
  agent="$(basename "$d")"
  [ -d "$d/memory" ] || continue
  case "$agent" in TEMPLATES|'{{agentId}}') continue ;; esac
  pending=$(ls -1 "$d"memory/pending-lessons-*.md 2>/dev/null | wc -l | tr -d ' ')
  applied=$(ls -1 "$d"memory/applied/ 2>/dev/null | wc -l | tr -d ' ')
  [ "$pending" = 0 ] && [ "$applied" = 0 ] && continue
  total_pending=$((total_pending + pending))
  if [ "$pending" -gt 0 ]; then pp=$(pill amber "$pending pending"); else pp=$(pill green "0 pending"); fi
  lessons_rows+="<tr><td class=\"name\">$agent</td><td>$pp</td><td class=\"mono\">$applied applied</td></tr>"
done
[ -z "$lessons_rows" ] && lessons_rows="<tr><td colspan=\"3\" class=\"empty\">No lessons activity.</td></tr>"
drafts=$(find "$OPENCLAW"/skills-pending "$OPENCLAW"/agents/*/skills-pending -type f 2>/dev/null | wc -l | tr -d ' ')

# -------------------------------------------------------------------- gbrain
gbrain_out="$(timeout 30 gbrain stats 2>/dev/null || true)"
[ -z "$gbrain_out" ] && gbrain_out="gbrain unavailable"
last_reflect="$(tail -1 "$STATE/reflect.log" 2>/dev/null | esc)"
last_harvest="$(tail -1 "$STATE/harvest.log" 2>/dev/null | esc)"
last_dream="$(journalctl --user -u dream-cycle.service -n 20 --no-pager -o cat 2>/dev/null | grep -Ei 'finished|failed|starting' | tail -1 | esc)"
[ -z "$last_dream" ] && last_dream="$(printf '%s\n' "$timers_raw" | grep dream-cycle | head -1 | esc)"

# --------------------------------------------------------------- scan health
# BACKOFF in the last hour = live problem (amber, degrades overall status).
# BACKOFF only in the 24h tail = recent history worth seeing, but quiet now
# (gray, informational) — a resolved storm should not hold the badge amber
# for a day after the fix.
scan_log="$STATE/scan.log"
CUTOFF_1H="$(date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -v-1H '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)"
rot_24h=0; backoff_24h=0; backoff_1h=0
if [ -r "$scan_log" ] && [ -n "$CUTOFF_24H" ]; then
  rot_24h=$(awk -v c="$CUTOFF_24H" -F'[][]' '$2 >= c && /ROTATE/ {n++} END {print n+0}' "$scan_log" 2>/dev/null || echo 0)
  backoff_24h=$(awk -v c="$CUTOFF_24H" -F'[][]' '$2 >= c && /BACKOFF/ {n++} END {print n+0}' "$scan_log" 2>/dev/null || echo 0)
  [ -n "$CUTOFF_1H" ] && backoff_1h=$(awk -v c="$CUTOFF_1H" -F'[][]' '$2 >= c && /BACKOFF/ {n++} END {print n+0}' "$scan_log" 2>/dev/null || echo 0)
fi
if [ "${backoff_1h:-0}" -gt 0 ]; then scan_pill=$(pill amber "$backoff_1h backoff/1h"); overall_amber=1
elif [ "${backoff_24h:-0}" -gt 0 ]; then scan_pill=$(pill gray "quiet now, $backoff_24h in 24h")
else scan_pill=$(pill green "no backoff"); fi
scan_tail="$(grep -E 'ROTATE|BACKOFF' "$scan_log" 2>/dev/null | tail -5 | esc)"
[ -z "$scan_tail" ] && scan_tail="(no ROTATE/BACKOFF lines in current scan.log)"

# ------------------------------------------------------------------- standup
standup="$(tail -n 12 /tmp/daily-standup.log 2>/dev/null | esc)"
[ -z "$standup" ] && standup="(no standup output yet)"

# ------------------------------------------------------------- overall pill
if [ "$overall_red" = 1 ]; then overall=$(pill red "ATTENTION")
elif [ "$overall_amber" = 1 ]; then overall=$(pill amber "DEGRADED")
else overall=$(pill green "ALL SYSTEMS GO"); fi

# ---------------------------------------------------------------------- html
tmp="$(mktemp "${OUTPUT_FILE}.XXXXXX" 2>/dev/null || mktemp)"
cat > "$tmp" <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="300">
<meta name="robots" content="noindex,nofollow">
<title>fleet health — ani-holdingco</title>
<style>
  :root {
    --bg:#050805; --panel:#070c07; --ink:#0a120a;
    --edge:#1d3a1d; --edge2:#2a512a;
    --text:#5dff7e; --dim:#2f8a44; --muted:#3d7a4d;
    --green:#5dff7e; --amber:#ffb347; --red:#ff5555; --gray:#5a7a5a;
    --glow:0 0 6px rgba(93,255,126,.45);
    --mono:ui-monospace,'SF Mono','JetBrains Mono',Menlo,Consolas,'Courier New',monospace;
  }
  * { box-sizing:border-box; margin:0; padding:0; }
  html { background:var(--bg); }
  body {
    background:var(--bg); color:var(--text);
    font:14px/1.55 var(--mono);
    padding:20px 16px 60px; max-width:1180px; margin:0 auto;
    text-shadow:var(--glow);
    position:relative;
  }
  /* CRT scanlines + vignette */
  body::before {
    content:""; position:fixed; inset:0; pointer-events:none; z-index:9999;
    background:repeating-linear-gradient(0deg, rgba(0,0,0,.22) 0 1px, transparent 1px 3px);
  }
  body::after {
    content:""; position:fixed; inset:0; pointer-events:none; z-index:9998;
    background:radial-gradient(ellipse at center, transparent 58%, rgba(0,0,0,.5) 100%);
  }
  ::selection { background:#1d3a1d; }
  header { margin-bottom:4px; }
  .banner { font-size:11px; line-height:1.15; color:var(--text); white-space:pre; overflow-x:auto; }
  .topline { display:flex; flex-wrap:wrap; align-items:center; gap:10px 16px; margin-top:8px; }
  h1 { font-size:15px; font-weight:700; letter-spacing:.12em; text-transform:uppercase; }
  h1 .dim { color:var(--dim); font-weight:400; }
  .stamp { color:var(--dim); font-size:12px; margin:6px 0 20px; }
  .cursor { display:inline-block; width:8px; height:14px; background:var(--text);
            vertical-align:-2px; animation:blink 1.1s steps(1) infinite; }
  @keyframes blink { 50% { opacity:0 } }
  .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(330px,1fr)); gap:14px; }
  .card {
    background:var(--panel); border:1px solid var(--edge); border-radius:0;
    padding:0 0 14px; overflow:hidden;
    box-shadow:inset 0 0 24px rgba(0,40,0,.35);
  }
  .card.wide { grid-column:1 / -1; }
  .card h2 {
    font-size:11px; font-weight:700; text-transform:uppercase; letter-spacing:.14em;
    color:var(--text); background:var(--ink); border-bottom:1px solid var(--edge);
    padding:8px 14px; margin-bottom:12px;
    display:flex; align-items:center; gap:8px;
  }
  .card h2::before { content:"█▓▒░ "; color:var(--dim); letter-spacing:0; text-shadow:none; }
  .card h2 .pill { margin-left:auto; }
  .card > *:not(h2) { margin-left:14px; margin-right:14px; }
  h4 { font-size:12px; color:var(--amber); margin:12px 0 6px; font-weight:700;
       text-transform:uppercase; letter-spacing:.08em; }
  h4::before { content:">> "; color:var(--dim); }
  .pill {
    display:inline-block; padding:0 2px; border-radius:0; background:none; border:none;
    font:700 11px/1.6 var(--mono); letter-spacing:.06em; white-space:nowrap;
  }
  .pill::before { content:"["; color:var(--dim); font-weight:400; }
  .pill::after  { content:"]"; color:var(--dim); font-weight:400; }
  .pill.green { color:var(--green); }
  .pill.amber { color:var(--amber); text-shadow:0 0 6px rgba(255,179,71,.5); }
  .pill.red   { color:var(--red);   text-shadow:0 0 6px rgba(255,85,85,.55); animation:blink 1.4s steps(1) infinite; }
  .pill.gray  { color:var(--gray);  text-shadow:none; }
  table { width:100%; border-collapse:collapse; font-size:13px; }
  th { text-align:left; color:var(--dim); font-weight:700; font-size:11px;
       text-transform:uppercase; letter-spacing:.1em; padding:5px 10px 5px 0;
       border-bottom:1px dashed var(--edge2); }
  td { padding:5px 10px 5px 0; border-bottom:1px dotted var(--edge); vertical-align:top; }
  tr:last-child td { border-bottom:none; }
  td.name { color:var(--text); font-size:13px; }
  td.name::before { content:"· "; color:var(--dim); }
  .mono { font-size:12.5px; color:var(--dim); }
  pre {
    font:12px/1.5 var(--mono); color:var(--dim); background:var(--ink);
    border:1px dashed var(--edge); border-radius:0; padding:10px 12px;
    overflow-x:auto; white-space:pre; margin-top:8px; text-shadow:none;
  }
  .tblwrap { overflow-x:auto; margin-top:6px; }
  .kv { display:flex; flex-wrap:wrap; gap:8px 22px; margin-bottom:8px; }
  .kv div { font-size:13px; }
  .kv b { font-weight:700; color:var(--text); display:block; font-size:18px; }
  .kv span { color:var(--dim); font-size:10px; text-transform:uppercase; letter-spacing:.1em; }
  p.md { font-size:13px; color:var(--muted); margin:4px 0; text-shadow:none; }
  p.src { color:var(--dim); font-size:11.5px; margin-bottom:2px; }
  p.empty { color:var(--dim); font-size:13px; }
  p.empty::before { content:"~ "; }
  .loglabel { color:var(--dim); font-size:11px; text-transform:uppercase; letter-spacing:.1em; margin-top:10px; }
  .loglabel::before { content:"$ "; }
  footer { margin-top:26px; color:var(--dim); font-size:11.5px; text-align:center; text-shadow:none; }
  @media (max-width:640px){
    body{padding:14px 8px 40px}
    .banner{font-size:7px}
    .card > *:not(h2){margin-left:10px;margin-right:10px}
  }
</style>
</head>
<body>
<header>
<div class="banner">╔═╗╦  ╔═╗╔═╗╔╦╗  ╦ ╦╔═╗╔═╗╦  ╔╦╗╦ ╦
╠╣ ║  ║╣ ║╣  ║   ╠═╣║╣ ╠═╣║   ║ ╠═╣
╚  ╩═╝╚═╝╚═╝ ╩   ╩ ╩╚═╝╩ ╩╩═╝ ╩ ╩ ╩</div>
<div class="topline">
  <h1>ai-holdingco <span class="dim">// fleet control</span></h1>
  $overall
</div>
</header>
<div class="stamp">sys.generated $NOW_UTC · autorefresh 300s <span class="cursor"></span></div>

<div class="grid">

  <div class="card">
    <h2>Warden Doctor $doctor_pill</h2>
    <div class="kv">
      <div><b>${doctor_ok:-0}</b><span>passed</span></div>
      <div><b>${doctor_warn:-0}</b><span>warnings</span></div>
      <div><b>${doctor_fail:-0}</b><span>failures</span></div>
    </div>
    <pre>$(printf '%s' "$doctor_summary" | esc)</pre>
  </div>

  <div class="card">
    <h2>Gateways &amp; Services</h2>
    <table><tr><th>unit</th><th>state</th></tr>$services_rows</table>
  </div>

  <div class="card">
    <h2>Timers</h2>
    <table><tr><th>timer</th><th>next fire</th><th></th></tr>$timers_rows</table>
  </div>

  <div class="card">
    <h2>Lessons Pipeline</h2>
    <div class="kv">
      <div><b>$total_pending</b><span>pending files</span></div>
      <div><b>$drafts</b><span>skill drafts</span></div>
    </div>
    <table><tr><th>agent</th><th>pending</th><th>applied batches</th></tr>$lessons_rows</table>
  </div>

  <div class="card wide">
    <h2>Latest Memory Evals</h2>
    $evals_html
  </div>

  <div class="card wide">
    <h2>Latest Scorecard</h2>
    $scorecard_html
  </div>

  <div class="card">
    <h2>GBrain</h2>
    <pre>$(printf '%s' "$gbrain_out" | esc)</pre>
  </div>

  <div class="card">
    <h2>Enrichment Pipelines</h2>
    <div class="loglabel">last reflect</div><pre>${last_reflect:-"(none)"}</pre>
    <div class="loglabel">last harvest</div><pre>${last_harvest:-"(none)"}</pre>
    <div class="loglabel">last dream-cycle</div><pre>${last_dream:-"(none)"}</pre>
  </div>

  <div class="card">
    <h2>Scan Health $scan_pill</h2>
    <div class="kv">
      <div><b>${rot_24h:-0}</b><span>rotations 24h</span></div>
      <div><b>${backoff_1h:-0}</b><span>backoffs 1h</span></div>
      <div><b>${backoff_24h:-0}</b><span>backoffs 24h</span></div>
    </div>
    <pre>$scan_tail</pre>
  </div>

  <div class="card">
    <h2>Daily Standup</h2>
    <pre>$standup</pre>
  </div>

</div>
<footer>── session-warden ▪ health-dashboard ▪ $(hostname -s 2>/dev/null) ──</footer>
</body>
</html>
HTML

chmod 644 "$tmp"
mv -f "$tmp" "$OUTPUT_FILE"
