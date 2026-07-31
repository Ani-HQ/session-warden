#!/usr/bin/env python3
"""Collect recurring scheduled loops (systemd user timers + crontab entries).

Emits ~/session-warden/state/timers/timers.json, consumed by:
  - contrib/fleet-live/collect.py   (public loops only, curated labels)
  - any internal dashboard of your own (all loops, full detail)

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
LABELS_JSON = Path(os.environ.get("TIMER_LABELS", str(WARDEN / "config" / "timers-labels.json")))
NOW = datetime.now(timezone.utc).replace(microsecond=0)
NOW_MS = int(NOW.timestamp() * 1000)

# session-warden's own loops — present in every install, safe to show publicly.
# Anything else defaults to internal-only until named in config/timers-labels.json
# (see config/timers-labels.json.example).
WARDEN_LOOPS = {
    "snapshot":              {"label": "state snapshot",   "agent": "warden", "cadence": "every 30 min", "public": True,
                              "desc": "Saves every agent's working state each half hour, so a crash or restart loses nothing."},
    "dream-cycle":           {"label": "dream cycle",      "agent": "warden", "cadence": "nightly",      "public": True,
                              "desc": "Nightly maintenance of the fleet's shared memory — merging, pruning, and backing it up."},
    "reflect":               {"label": "reflection pass",  "agent": "warden", "cadence": "nightly",      "public": True,
                              "desc": "Each night, every agent's recent work is distilled into short lessons it applies going forward."},
    "scorecard":             {"label": "model scorecard",  "agent": "warden", "cadence": "weekly",       "public": True,
                              "desc": "Weekly benchmark comparing the fleet's AI models on real tasks, so the best one wins."},
    "fleet-review":          {"label": "fleet review",     "agent": "warden", "cadence": "weekly",       "public": True,
                              "desc": "Weekly quality review of each agent's actual work, scored with a plain-English insight and one action."},
    "eval-memory":           {"label": "memory eval",      "agent": "warden", "cadence": "monthly",      "public": True,
                              "desc": "Monthly regression test confirming agent memory is still accurate and hasn't drifted."},
    "harvest":               {"label": "lesson harvest",   "agent": "warden", "cadence": "weekly",       "public": True,
                              "desc": "Weekly mining of workflows each agent repeated — they become draft skills waiting for approval."},
    "session-warden":        {"label": "session scan",     "agent": "warden", "cadence": "every 30s",
                              "desc": "Scans every agent session for problems and rotates the unhealthy ones."},
    "session-warden-reap":   {"label": "stall reaper",     "agent": "warden", "cadence": "every 30s",
                              "desc": "Backstop that catches silently hung agent sessions and restarts them."},
    "session-warden-doctor": {"label": "warden doctor",    "agent": "warden", "cadence": "every 5 min",
                              "desc": "The warden's self-check: verifies its own wiring and raises an alert when something is unhooked."},
    "warden-context-sync":   {"label": "context sync",     "agent": "warden", "cadence": "every 5 min",
                              "desc": "Keeps each agent's workspace context files in step with its live sessions."},
    "warden-cleanup":        {"label": "archive cleanup",  "agent": "warden", "cadence": "daily",
                              "desc": "Daily sweep that clears old archives and logs."},
    "warden-worktree-gc":    {"label": "worktree gc",      "agent": "warden", "cadence": "every 15 min",
                              "desc": "Cleans up finished task worktrees so disk and git state stay tidy."},
    "mcp-supervisor":        {"label": "mcp supervisor",   "agent": "warden", "cadence": "every 5 min",
                              "desc": "Keeps agent tool servers alive and restarts any that died."},
}


def load_labels() -> dict[str, dict]:
    """Built-in warden loops, overlaid with the operator's own config."""
    loops = {k: dict(v) for k, v in WARDEN_LOOPS.items()}
    try:
        user = json.loads(LABELS_JSON.read_text()).get("loops", {})
    except Exception:
        return loops
    for lid, cfg in user.items():
        if isinstance(cfg, dict):
            loops.setdefault(lid, {}).update(cfg)
    return loops


LOOPS = load_labels()

# ── loop descriptions ─────────────────────────────────────────────
# Resolution order: labels/built-ins → cache → one `claude -p` call on a cheap
# model, grounded in the loop's own schedule line so it cannot invent much.
# Model calls ride the operator's existing subscription (warden's premise) and
# happen once per loop ever; failures just leave the description blank.
DESC_CACHE = WARDEN / "state" / "timers" / "loop-desc.json"
DESC_MODEL = os.environ.get("WARDEN_LOOPDESC_MODEL", "haiku")
DESC_ENABLED = os.environ.get("WARDEN_LOOPDESC", "1") == "1"


def _load_desc_cache() -> dict:
    try:
        return json.loads(DESC_CACHE.read_text())
    except Exception:
        return {}


_desc_cache = _load_desc_cache()


