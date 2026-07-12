#!/usr/bin/env python3
"""harvest-work.py — extract a compact sample of an agent's REAL work.

Reads an OpenClaw agent's session transcripts and emits a bounded, human- and
judge-readable digest of what the agent actually did in the recent window:
the prompts it received and the outputs it produced. Used by fleet-review.sh
to score real work (not synthetic benchmark tasks).

Session files are JSON Lines: a `{"type":"session",...}` header followed by
`{"type":"message","message":{"role":...,"content":...}}` rows. Assistant
content is a list of blocks (text / tool_use); user content is a string.

Usage: harvest-work.py <sessions_dir> [--days N] [--max-chars N]
Prints:
  #SESSIONS <count-in-window>
  #LAST <iso-timestamp-of-most-recent-session or ->
  <digest text, most-recent session first, capped at max-chars>
Exit 0 always (empty digest + #SESSIONS 0 means dormant).
"""
import sys, os, json, glob, time, argparse

def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("sessions_dir")
    p.add_argument("--days", type=int, default=7)
    p.add_argument("--max-chars", type=int, default=12000)
    return p.parse_args()

def block_text(content):
    """Flatten an assistant `content` (str or list of blocks) to readable text."""
    if isinstance(content, str):
        return content.strip()
    if not isinstance(content, list):
        return ""
    out = []
    for b in content:
        if not isinstance(b, dict):
            continue
        t = b.get("type")
        if t == "text":
            txt = (b.get("text") or "").strip()
            if txt:
                out.append(txt)
        elif t == "tool_use":
            name = b.get("name", "tool")
            out.append(f"[used tool: {name}]")
        elif t == "tool_result":
            out.append("[tool result]")
    return "\n".join(out).strip()

def session_records(path):
    recs = []
    try:
        with open(path, "r", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                recs.append(o)
    except Exception:
        return []
    return recs

ROUTINE_ACKS = {"ok", "okay", "done", "noted", "got it", "ack", "thanks", "👍", "sure"}

def is_routine(text):
    """A no-op turn: the agent correctly decided nothing was needed. This is
    good filtering, not idleness — but a wall of it drowns the real work, so we
    collapse runs of it into a single counted line."""
    t = text.strip()
    up = t.upper()
    if up in ("NO_REPLY", "NOREPLY", "NONE", "NO REPLY", ""):
        return True
    if len(t) <= 14 and t.lower().strip(".!") in ROUTINE_ACKS:
        return True
    return False

def digest_session(recs):
    """Render one session as trimmed ask->did exchanges, collapsing runs of
    routine no-op turns so substantive work isn't buried."""
    # Pair each assistant turn with the most recent preceding user ask.
    pairs = []            # (ask_first_line_or_None, did_text)
    pending_ask = None
    for o in recs:
        if o.get("type") != "message":
            continue
        msg = o.get("message", o)
        if not isinstance(msg, dict):
            continue
        role = msg.get("role")
        text = block_text(msg.get("content"))
        if not text:
            continue
        if role == "user":
            pending_ask = text.splitlines()[0][:240]
        elif role == "assistant":
            pairs.append((pending_ask, text))
            pending_ask = None

    lines = []
    routine_run = 0
    def flush_routine():
        nonlocal routine_run
        if routine_run:
            lines.append(f"  · [{routine_run} routine pass(es) — agent correctly took no action]")
            routine_run = 0
    for ask, did in pairs:
        if is_routine(did):
            routine_run += 1
            continue
        flush_routine()
        if ask:
            lines.append(f"  ↳ ASK: {ask}")
        lines.append(f"  ● DID: {did[:900]}")
    flush_routine()
    return lines

def main():
    a = parse_args()
    cutoff = time.time() - a.days * 86400
    files = [p for p in glob.glob(os.path.join(a.sessions_dir, "*.jsonl"))
             if "trajectory-path" not in os.path.basename(p)]
    # de-dupe: a session may have both X.jsonl and X.trajectory.jsonl; prefer
    # the plain .jsonl, fall back to trajectory. Key on the uuid stem.
    by_stem = {}
    for p in files:
        base = os.path.basename(p)
        stem = base.split(".")[0]
        is_traj = ".trajectory.jsonl" in base
        # prefer non-trajectory
        if stem not in by_stem or (by_stem[stem][1] and not is_traj):
            by_stem[stem] = (p, is_traj)
    recent = []
    for p, _ in by_stem.values():
        try:
            mt = os.path.getmtime(p)
        except OSError:
            continue
        if mt >= cutoff:
            recent.append((mt, p))
    recent.sort(reverse=True)  # newest first

    print(f"#SESSIONS {len(recent)}")
    if recent:
        last_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(recent[0][0]))
        print(f"#LAST {last_iso}")
    else:
        print("#LAST -")
        return 0

    budget = a.max_chars
    for mt, p in recent:
        recs = session_records(p)
        lines = digest_session(recs)
        if not lines:
            continue
        header = f"\n=== session {time.strftime('%Y-%m-%d %H:%M', time.gmtime(mt))} ==="
        chunk = header + "\n" + "\n".join(lines)
        if len(chunk) > budget:
            chunk = chunk[:budget] + "\n  … (truncated)"
        print(chunk)
        budget -= len(chunk)
        if budget <= 0:
            print("\n… (older sessions omitted — sample budget reached)")
            break
    return 0

if __name__ == "__main__":
    sys.exit(main())
