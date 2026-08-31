#!/usr/bin/env python3
"""Collect redacted live fleet activity for the public fleet board."""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HOME = Path(os.environ.get("HOME", str(Path.home())))
OPENCLAW = HOME / ".openclaw"
WARDEN = Path(os.environ.get("WARDEN_HOME", str(HOME / "session-warden")))
OUT_DIR = Path(os.environ.get("FLEET_OUT", "/var/www/fleet"))

# Branding. Everything here is optional — leave it unset and the board renders
# unbranded rather than with somebody else's domain on it.
SITE = {
    "host": os.environ.get("FLEET_SITE", ""),            # e.g. ani.computer
    "url": os.environ.get("FLEET_SITE_URL", ""),         # e.g. https://ani.computer
    "note": os.environ.get("FLEET_FOOTER_NOTE", ""),     # e.g. private ops on health.ani.computer
}
ROSTER = WARDEN / "config" / "fleet-roster.tsv"
OPENCLAW_JSON = OPENCLAW / "openclaw.json"

ACTIVE_MINUTES = int(os.environ.get("FLEET_ACTIVE_MINUTES", "180"))
NOW = int(time.time() * 1000)

COSTS_JSON = Path(os.environ.get("COSTS_JSON", str(WARDEN / "state" / "costs" / "costs.json")))
TIMERS_COLLECT = WARDEN / "contrib" / "timers" / "collect.py"
TIMERS_JSON = Path(os.environ.get("TIMERS_JSON", str(WARDEN / "state" / "timers" / "timers.json")))

EMAIL_RE = re.compile(r"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}", re.I)
PHONE_RE = re.compile(r"(?<!\d)(?:\+?\d[\d\-\s().]{7,}\d)")
URL_RE = re.compile(r"https?://\S+", re.I)
SECRET_RE = re.compile(
    r"(?i)(api[_-]?key|token|secret|password|bearer|authorization|"
    r"sk-[a-z0-9]{10,}|ghp_[a-z0-9]{20,}|xox[baprs]-[a-z0-9-]+|AIza[0-9A-Za-z_-]{20,})"
)
DISCORD_ID_RE = re.compile(r"\b\d{17,20}\b")
PATH_RE = re.compile(r"(?:/home/\S+|~/\.openclaw/\S+|/[A-Za-z0-9._/-]{12,})")
EMAIL_HDR_RE = re.compile(r"(?im)^(from|to|cc|subject|date):\s*.+$")
MONEY_RE = re.compile(r"\$\s?\d[\d,]*(?:\.\d+)?")
HEARTBEAT_RE = re.compile(
    r"(?i)heartbeat|nothing to do|standing by|no new|on patrol|idle poll"
)


def run(cmd: list[str], timeout: int = 45) -> str:
    try:
        return subprocess.check_output(
            cmd, text=True, stderr=subprocess.DEVNULL, timeout=timeout
        )
    except Exception:
        return ""


def redact(text: str) -> str:
    if not text:
        return ""
    t = EMAIL_HDR_RE.sub("", text)
    t = EMAIL_RE.sub("[email]", t)
    t = PHONE_RE.sub("[phone]", t)
    t = URL_RE.sub("[link]", t)
    t = SECRET_RE.sub("[redacted]", t)
    t = DISCORD_ID_RE.sub("[id]", t)
    t = PATH_RE.sub("[path]", t)
    t = MONEY_RE.sub("[amount]", t)
    t = re.sub(r"`[^`]{0,80}`", "[code]", t)
    t = re.sub(r"\s+", " ", t).strip()
    return t


def tidy_quest(text: str) -> str:
    t = redact(text)
    for marker in (
        "INCOMPLETE:",
        "You just came back from a session restart",
        "PREVIOUS session",
        "Retry after the previous model",
        "OpenClaw runtime context",
        "<context>",
    ):
        if marker in t:
            t = t.split(marker)[0].strip()
    t = re.split(r"(?<=[.!?])\s+", t)[0] if t else ""
    t = t.strip(" -:\n\t\"'")
    if len(t) > 110:
        t = t[:107].rstrip() + "…"
    return t


def roster_rows() -> list[list[str]]:
    if not ROSTER.exists():
        return []
    rows = []
    for line in ROSTER.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = [p.strip() for p in line.split("\t")]
        if len(parts) >= 4:
            rows.append(parts)
    return rows


