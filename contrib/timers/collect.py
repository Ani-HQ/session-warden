#!/usr/bin/env python3
"""Collect recurring scheduled loops (systemd user timers + crontab entries).

Emits ~/session-warden/state/timers/timers.json, consumed by:
  - contrib/fleet-live/collect.py   (public loops only, curated labels)
  - contrib/health-dashboard/generate.sh (all loops, internal detail)

Read-only. Fast enough to run inline from either generator.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path

HOME = Path(os.environ.get("HOME", str(Path.home())))
WARDEN = Path(os.environ.get("WARDEN_HOME", str(HOME / "session-warden")))
OUT = WARDEN / "state" / "timers" / "timers.json"
NOW = datetime.now(timezone.utc).replace(microsecond=0)
NOW_MS = int(NOW.timestamp() * 1000)

SYSTEMD_TIMERS = ["snapshot", "dream-cycle", "reflect", "scorecard", "fleet-review", "eval-memory", "harvest"]

# curated public-safe presentation; anything not listed here is internal-only
PUBLIC = {
    "zara-rundown":  {"label": "morning rundown",     "agent": "zara",  "cadence": "daily"},
    "inbox-watch":   {"label": "inbox watch",         "agent": "zara",  "cadence": "every 5 min"},
    "aria-support-watch": {"label": "support inbox sweep", "agent": "dash", "cadence": "every 10 min"},
    "daily-standup": {"label": "daily standup",       "agent": "dash",  "cadence": "weekdays"},
    "snapshot":      {"label": "state snapshot",      "agent": "fleet", "cadence": "every 30 min"},
    "dream-cycle":   {"label": "dream cycle",         "agent": "fleet", "cadence": "nightly"},
    "reflect":       {"label": "reflection pass",     "agent": "fleet", "cadence": "nightly"},
    "scorecard":     {"label": "revenue scorecard",   "agent": "fleet", "cadence": "weekly"},
    "fleet-review":  {"label": "fleet review",        "agent": "fleet", "cadence": "weekly"},
    "eval-memory":   {"label": "memory eval",         "agent": "fleet", "cadence": "weekly"},
    "harvest":       {"label": "lesson harvest",      "agent": "fleet", "cadence": "weekly"},
}

# internal attribution for loops not in PUBLIC
AGENT_OF = {
    "fleet-payroll-refresh": "ops", "fleet-live-refresh": "ops", "health-dashboard-refresh": "ops",
    "sync-codex-auth": "ops", "autoapply-reminder": "ops",
    "aria-support-watch": "dash", "daily-standup": "dash",
    "zara-rundown": "zara", "inbox-watch": "zara",
    "warden-cleanup": "warden", "mcp-supervisor": "warden", "warden-context-sync": "warden",
    "session-warden": "warden", "session-warden-30s": "warden", "session-warden-reap": "warden",
    "session-warden-reap-30s": "warden", "session-warden-doctor": "warden", "warden-worktree-gc": "warden",
    "planck-sync": "planck", "planck-focus": "planck", "planck-renew": "planck",
    "planck-gamification": "planck", "planck-weekly": "planck",
    "capexodus-daily": "capexodus", "capexodus-weekly": "capexodus",
    "capexodus-monthly": "capexodus", "capexodus-quarterly": "capexodus",
}

# last-run proxy: log file mtimes for crontab jobs
LOG_OF = {
    "zara-rundown": "/tmp/morning-rundown.log",
    "inbox-watch": "/tmp/inbox-watch.log",
    "aria-support-watch": "/tmp/aria-watch.log",
    "daily-standup": "/tmp/daily-standup.log",
    "health-dashboard-refresh": "/tmp/health-dashboard.log",
    "fleet-live-refresh": "/tmp/fleet-live.log",
    "fleet-payroll-refresh": "/tmp/costs.log",
    "sync-codex-auth": str(HOME / ".openclaw" / "logs" / "sync-codex-auth.log"),
    "planck-sync": "/tmp/planck-cron.log",
    "planck-focus": "/tmp/planck-cron.log",
    "planck-renew": "/tmp/planck-cron.log",
    "planck-gamification": "/tmp/planck-cron.log",
    "planck-weekly": "/tmp/planck-cron.log",
}


def run(cmd: list[str], timeout: int = 20) -> str:
    try:
        return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL, timeout=timeout)
    except Exception:
        return ""


def human(dt: datetime | None) -> str | None:
    if dt is None:
        return None
    delta = dt - NOW
    secs = int(delta.total_seconds())
    past = secs < 0
    secs = abs(secs)
    if secs < 90:
        s = f"{secs}s"
    elif secs < 3600:
        s = f"{secs // 60}m"
    elif secs < 86400:
        s = f"{secs // 3600}h"
    else:
        s = f"{secs // 86400}d"
    return f"{s} ago" if past else f"in {s}"


def ms(dt: datetime | None) -> int | None:
    return int(dt.timestamp() * 1000) if dt else None


# ---------------------------------------------------------------- systemd
TS_RE = re.compile(r"[A-Z][a-z]{2} \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [A-Z]+")


def parse_systemd_ts(raw: str) -> datetime | None:
    raw = raw.strip()
    if not raw or raw in ("n/a", "0"):
        return None
    try:
        return datetime.strptime(raw, "%a %Y-%m-%d %H:%M:%S %Z").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def list_timers_next() -> dict[str, datetime]:
    """unit -> next elapse, parsed from list-timers (NextElapseUSecRealtime is
    empty for some units on this systemd version)."""
    out: dict[str, datetime] = {}
    raw = run(["systemctl", "--user", "list-timers", "--all", "--no-legend", "--no-pager"])
    for line in raw.splitlines():
        m = re.search(r"([\w.-]+\.timer)\b", line)
        ts = TS_RE.search(line)
        if m and ts:
            dt = parse_systemd_ts(ts.group(0))
            if dt:
                out[m.group(1)] = dt
    return out


def systemd_loops() -> list[dict]:
    loops = []
    nexts = list_timers_next()
    for name in SYSTEMD_TIMERS:
        out = run(["systemctl", "--user", "show", f"{name}.timer",
                   "--property=LastTriggerUSec,ActiveState"])
        props = dict(
            line.split("=", 1) for line in out.splitlines() if "=" in line
        )
        active = props.get("ActiveState", "") == "active"
        nxt = nexts.get(f"{name}.timer") if active else None
        last = parse_systemd_ts(props.get("LastTriggerUSec", ""))
        pub = PUBLIC.get(name)
        loops.append({
            "id": name,
            "source": "systemd",
            "label": (pub or {}).get("label", name.replace("-", " ")),
            "agent": (pub or {}).get("agent", AGENT_OF.get(name, "fleet")),
            "cadence": (pub or {}).get("cadence", "scheduled"),
            "schedule": f"{name}.timer",
            "detail": f"{name}.service" if active else "timer inactive",
            "last": ms(last), "next": ms(nxt),
            "lastHuman": human(last), "nextHuman": human(nxt),
            "public": bool(pub),
            "missing": not active,
        })
    return loops


# ----------------------------------------------------------------- crontab
def field_match(field: str, value: int, lo: int, hi: int) -> bool:
    for part in field.split(","):
        part = part.strip()
        if not part:
            continue
        step = 1
        if "/" in part:
            part, st = part.split("/", 1)
            try:
                step = int(st)
            except ValueError:
                return True  # unparseable: assume match rather than hide
        if part == "*":
            start, end = lo, hi
        elif "-" in part:
            a, b = part.split("-", 1)
            try:
                start, end = int(a), int(b)
            except ValueError:
                return True
        else:
            try:
                if value == int(part):
                    return True
                continue
            except ValueError:
                return True
        if start <= value <= end and (value - start) % step == 0:
            return True
    return False


def next_cron(expr: str, limit_days: int = 400) -> datetime | None:
    fields = expr.split()
    if len(fields) != 5:
        return None
    fmin, fhour, fdom, fmon, fdow = fields
    t = NOW.replace(second=0) + timedelta(minutes=1)
    end = NOW + timedelta(days=limit_days)
    while t <= end:
        dow = (t.weekday() + 1) % 7  # cron: 0/7 = Sunday
        dom_star = fdom == "*"
        dow_star = fdow == "*"
        dom_ok = field_match(fdom, t.day, 1, 31)
        dow_ok = field_match(fdow.replace("7", "0"), dow, 0, 6)
        day_ok = (dom_ok or dow_ok) if (not dom_star and not dow_star) else (dom_ok and dow_ok)
        if (
            field_match(fmin, t.minute, 0, 59)
            and field_match(fhour, t.hour, 0, 23)
            and day_ok
            and field_match(fmon, t.month, 1, 12)
        ):
            return t
        t += timedelta(minutes=1)
    return None


def cron_id(schedule_rest: str, comment: str) -> str:
    if comment:
        return comment.strip().split()[0]
    m = re.search(r"([\w.-]+\.(?:sh|mjs|py))\b", schedule_rest)
    if m:
        return m.group(1).rsplit(".", 1)[0]
    m = re.search(r"https?://([\w.-]+)(/[\w/-]*)?", schedule_rest)
    if m:
        return m.group(1).split(".")[0] + (m.group(2) or "").replace("/", "-").strip("-")
    return schedule_rest.strip().split()[-1][:24] if schedule_rest.strip() else "job"


def cron_detail(rest: str) -> str:
    m = re.search(r"([\w.-]+\.(?:sh|mjs|py))\b", rest)
    if m:
        return m.group(1)
    m = re.search(r"(?:POST|GET)\s+https?://([\w.-]+)(/[\w/-]*)?", rest)
    if m:
        return f"{m.group(1)}{m.group(2) or ''}"
    return re.sub(r"\s+", " ", rest)[:48]


ID_BY_SCRIPT = {  # basename overrides (comment tags are unreliable prose)
    "daily-standup.sh": "daily-standup",
    "morning-rundown.sh": "zara-rundown",
    "watch.mjs": "inbox-watch",
    "aria-watch.mjs": "aria-support-watch",
    "sync-codex-auth.sh": "sync-codex-auth",
}


def crontab_loops() -> list[dict]:
    loops = []
    for line in run(["crontab", "-l"]).splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" in line.split()[0]:
            continue
        comment = ""
        if "#" in line:
            line, comment = line.split("#", 1)
            line = line.strip()
        tokens = line.split(None, 5)
        if len(tokens) < 6:
            continue
        expr, rest = " ".join(tokens[:5]), tokens[5]
        if rest.startswith("sleep"):  # 30s-offset duplicates of the same job
            continue
        script = re.search(r"([\w.-]+\.(?:sh|mjs|py))\b", rest)
        cid = ID_BY_SCRIPT.get(script.group(1)) if script else None
        if not cid:
            cid = cron_id(rest, comment)
        if "capexodus" in rest:
            m = re.search(r"sources[^a-zA-Z0-9]+(\w+)", rest)
            cid = "capexodus-" + (m.group(1) if m else "job")
        elif "planck" in rest:
            m = re.search(r"/api/cron/([\w-]+)", rest)
            slug = {"sync": "sync", "focus-schedule": "focus", "renew-watches": "renew",
                    "gamification": "gamification", "weekly-digest": "weekly"}
            cid = "planck-" + slug.get(m.group(1) if m else "", "job")
        pub = PUBLIC.get(cid)
        nxt = next_cron(expr)
        last = None
        logf = LOG_OF.get(cid)
        if logf and os.path.exists(logf):
            last = datetime.fromtimestamp(os.path.getmtime(logf), tz=timezone.utc).replace(microsecond=0)
        loops.append({
            "id": cid,
            "source": "crontab",
            "label": (pub or {}).get("label", cid.replace("-", " ")),
            "agent": (pub or {}).get("agent", AGENT_OF.get(cid, "ops")),
            "cadence": (pub or {}).get("cadence", expr),
            "schedule": expr,
            "detail": cron_detail(rest),
            "last": ms(last), "next": ms(nxt),
            "lastHuman": human(last), "nextHuman": human(nxt),
            "public": bool(pub),
            "missing": False,
        })
    return loops


def main() -> None:
    loops = systemd_loops() + crontab_loops()
    loops.sort(key=lambda l: (l["next"] is None, l["next"] or 0))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    tmp = OUT.with_suffix(".tmp")
    tmp.write_text(json.dumps({"generatedAt": NOW_MS, "loops": loops}, indent=1) + "\n")
    tmp.replace(OUT)
    print(f"wrote {OUT} loops={len(loops)} public={sum(1 for l in loops if l['public'])}")


if __name__ == "__main__":
    main()
