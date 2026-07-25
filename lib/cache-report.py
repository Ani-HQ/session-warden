#!/usr/bin/env python3
"""cache-report.py — per-agent prompt-cache hit rate from OpenClaw transcripts.

Reads each agent's session JSONLs (the same files fleet-review harvests) and
sums the usage counters OpenClaw persists on every assistant message:
`input` (uncached prompt tokens), `cacheRead`, `cacheWrite`, `output`.
Hit rate is the share of prompt tokens served from cache:

    hit = cacheRead / (input + cacheRead + cacheWrite)

A prefix mutation (model swap, MCP tool-list change, injected timestamp)
reverts calls to full-price input tokens with no error anywhere; a falling
hit rate is the only place it shows before the bill.

Usage: cache-report.py <agents_base_dir> [--days N] [--agents a,b,c] [--json]

<agents_base_dir> is the OpenClaw agents root (e.g. ~/.openclaw/agents).
Without --agents, any direct subdirectory containing sessions/*.jsonl is
included. `*.trajectory.jsonl` siblings are skipped (no API usage rows).

Plain output is TSV, one row per agent:
  agent  hit_pct  cache_read  cache_write  input  output  calls  last_ts
hit_pct is '-' for agents with no prompt tokens in the window.
Exit 0 always; unreadable files and torn lines are skipped, never fatal.
"""
import sys, os, json, glob, time, argparse
from datetime import datetime, timezone


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("agents_base_dir")
    p.add_argument("--days", type=int, default=7)
    p.add_argument("--agents", default="", help="comma-separated allowlist")
    p.add_argument("--json", action="store_true")
    return p.parse_args()


def record_epoch(o):
    """Best-effort epoch seconds for one JSONL record, else None."""
    ts = o.get("timestamp")
    if isinstance(ts, str):
        try:
            return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
        except ValueError:
            pass
    msg = o.get("message")
    if isinstance(msg, dict):
        ms = msg.get("timestamp")
        if isinstance(ms, (int, float)) and ms > 0:
            return ms / 1000.0
    return None


def uint(v):
    return v if isinstance(v, int) and v >= 0 else 0


def scan_agent(sessions_dir, since):
    tot = {"input": 0, "cache_read": 0, "cache_write": 0, "output": 0}
    calls = 0
    last = None
    for path in glob.glob(os.path.join(sessions_dir, "*.jsonl")):
        if path.endswith(".trajectory.jsonl"):
            continue
        # Skip files last touched before the window: nothing inside can be newer.
        try:
            if os.path.getmtime(path) < since:
                continue
        except OSError:
            continue
        try:
            with open(path, "r", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        o = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if o.get("type") != "message":
                        continue
                    msg = o.get("message")
                    if not isinstance(msg, dict) or msg.get("role") != "assistant":
                        continue
                    usage = msg.get("usage")
                    if not isinstance(usage, dict):
                        continue
                    ts = record_epoch(o)
                    if ts is not None and ts < since:
                        continue
                    row = {
                        "input": uint(usage.get("input")),
                        "cache_read": uint(usage.get("cacheRead")),
                        "cache_write": uint(usage.get("cacheWrite")),
                        "output": uint(usage.get("output")),
                    }
                    if not any(row.values()):
                        continue  # delivery mirrors etc. log all-zero usage
                    for k, v in row.items():
                        tot[k] += v
                    calls += 1
                    if ts is not None and (last is None or ts > last):
                        last = ts
        except OSError:
            continue
    return tot, calls, last


def hit_pct(tot):
    denom = tot["input"] + tot["cache_read"] + tot["cache_write"]
    if denom == 0:
        return None
    return round(100.0 * tot["cache_read"] / denom, 1)


def main():
    args = parse_args()
    base = os.path.expanduser(args.agents_base_dir)
    since = time.time() - args.days * 86400

    if args.agents:
        agents = [a.strip() for a in args.agents.split(",") if a.strip()]
    else:
        agents = sorted(
            d for d in (os.listdir(base) if os.path.isdir(base) else [])
            if glob.glob(os.path.join(base, d, "sessions", "*.jsonl"))
        )

    rows = []
    fleet = {"input": 0, "cache_read": 0, "cache_write": 0, "output": 0}
    for agent in agents:
        tot, calls, last = scan_agent(os.path.join(base, agent, "sessions"), since)
        for k in fleet:
            fleet[k] += tot[k]
        rows.append({
            "agent": agent,
            "hit_pct": hit_pct(tot),
            "cache_read": tot["cache_read"],
            "cache_write": tot["cache_write"],
            "input": tot["input"],
            "output": tot["output"],
            "calls": calls,
            "last_ts": (
                datetime.fromtimestamp(last, tz=timezone.utc)
                .strftime("%Y-%m-%dT%H:%M:%SZ") if last else None
            ),
        })

    if args.json:
        json.dump({
            "window_days": args.days,
            "generated": int(time.time()),
            "agents": rows,
            "fleet": {**fleet, "hit_pct": hit_pct(fleet)},
        }, sys.stdout)
        print()
    else:
        for r in rows:
            print("\t".join(str(r[k]) if r[k] is not None else "-"
                            for k in ("agent", "hit_pct", "cache_read",
                                      "cache_write", "input", "output",
                                      "calls", "last_ts")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