def short_role(role: str) -> str:
    return role.split(" — ")[0].split(" (")[0]


def load_roster_roles() -> dict[str, str]:
    return {r[0]: short_role(r[3]) for r in roster_rows()}


def load_board() -> list[tuple[str, str, str, str]]:
    """Agents to show on the public board, from config/fleet-roster.tsv.

    Columns: agent, team, channel, role[, board, title, blurb]. The last three
    are optional — a roster without them puts every agent on the board and
    falls back to the role for the title.
    """
    board = []
    for p in roster_rows():
        if len(p) > 4 and p[4].lower() not in ("1", "true", "yes", ""):
            continue
        title = p[5] if len(p) > 5 and p[5] else short_role(p[3])
        blurb = p[6] if len(p) > 6 and p[6] else p[3]
        board.append((p[0], p[1], title, blurb))
    return board


def load_models() -> dict[str, dict]:
    out: dict[str, dict] = {}
    if not OPENCLAW_JSON.exists():
        return out
    cfg = json.loads(OPENCLAW_JSON.read_text())
    for a in cfg.get("agents", {}).get("list", []):
        mid = a.get("id")
        m = a.get("model")
        if isinstance(m, str):
            primary, fallbacks = m, []
        elif isinstance(m, dict):
            primary = m.get("primary", "")
            fallbacks = m.get("fallbacks") or []
        else:
            continue
        out[mid] = {"primary": primary, "fallbacks": fallbacks}
    return out


def load_review() -> dict[str, dict]:
    reviews = sorted((WARDEN / "state" / "fleet-review").glob("*/review.json"))
    if not reviews:
        return {}
    data = json.loads(reviews[-1].read_text())
    return {a["agent"]: a for a in data.get("agents", [])}


def load_costs() -> dict:
    """Fleet payroll from contrib/costs/costs.py — public-safe aggregates only."""
    try:
        data = json.loads(COSTS_JSON.read_text())
    except Exception:
        return {}
    # stale payroll is worse than none
    if abs(NOW - int(data.get("generatedAt", 0))) > 6 * 3600 * 1000:
        return {}
    return data


def load_loops() -> list[dict]:
    """Recurring scheduled loops (contrib/timers/collect.py), public entries only."""
    if TIMERS_COLLECT.exists():
        run(["/usr/bin/python3", str(TIMERS_COLLECT)], timeout=30)
    try:
        data = json.loads(TIMERS_JSON.read_text())
    except Exception:
        return []
    if abs(NOW - int(data.get("generatedAt", 0))) > 6 * 3600 * 1000:
        return []
    loops = [l for l in data.get("loops", []) if l.get("public")]
    loops.sort(key=lambda l: (l.get("next") is None, l.get("next") or 0))
    return [
        {
            "agent": l.get("agent"),
            "label": l.get("label"),
            "cadence": l.get("cadence"),
            "desc": l.get("desc"),
            "last": l.get("last"),
            "next": l.get("next"),
        }
        for l in loops
    ]


def load_skills() -> dict[str, dict]:
    """What each agent has learned: live skills plus drafts the weekly harvest
    staged for approval. Slug names only — never file contents — so the public
    board can show capability growth without leaking how the sausage is made."""
    out: dict[str, dict] = {}
    pending_root = OPENCLAW / "skills-pending"
    for adir in sorted((OPENCLAW / "agents").glob("*")):
        aid = adir.name
        live = []
        for sk in sorted((adir / "skills").glob("*/SKILL.md")):
            name = sk.parent.name.replace("-", " ").replace("_", " ")
            try:
                added = int(sk.stat().st_mtime * 1000)
            except OSError:
                continue
            live.append({"name": redact(name), "added": added})
        live.sort(key=lambda s: -s["added"])
        pending = [
            redact(p.parent.name.replace("-", " ").replace("_", " "))
            for p in sorted((pending_root / aid).glob("*/SKILL.md"))
        ]
        if live or pending:
            out[aid] = {"count": len(live), "live": live[:8], "pending": pending[:6]}
    return out


def active_sessions() -> list[dict]:
    raw = run(
        [
            str(HOME / ".npm-global/bin/openclaw"),
            "sessions",
            "--all-agents",
            "--active",
            str(ACTIVE_MINUTES),
            "--json",
            "--limit",
            "100",
        ]
    )
    if not raw.strip():
        return []
    start = raw.find("{")
    if start < 0:
        return []
    try:
        data = json.loads(raw[start:])
    except json.JSONDecodeError:
        return []
    return data.get("sessions") or []


