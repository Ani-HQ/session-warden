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
scan_log="$STATE/scan.log"
rot_24h=0; backoff_24h=0
if [ -r "$scan_log" ] && [ -n "$CUTOFF_24H" ]; then
  rot_24h=$(awk -v c="$CUTOFF_24H" -F'[][]' '$2 >= c && /ROTATE/ {n++} END {print n+0}' "$scan_log" 2>/dev/null || echo 0)
  backoff_24h=$(awk -v c="$CUTOFF_24H" -F'[][]' '$2 >= c && /BACKOFF/ {n++} END {print n+0}' "$scan_log" 2>/dev/null || echo 0)
fi
if [ "${backoff_24h:-0}" -gt 0 ]; then scan_pill=$(pill amber "$backoff_24h backoff"); overall_amber=1
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
    --bg:#0b0e14; --card:#12161f; --edge:#1f2633; --edge2:#2a3347;
    --text:#d7dde8; --muted:#78829a; --accent:#7aa2f7;
    --green:#10b981; --green-bg:rgba(16,185,129,.12);
    --amber:#f59e0b; --amber-bg:rgba(245,158,11,.12);
    --red:#ef4444;   --red-bg:rgba(239,68,68,.14);
    --gray:#6b7280;  --gray-bg:rgba(107,114,128,.15);
    --mono:ui-monospace,'SF Mono','JetBrains Mono',Menlo,Consolas,monospace;
  }
  * { box-sizing:border-box; margin:0; padding:0; }
  body {
    background:var(--bg); color:var(--text);
    font:15px/1.55 -apple-system,BlinkMacSystemFont,'Segoe UI',Inter,Roboto,sans-serif;
    padding:20px 16px 60px; max-width:1180px; margin:0 auto;
  }
  header { display:flex; flex-wrap:wrap; align-items:baseline; gap:10px 16px; margin-bottom:6px; }
  h1 { font-size:19px; font-weight:650; letter-spacing:.02em; }
  h1 .dim { color:var(--muted); font-weight:400; }
  .stamp { color:var(--muted); font-family:var(--mono); font-size:12px; margin-bottom:18px; }
  .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(330px,1fr)); gap:14px; }
  .card {
    background:var(--card); border:1px solid var(--edge); border-radius:10px;
    padding:16px 18px; overflow:hidden;
  }
  .card.wide { grid-column:1 / -1; }
  .card h2 {
    font-size:11px; font-weight:600; text-transform:uppercase; letter-spacing:.12em;
    color:var(--muted); margin-bottom:12px; display:flex; align-items:center; gap:8px;
  }
  .card h2 .pill { margin-left:auto; }
  h4 { font-size:13px; color:var(--accent); margin:12px 0 6px; font-weight:600; }
  .pill {
    display:inline-block; padding:2px 9px; border-radius:999px;
    font:600 11px/1.6 var(--mono); letter-spacing:.04em; white-space:nowrap;
  }
  .pill.green { color:var(--green); background:var(--green-bg); border:1px solid rgba(16,185,129,.35); }
  .pill.amber { color:var(--amber); background:var(--amber-bg); border:1px solid rgba(245,158,11,.35); }
  .pill.red   { color:var(--red);   background:var(--red-bg);   border:1px solid rgba(239,68,68,.4); }
  .pill.gray  { color:var(--gray);  background:var(--gray-bg);  border:1px solid rgba(107,114,128,.35); }
  table { width:100%; border-collapse:collapse; font-size:13.5px; }
  th { text-align:left; color:var(--muted); font-weight:600; font-size:11px;
       text-transform:uppercase; letter-spacing:.08em; padding:5px 10px 5px 0; border-bottom:1px solid var(--edge2); }
  td { padding:6px 10px 6px 0; border-bottom:1px solid var(--edge); vertical-align:top; }
  tr:last-child td { border-bottom:none; }
  td.name { font-family:var(--mono); font-size:13px; color:var(--text); }
  .mono { font-family:var(--mono); font-size:12.5px; color:#a8b3c9; }
  pre {
    font:12px/1.5 var(--mono); color:#9aa5bc; background:#0d1119;
    border:1px solid var(--edge); border-radius:7px; padding:10px 12px;
    overflow-x:auto; white-space:pre; margin-top:8px;
  }
  .tblwrap { overflow-x:auto; margin-top:6px; }
  .kv { display:flex; flex-wrap:wrap; gap:8px 20px; margin-bottom:8px; }
  .kv div { font-size:13px; }
  .kv b { font-family:var(--mono); font-weight:600; color:var(--text); display:block; font-size:17px; }
  .kv span { color:var(--muted); font-size:11px; text-transform:uppercase; letter-spacing:.08em; }
  p.md { font-size:13px; color:#b6bfd2; margin:4px 0; }
  p.src { color:var(--muted); font-size:11.5px; margin-bottom:2px; }
  p.empty { color:var(--muted); font-size:13px; font-style:italic; }
  .loglabel { color:var(--muted); font-size:11px; text-transform:uppercase; letter-spacing:.08em; margin-top:10px; }
  footer { margin-top:26px; color:var(--muted); font-size:11.5px; font-family:var(--mono); text-align:center; }
  @media (max-width:640px){ body{padding:14px 10px 40px} .card{padding:13px 14px} }
</style>
</head>
<body>
<header>
  <h1>FLEET HEALTH <span class="dim">/ ai-holdingco</span></h1>
  $overall
</header>
<div class="stamp">generated $NOW_UTC · refreshes every 5 min</div>

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
    <h2>Scan Health (24h) $scan_pill</h2>
    <div class="kv">
      <div><b>${rot_24h:-0}</b><span>rotations 24h</span></div>
      <div><b>${backoff_24h:-0}</b><span>backoffs 24h</span></div>
    </div>
    <pre>$scan_tail</pre>
  </div>

  <div class="card">
    <h2>Daily Standup</h2>
    <pre>$standup</pre>
  </div>

</div>
<footer>session-warden · health-dashboard · $(hostname -s 2>/dev/null)</footer>
</body>
</html>
HTML

chmod 644 "$tmp"
mv -f "$tmp" "$OUTPUT_FILE"
