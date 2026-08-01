#!/usr/bin/env python3
"""Fleet payroll — per-agent cost ledger.

Scans OpenClaw session transcripts (main + rotated .reset files; trajectories
are skipped because their trace lines duplicate message usage), buckets token
usage per agent/model/day, and produces state/costs/costs.json:

  wouldCost  — what those tokens would cost at public API list prices
               (config/cost-rates.json)
  actualCost — what they actually cost: Claude Max / ChatGPT subscription
               dollars allocated pro-rata by each agent's share of that
               provider's would-cost pool, plus real API dollars for
               API-billed providers (Gemini).

Incremental: per-file aggregates are cached in state/costs/cache.json keyed by
mtime+size, so repeat runs only re-read files that changed.
"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

HOME = Path(os.environ.get("HOME", str(Path.home())))
OPENCLAW = Path(os.environ.get("WARDEN_OPENCLAW_HOME", str(HOME / ".openclaw")))
WARDEN = Path(os.environ.get("WARDEN_HOME", str(HOME / "session-warden")))
RATES_PATH = Path(os.environ.get("COST_RATES", str(WARDEN / "config" / "cost-rates.json")))
STATE_DIR = WARDEN / "state" / "costs"
CACHE_PATH = STATE_DIR / "cache.json"
OUT_PATH = Path(os.environ.get("COSTS_OUT", str(STATE_DIR / "costs.json")))

SKIP_MODELS = {"gateway-injected", "delivery-mirror", "acp-runtime", "", "?", "none"}


def provider_of(model: str) -> str:
    m = model.lower()
    if m.startswith("claude"):
        return "claude"
    if m.startswith("gpt") or m.startswith("o1") or m.startswith("o3") or m.startswith("o4"):
        return "openai"
    if m.startswith("gemini"):
        return "google"
    return "other"


class RateCard:
    def __init__(self, cfg: dict):
        self.models = cfg.get("models", {})
        self.fallbacks = cfg.get("fallbackByPrefix", {})
        self.providers = cfg.get("providers", {})
        self.plans = cfg.get("plans", {})

    def rates_for(self, model: str) -> tuple[float, float, float, float]:
        """Return (in, out, cacheRead, cacheWrite) prices per token."""
        r = self.models.get(model)
        if r is None:
            r = None
            best = -1
            for prefix, cand in self.fallbacks.items():
                if prefix != "default" and model.startswith(prefix) and len(prefix) > best:
                    r = cand
                    best = len(prefix)
            if r is None:
                r = self.fallbacks.get("default", {"in": 2.0, "out": 8.0})
        prov = self.providers.get(provider_of(model), {})
        pin = float(r.get("in", 0)) / 1e6
        pout = float(r.get("out", 0)) / 1e6
        cr_factor = float(prov.get("cacheReadFactor", 0.10))
        cw_factor = float(prov.get("cacheWriteFactor", 1.25))
        pcr = float(r.get("cacheRead", pin * 1e6 * cr_factor)) / 1e6 if "cacheRead" in r else pin * cr_factor
        pcw = float(r.get("cacheWrite", pin * 1e6 * cw_factor)) / 1e6 if "cacheWrite" in r else pin * cw_factor
        return pin, pout, pcr, pcw

    def billed(self, provider: str) -> str:
        return str(self.providers.get(provider, {}).get("billed", "api"))

    def plan_monthly(self, provider: str) -> float:
        return float(self.plans.get(provider, {}).get("monthlyUsd", 0))


def session_files() -> list[Path]:
    out = []
    for agent_dir in sorted(OPENCLAW.glob("agents/*/sessions")):
        if not agent_dir.is_dir():
            continue
        for p in agent_dir.iterdir():
            name = p.name
            if ".trajectory" in name:
                continue
            if ".jsonl" not in name:
                continue
            if not p.is_file():
                continue
            out.append(p)
    return out


def parse_file(path: Path) -> dict[str, list[int]]:
    """Return {(day|model): [input, output, cacheRead, cacheWrite]}."""
    buckets: dict[str, list[int]] = {}
    try:
        fh = open(path, "r", errors="replace")
    except OSError:
        return buckets
    with fh:
        for line in fh:
            if '"usage"' not in line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            if o.get("type") != "message":
                continue
            m = o.get("message") or {}
            u = m.get("usage") or {}
            i = int(u.get("input") or 0)
            ot = int(u.get("output") or 0)
            cr = int(u.get("cacheRead") or 0)
            cw = int(u.get("cacheWrite") or 0)
            if i + ot + cr + cw <= 0:
                continue
            model = str(m.get("model") or "").strip().lower()
            if model in SKIP_MODELS:
                continue
            day = str(o.get("timestamp") or "")[:10]
            if len(day) != 10 or day[4] != "-":
                continue
            key = f"{day}|{model}"
            b = buckets.get(key)
            if b is None:
                buckets[key] = [i, ot, cr, cw]
            else:
                b[0] += i
                b[1] += ot
                b[2] += cr
                b[3] += cw
    return buckets


def load_cache() -> dict:
    try:
        return json.loads(CACHE_PATH.read_text())
    except Exception:
        return {"version": 1, "files": {}}


def main() -> None:
    rates = RateCard(json.loads(RATES_PATH.read_text()))
    cache = load_cache()
    files_cache = cache.setdefault("files", {})

    # agent -> day|model -> [in,out,cr,cw]
    agg: dict[str, dict[str, list[int]]] = {}
    seen_paths = set()

    for p in session_files():
        agent = p.parent.parent.name
        sp = str(p)
        seen_paths.add(sp)
        try:
            st = p.stat()
        except OSError:
            continue
        ent = files_cache.get(sp)
        if ent and ent.get("mtime") == st.st_mtime and ent.get("size") == st.st_size:
            buckets = ent.get("buckets", {})
        else:
            buckets = parse_file(p)
            files_cache[sp] = {"mtime": st.st_mtime, "size": st.st_size, "buckets": buckets}
        dst = agg.setdefault(agent, {})
        for key, vals in buckets.items():
            b = dst.get(key)
            if b is None:
                dst[key] = list(vals)
            else:
                for i in range(4):
                    b[i] += vals[i]

    # drop cache entries for deleted files
    for sp in list(files_cache.keys()):
        if sp not in seen_paths:
            del files_cache[sp]

    now = time.time()
    month_label = time.strftime("%Y-%m", time.gmtime(now))
    month_name = time.strftime("%b %Y", time.gmtime(now))
    day_today = time.strftime("%Y-%m-%d", time.gmtime(now))
    days_elapsed = int(day_today[8:10])

    agents_out = []
    pool_would: dict[str, float] = {}
    per_agent_prov: dict[str, dict[str, dict]] = {}

    for agent, buckets in sorted(agg.items()):
        a_tokens = 0
        a_would = 0.0
        a_in = a_cr = a_cw = 0
        by_prov: dict[str, dict] = {}
        by_model_would: dict[str, float] = {}
        daily: dict[str, float] = {}
        for key, (i, ot, cr, cw) in buckets.items():
            day, model = key.split("|", 1)
            if not day.startswith(month_label):
                continue
            pin, pout, pcr, pcw = rates.rates_for(model)
            would = i * pin + ot * pout + cr * pcr + cw * pcw
            toks = i + ot + cr + cw
            prov = provider_of(model)
            a_tokens += toks
            a_would += would
            a_in += i
            a_cr += cr
            a_cw += cw
            by_model_would[model] = by_model_would.get(model, 0.0) + would
            daily[day] = daily.get(day, 0.0) + would
            pb = by_prov.setdefault(prov, {"tokens": 0, "would": 0.0})
            pb["tokens"] += toks
            pb["would"] += would
        if a_tokens == 0:
            continue
        per_agent_prov[agent] = by_prov
        for prov, pb in by_prov.items():
            pool_would[prov] = pool_would.get(prov, 0.0) + pb["would"]
        top_model = max(by_model_would.items(), key=lambda kv: kv[1])[0] if by_model_would else ""
        # Prompt-cache hit rate: share of prompt tokens served from cache.
        # A prefix mutation above the cache point (model swap, tool-list change,
        # timestamp churn) shows up here long before it shows up on the bill.
        a_prompt = a_in + a_cr + a_cw
        agents_out.append(
            {
                "id": agent,
                "tokens": a_tokens,
                "wouldCost": a_would,
                "topModel": top_model,
                "cache": {
                    "input": a_in,
                    "read": a_cr,
                    "write": a_cw,
                    "hitPct": round(100.0 * a_cr / a_prompt, 1) if a_prompt else None,
                },
                "byProvider": by_prov,
                "dailyWould": daily,
            }
        )

    # actual cost attribution
    total_actual = 0.0
    total_would = 0.0
    total_tokens = 0
    fleet_cache = {"input": 0, "read": 0, "write": 0}
    daily_totals: dict[str, float] = {}
    for a in agents_out:
        actual = 0.0
        by_prov_actual = {}
        for prov, pb in a["byProvider"].items():
            if rates.billed(prov) == "subscription":
                pool = pool_would.get(prov, 0.0)
                part = rates.plan_monthly(prov) * (pb["would"] / pool) if pool > 0 else 0.0
            else:
                part = pb["would"]
            by_prov_actual[prov] = {
                "tokens": pb["tokens"],
                "would": round(pb["would"], 4),
                "actual": round(part, 4),
            }
            actual += part
        a["byProvider"] = by_prov_actual
        a["wouldCost"] = round(a["wouldCost"], 2)
        a["actualCost"] = round(actual, 2)
        a["savings"] = round(a["wouldCost"] - actual, 2)
        total_actual += actual
        total_would += a["wouldCost"]
        total_tokens += a["tokens"]
        for k in fleet_cache:
            fleet_cache[k] += a["cache"][k]
        for day, w in a.pop("dailyWould").items():
            daily_totals[day] = daily_totals.get(day, 0.0) + w

    for a in agents_out:
        a["shareOfActual"] = round(a["actualCost"] / total_actual, 4) if total_actual > 0 else 0.0
    agents_out.sort(key=lambda a: -a["wouldCost"])

    plans_out = {}
    for prov, plan in rates.plans.items():
        plans_out[prov] = {
            "label": plan.get("label", prov),
            "monthlyUsd": rates.plan_monthly(prov),
            "billed": rates.billed(prov),
            "poolWould": round(pool_would.get(prov, 0.0), 2),
        }

    payload = {
        "generatedAt": int(now * 1000),
        "generatedAtIso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
        "window": {
            "kind": "month",
            "label": month_name,
            "month": month_label,
            "daysElapsed": days_elapsed,
        },
        "plans": plans_out,
        "totals": {
            "tokens": total_tokens,
            "wouldCost": round(total_would, 2),
            "actualCost": round(total_actual, 2),
            "savings": round(total_would - total_actual, 2),
            "savingsPct": round(100 * (1 - total_actual / total_would), 1) if total_would > 0 else 0.0,
            "cache": {
                **fleet_cache,
                "hitPct": round(
                    100.0 * fleet_cache["read"] / (fleet_cache["input"] + fleet_cache["read"] + fleet_cache["write"]),
                    1,
                )
                if (fleet_cache["input"] + fleet_cache["read"] + fleet_cache["write"])
                else None,
            },
            "dailyWould": sorted(daily_totals.items()),
        },
        "agents": agents_out,
    }

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = OUT_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, indent=1) + "\n")
    tmp.replace(OUT_PATH)
    CACHE_PATH.write_text(json.dumps(cache))
    print(
        f"costs ok: {len(agents_out)} agents, month={month_label}, "
        f"would=${total_would:.2f} actual=${total_actual:.2f} tokens={total_tokens:,}"
    )


if __name__ == "__main__":
    sys.exit(main())