def latest_session_file(agent: str) -> Path | None:
    sess = OPENCLAW / "agents" / agent / "sessions"
    if not sess.is_dir():
        return None
    files = [
        p
        for p in sess.glob("*.jsonl")
        if ".trajectory" not in p.name and ".reset." not in p.name
    ]
    if not files:
        return None
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return files[0]


def extract_activity(agent: str) -> tuple[str, str]:
    f = latest_session_file(agent)
    if not f:
        return ("Standing by for the next brief.", "idle")
    last_user = ""
    last_asst = ""
    try:
        with open(f) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    o = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if o.get("type") != "message":
                    continue
                msg = o.get("message") or {}
                role = msg.get("role")
                content = msg.get("content")
                chunks: list[str] = []
                if isinstance(content, str):
                    chunks = [content]
                elif isinstance(content, list):
                    for part in content:
                        if isinstance(part, dict) and part.get("type") in (
                            "text",
                            "input_text",
                            "output_text",
                        ):
                            chunks.append(str(part.get("text") or ""))
                        elif isinstance(part, str):
                            chunks.append(part)
                text = " ".join(chunks).strip()
                if not text:
                    continue
                if role == "user":
                    last_user = text
                elif role == "assistant":
                    last_asst = text
    except OSError:
        return ("Standing by for the next brief.", "idle")

    def usable(text: str) -> bool:
        t = (text or "").strip()
        if not t:
            return False
        if t.upper() in {
            "CODEX FALLBACK OK",
            "CODEX AUTH OK",
            "OK",
            "DONE",
            "NO_REPLY",
            "YES",
            "NO",
        }:
            return False
        if t.startswith("[Retry after"):
            return False
        # too terse / low-signal for a public board
        if len(t) < 18 and " " not in t.strip("."):
            return False
        if re.fullmatch(r"(?i)yes[,.].*", t) and len(t) < 40:
            return False
        return True

    source = last_asst if usable(last_asst) else (last_user if usable(last_user) else "")
    if not source:
        return ("Standing by for the next brief.", "idle")
    if HEARTBEAT_RE.search(source) or "[OpenClaw heartbeat" in (last_user or ""):
        if usable(last_asst) and not HEARTBEAT_RE.search(last_asst):
            quest = tidy_quest(last_asst)
        else:
            quest = "On patrol — scanning for new work."
        return (quest or "On patrol — scanning for new work.", "patrol")
    quest = tidy_quest(source)
    if not quest or quest.upper() in {"NO_REPLY", "OK", "DONE"}:
        return ("Working a live session.", "active")
    if len(quest) < 12:
        return ("Working a live session.", "active")
    return (quest, "active")


def pretty_model(ref: str) -> str:
    if not ref:
        return "—"
    return ref.split("/")[-1].replace("claude-", "")


def status_for(age_ms: int | None, hint: str) -> str:
    if age_ms is None:
        return "dormant"
    mins = age_ms / 60000
    if mins <= 8 and hint == "active":
        return "questing"
    if mins <= 20 and hint in ("active", "patrol"):
        return "patrol" if hint == "patrol" else "questing"
    if mins <= ACTIVE_MINUTES:
        return "cooling"
    return "dormant"


