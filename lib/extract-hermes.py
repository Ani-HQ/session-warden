#!/usr/bin/env python3
"""Extract a human-readable transcript from a Hermes agent state.db.

Emits the same rough shape as lib/extract.sh (USER:/ASSISTANT:/→ tool lines)
so lib/memory.sh can summarize it.

Usage:
  extract-hermes.py <hermes-home> [--session-id ID] [--all-active]

Default: most recently updated open session (ended_at IS NULL), else newest.
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from pathlib import Path


def tool_line(tool_calls_raw: str | None, tool_name: str | None) -> list[str]:
    lines: list[str] = []
    if tool_name and not tool_calls_raw:
        lines.append(f"  → {tool_name}")
        return lines
    if not tool_calls_raw:
        return lines
    try:
        calls = json.loads(tool_calls_raw)
    except Exception:
        return lines
    if not isinstance(calls, list):
        calls = [calls]
    for call in calls:
        if not isinstance(call, dict):
            continue
        fn = call.get("function") or {}
        name = fn.get("name") or call.get("name") or tool_name or "tool"
        args_raw = fn.get("arguments") or call.get("arguments") or {}
        if isinstance(args_raw, str):
            try:
                args = json.loads(args_raw)
            except Exception:
                args = {"_raw": args_raw[:120]}
        elif isinstance(args_raw, dict):
            args = args_raw
        else:
            args = {}
        detail = ""
        for key in ("file_path", "path", "command", "query", "pattern"):
            if args.get(key):
                val = str(args[key])
                if key == "command":
                    detail = f" `{val[:100]}`"
                else:
                    detail = f" {val[:160]}"
                break
        lines.append(f"  → {name}{detail}")
    return lines


def pick_session(con: sqlite3.Connection, session_id: str | None, all_active: bool) -> list[str]:
    """Prefer the open session with the newest message activity / most turns.

    Hermes cron / scorecard wakes create many short open sessions; ordering by
    started_at alone often hands off a 2-message stub instead of the live chat.
    """
    cur = con.cursor()
    if session_id:
        return [session_id]
    # Substantive sessions (>=5 msgs) beat short cron/scorecard stubs even when
    # the stub started more recently. Among peers, prefer newest activity.
    order = """
            ORDER BY CASE WHEN COALESCE(m.n, 0) >= 5 THEN 1 ELSE 0 END DESC,
                     COALESCE(m.last_ts, 0) DESC,
                     COALESCE(m.n, 0) DESC,
                     COALESCE(s.message_count, 0) DESC,
                     COALESCE(s.started_at, 0) DESC
    """
    join = """
            FROM sessions s
            LEFT JOIN (
              SELECT session_id, MAX(timestamp) AS last_ts, COUNT(*) AS n
              FROM messages
              WHERE COALESCE(active, 1) = 1
              GROUP BY session_id
            ) m ON m.session_id = s.id
    """
    if all_active:
        rows = cur.execute(
            f"SELECT s.id {join} WHERE COALESCE(s.archived, 0) = 0 AND s.ended_at IS NULL {order}"
        ).fetchall()
        return [r[0] for r in rows]
    row = cur.execute(
        f"SELECT s.id {join} WHERE COALESCE(s.archived, 0) = 0 AND s.ended_at IS NULL {order} LIMIT 1"
    ).fetchone()
    if row:
        return [row[0]]
    row = cur.execute(f"SELECT s.id {join} {order} LIMIT 1").fetchone()
    return [row[0]] if row else []


def extract_session(con: sqlite3.Connection, session_id: str) -> list[str]:
    cur = con.cursor()
    rows = cur.execute(
        """
        SELECT role, content, tool_calls, tool_name
        FROM messages
        WHERE session_id = ? AND COALESCE(active, 1) = 1
        ORDER BY id ASC
        """,
        (session_id,),
    ).fetchall()
    out: list[str] = []
    for role, content, tool_calls, tool_name in rows:
        text = (content or "").strip()
        if role == "user" and text:
            out.append(f"USER: {text}")
        elif role == "assistant":
            if text:
                out.append(f"ASSISTANT: {text}")
            out.extend(tool_line(tool_calls, tool_name))
        elif role == "tool":
            name = tool_name or "tool"
            snippet = text.replace("\n", " ")[:160]
            out.append(f"  → {name} result: {snippet}")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("hermes_home", type=Path)
    ap.add_argument("--session-id")
    ap.add_argument("--all-active", action="store_true")
    ap.add_argument("--print-session-id", action="store_true",
                    help="print chosen session id on stderr")
    args = ap.parse_args()
    db = args.hermes_home / "state.db"
    if not db.is_file():
        print(f"extract-hermes: no state.db at {db}", file=sys.stderr)
        return 1
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        sids = pick_session(con, args.session_id, args.all_active)
        if not sids:
            print("extract-hermes: no sessions", file=sys.stderr)
            return 2
        lines: list[str] = []
        for sid in sids:
            if args.print_session_id:
                print(sid, file=sys.stderr)
            if len(sids) > 1:
                lines.append(f"# session {sid}")
            lines.extend(extract_session(con, sid))
        if not lines:
            return 3
        sys.stdout.write("\n".join(lines) + "\n")
        return 0
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