def _generate_desc(loop: dict) -> str:
    prompt = (
        "One sentence, at most 18 words, plain English for a non-technical reader. "
        "Say what this scheduled job does and what to expect from it. Describe ONLY "
        "what is evident from the data below; if unsure, stay generic rather than "
        "inventing specifics. No quotes, no markdown.\n"
        f"Name: {loop.get('label') or loop.get('id')}\n"
        f"Owner: {loop.get('agent') or 'ops'}\n"
        f"Runs: {loop.get('cadence') or loop.get('schedule') or ''}\n"
        f"Full schedule entry: {loop.get('detail') or ''} {loop.get('schedule') or ''}"
    )
    try:
        out = subprocess.run(
            ["claude", "-p", "--model", DESC_MODEL, prompt],
            capture_output=True, text=True, timeout=45,
        ).stdout.strip().replace("\n", " ")
    except Exception:
        return ""
    return out if 0 < len(out) < 220 else ""


def resolve_desc(lid: str, loop: dict) -> str:
    d = (meta(lid).get("desc") or "").strip()
    if d:
        return d
    if lid in _desc_cache:
        return _desc_cache[lid]
    if not (DESC_ENABLED and loop.get("public")):
        return ""
    d = _generate_desc(loop)
    if d:
        _desc_cache[lid] = d
        try:
            DESC_CACHE.parent.mkdir(parents=True, exist_ok=True)
            DESC_CACHE.write_text(json.dumps(_desc_cache, indent=1, ensure_ascii=False) + "\n")
        except Exception:
            pass
    return d


def systemd_units() -> list[str]:
    """Timer units shipped in deploy/, plus any named in the labels config."""
    units = sorted(p.stem for p in (WARDEN / "deploy").glob("*.timer"))
    for lid, cfg in LOOPS.items():
        if cfg.get("source") == "systemd" and lid not in units:
            units.append(lid)
    return units


def meta(lid: str) -> dict:
    return LOOPS.get(lid, {})


def log_path(lid: str) -> str | None:
    p = meta(lid).get("log")
    return os.path.expanduser(p) if p else None


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
    for name in systemd_units():
        out = run(["systemctl", "--user", "show", f"{name}.timer",
                   "--property=LastTriggerUSec,ActiveState"])
        props = dict(
            line.split("=", 1) for line in out.splitlines() if "=" in line
        )
        active = props.get("ActiveState", "") == "active"
        nxt = nexts.get(f"{name}.timer") if active else None
        last = parse_systemd_ts(props.get("LastTriggerUSec", ""))
        m = meta(name)
        loops.append({
            "id": name,
            "source": "systemd",
            "label": m.get("label", name.replace("-", " ")),
            "agent": m.get("agent", "fleet"),
            "cadence": m.get("cadence", "scheduled"),
            "schedule": f"{name}.timer",
            "detail": f"{name}.service" if active else "timer inactive",
            "last": ms(last), "next": ms(nxt),
            "lastHuman": human(last), "nextHuman": human(nxt),
            "public": bool(m.get("public")),
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
        host = m.group(1).split(".")[0]
        path = (m.group(2) or "").strip("/").replace("/", "-")
        return f"{host}-{path}" if path else host
    return schedule_rest.strip().split()[-1][:24] if schedule_rest.strip() else "job"


def cron_detail(rest: str) -> str:
    m = re.search(r"([\w.-]+\.(?:sh|mjs|py))\b", rest)
    if m:
        return m.group(1)
    m = re.search(r"(?:POST|GET)\s+https?://([\w.-]+)(/[\w/-]*)?", rest)
    if m:
        return f"{m.group(1)}{m.group(2) or ''}"
    return re.sub(r"\s+", " ", rest)[:48]


def id_by_script() -> dict[str, str]:
    """script basename -> loop id, from the labels config.

    Crontab comment tags are free prose, so an explicit `script` in the config
    is the reliable way to pin a job to its label.
    """
    out = {}
    for lid, cfg in LOOPS.items():
        s = cfg.get("script")
        if s:
            out[s] = lid
    return out


ID_BY_SCRIPT = id_by_script()


def crontab_loops() -> list[dict]:
    loops = []
    seen: dict[str, int] = {}
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
        # several jobs can hit the same script or endpoint; keep ids unique so
        # rows stay distinguishable (tag the crontab line to name it properly)
        seen[cid] = seen.get(cid, 0) + 1
        if seen[cid] > 1:
            cid = f"{cid}-{seen[cid]}"
        m = meta(cid)
        nxt = next_cron(expr)
        last = None
        logf = log_path(cid)
        if logf and os.path.exists(logf):
            last = datetime.fromtimestamp(os.path.getmtime(logf), tz=timezone.utc).replace(microsecond=0)
        loops.append({
            "id": cid,
            "source": "crontab",
            "label": m.get("label", cid.replace("-", " ")),
            "agent": m.get("agent", "ops"),
            "cadence": m.get("cadence", expr),
            "schedule": expr,
            "detail": cron_detail(rest),
            "last": ms(last), "next": ms(nxt),
            "lastHuman": human(last), "nextHuman": human(nxt),
            "public": bool(m.get("public")),
            "missing": False,
        })
    return loops


def main() -> None:
    loops = systemd_loops() + crontab_loops()
    loops.sort(key=lambda l: (l["next"] is None, l["next"] or 0))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    tmp = OUT.with_suffix(".tmp")
    for l in loops:
        l["desc"] = resolve_desc(l.get("id", ""), l)
    tmp.write_text(json.dumps({"generatedAt": NOW_MS, "loops": loops}, indent=1) + "\n")
    tmp.replace(OUT)
    print(f"wrote {OUT} loops={len(loops)} public={sum(1 for l in loops if l['public'])}")


if __name__ == "__main__":
    main()