def main() -> None:
    sessions = active_sessions()
    by_agent: dict[str, dict] = {}
    for s in sessions:
        aid = s.get("agentId")
        if not aid:
            continue
        prev = by_agent.get(aid)
        if not prev or (s.get("updatedAt") or 0) > (prev.get("updatedAt") or 0):
            by_agent[aid] = s

    models = load_models()
    review = load_review()
    roles = load_roster_roles()
    costs = load_costs()
    loops = load_loops()
    skills = load_skills()
    board = load_board()
    if not board:
        print(
            f"warning: no agents on the board — {ROSTER} is missing or empty "
            "(copy config/fleet-roster.tsv.example to get started)",
            file=sys.stderr,
        )
    cost_by_agent = {a["id"]: a for a in costs.get("agents", [])}

    agents = []
    feed = []
    online = 0
    for aid, team, title, blurb in board:
        s = by_agent.get(aid)
        quest, hint = extract_activity(aid)
        age = s.get("ageMs") if s else None
        provider = (s or {}).get("modelProvider")
        model = (s or {}).get("model") or pretty_model(
            (models.get(aid) or {}).get("primary", "")
        )
        status = status_for(age, hint)
        if status in ("questing", "patrol", "cooling"):
            online += 1
        fallback = bool(provider and provider in ("openai", "codex", "google"))
        if provider == "claude-cli":
            fallback = False
        rev = review.get(aid) or {}
        score = rev.get("score")
        sessions_n = rev.get("sessions") or 0
        role = roles.get(aid) or title
        c = cost_by_agent.get(aid) or {}
        wage = c.get("actualCost")
        worth = c.get("wouldCost")
        saved_pct = saved_amt = None
        if isinstance(wage, (int, float)) and isinstance(worth, (int, float)) and worth > 0:
            saved_pct = round(100 * (1 - wage / worth))
            saved_amt = round(worth - wage, 2)
        agents.append(
            {
                "id": aid,
                "name": aid.title(),
                "title": title,
                "role": role,
                "team": team,
                "blurb": blurb,
                "status": status,
                "quest": quest,
                "model": pretty_model(str(model)),
                "provider": provider or "—",
                "fallback": fallback,
                "ageMs": age,
                "score": score,
                "sessionsWeek": sessions_n,
                "xp": int(score) if isinstance(score, (int, float)) else None,
                "wage": wage,
                "worth": worth,
                "savedPct": saved_pct,
                "saved": saved_amt,
                "tokens": c.get("tokens"),
                "topModel": c.get("topModel"),
                "hitPct": (c.get("cache") or {}).get("hitPct"),
                "skills": skills.get(aid),
            }
        )
        if status in ("questing", "patrol") and quest:
            feed.append(
                {
                    "ts": NOW - int(age or 0),
                    "agent": aid,
                    "text": f"{aid} · {quest}",
                    "status": status,
                }
            )

    feed.sort(key=lambda x: x["ts"], reverse=True)
    totals = costs.get("totals") or {}
    window = costs.get("window") or {}
    econ = None
    if costs and totals:
        # work-delivered headline sums only the agents shown on the public
        # board so cards reconcile; actual payroll is the true flat bill
        # (which also covers work by recently retired agents this month).
        visible_would = sum(a.get("worth") or 0.0 for a in agents)
        visible_tokens = sum(a.get("tokens") or 0 for a in agents)
        actual = totals.get("actualCost")
        econ = {
            "windowLabel": window.get("label", ""),
            "daysElapsed": window.get("daysElapsed"),
            "tokens": visible_tokens,
            "cacheHitPct": (totals.get("cache") or {}).get("hitPct"),
            "wouldCost": round(visible_would, 2),
            "actualCost": actual,
            "savings": round(visible_would - (actual or 0), 2) if actual is not None else None,
            "savingsPct": round(100 * (1 - actual / visible_would), 1)
            if actual is not None and visible_would > 0
            else None,
            "plans": [
                {
                    "label": p.get("label"),
                    "monthlyUsd": p.get("monthlyUsd"),
                    "billed": p.get("billed"),
                    "used": p.get("poolWould"),
                }
                for p in (costs.get("plans") or {}).values()
            ],
        }
    payload = {
        "generatedAt": NOW,
        "generatedAtIso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "site": SITE,
        "stats": {
            "online": online,
            "total": len(board),
            "sessionsActive": len(sessions),
            "fallbackReady": True,
        },
        "econ": econ,
        "agents": agents,
        "loops": loops,
        "feed": feed[:24],
        "legend": {
            "questing": "Actively working a task right now",
            "patrol": "Heartbeat / scanning for new work",
            "cooling": "Recently active, catching breath",
            "dormant": "No recent session",
        },
        "note": (
            "Sensitive bits (emails, links, IDs, paths, amounts) are stripped. "
            "This is a spectator view, not a control panel."
        ),
    }

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    tmp = OUT_DIR / "live.json.tmp"
    tmp.write_text(json.dumps(payload, indent=2) + "\n")
    tmp.replace(OUT_DIR / "live.json")
    print(
        f"wrote {OUT_DIR / 'live.json'} agents={len(agents)} "
        f"online={online} feed={len(feed)}"
    )


if __name__ == "__main__":
    main()
