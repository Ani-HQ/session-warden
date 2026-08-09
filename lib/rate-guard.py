#!/usr/bin/env python3
"""rate-guard — demote rate-limited providers in openclaw.json until reset.

Invoked by bin/rate-guard.sh. Prints a single JSON object on stdout for the
shell wrapper to drive Telegram notify:

  {"action":"noop"|"demoted"|"restored"|"status", ...}

Demotion window rules:
  - `active.resetsAt` is frozen at demote time (when THIS outage ends).
  - Never overwrite it with the next weekly window from a healthy usage payload.
  - `lastRestored.demotionResetsAt` records that same frozen stamp so a usage
    probe failure only re-demotes if we restored *before* that window ended.
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

WARDEN_HOME = Path(os.environ.get("WARDEN_HOME", Path.home() / "session-warden"))
OPENCLAW_HOME = Path(os.environ.get("WARDEN_OPENCLAW_HOME", Path.home() / ".openclaw"))
CFG = OPENCLAW_HOME / "openclaw.json"
STATE_DIR = WARDEN_HOME / "state" / "rate-guard"
STATE = STATE_DIR / "state.json"
BASELINE = STATE_DIR / "baseline-models.json"
CLAUDE_CRED = Path.home() / ".claude" / ".credentials.json"
HANDOFF_BIN = WARDEN_HOME / "bin" / "handoff.sh"
UTIL_THRESHOLD = float(os.environ.get("WARDEN_RATE_GUARD_UTIL_PCT", "95"))
GRACE_SEC = int(os.environ.get("WARDEN_RATE_GUARD_RESTORE_GRACE_SEC", "120"))
HANDOFF_TIMEOUT = int(os.environ.get("WARDEN_HANDOFF_TIMEOUT", "120"))


def emit(obj: dict) -> None:
    print(json.dumps(obj), flush=True)


def load_json(path: Path, default=None):
    if not path.is_file():
        return default
    return json.loads(path.read_text())


def save_json(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(obj, indent=2) + "\n")
    tmp.replace(path)


def load_cfg() -> dict:
    return json.loads(CFG.read_text())


def save_cfg(cfg: dict) -> None:
    bak = CFG.with_name(
        f"openclaw.json.bak-rateguard-{time.strftime('%Y%m%d-%H%M%S')}"
    )
    shutil.copy2(CFG, bak)
    tmp = CFG.with_suffix(".tmp")
    tmp.write_text(json.dumps(cfg, indent=2) + "\n")
    tmp.replace(CFG)
    baks = sorted(CFG.parent.glob("openclaw.json.bak-rateguard-*"), reverse=True)
    for old in baks[8:]:
        old.unlink(missing_ok=True)


def maybe_restart_gateway() -> None:
    """Model chain edits hot-reload in OpenClaw — do NOT restart by default.

    A full gateway restart kills Claude CLI live sessions mid-chat and the next
    turn looks like a brand-new conversation even though the session jsonl is
    intact. Opt in only with WARDEN_RATE_GUARD_RESTART_GATEWAY=1.
    """
    if os.environ.get("WARDEN_RATE_GUARD_RESTART_GATEWAY", "0") != "1":
        return
    subprocess.run(
        ["systemctl", "--user", "restart", "openclaw-gateway.service"],
        capture_output=True,
        timeout=90,
        check=False,
    )


def snapshot_models(cfg: dict) -> dict:
    out = {
        "defaults": cfg.get("agents", {}).get("defaults", {}).get("model"),
        "agents": {},
    }
    for a in cfg.get("agents", {}).get("list", []):
        if a.get("id") and a.get("model"):
            out["agents"][a["id"]] = a["model"]
    return out


def restore_models(cfg: dict, snap: dict) -> None:
    if snap.get("defaults"):
        cfg.setdefault("agents", {}).setdefault("defaults", {})["model"] = snap["defaults"]
    by_id = {a.get("id"): a for a in cfg.get("agents", {}).get("list", [])}
    for aid, model in (snap.get("agents") or {}).items():
        if aid in by_id:
            by_id[aid]["model"] = model


def primary_of(model_obj) -> str | None:
    if isinstance(model_obj, dict):
        return model_obj.get("primary")
    if isinstance(model_obj, str):
        return model_obj
    return None


def agent_ids(cfg: dict) -> list[str]:
    return [a["id"] for a in cfg.get("agents", {}).get("list", []) if a.get("id")]


def resolve_primary(cfg: dict, agent_id: str) -> str | None:
    for a in cfg.get("agents", {}).get("list", []):
        if a.get("id") == agent_id and a.get("model"):
            return primary_of(a.get("model"))
    return primary_of(cfg.get("agents", {}).get("defaults", {}).get("model"))


def agents_with_primary_change(before: dict, after: dict) -> list[str]:
    changed = []
    for aid in agent_ids(after):
        if resolve_primary(before, aid) != resolve_primary(after, aid):
            changed.append(aid)
    return changed


def restore_one_agent_model(target: dict, source: dict, agent_id: str) -> None:
    """Copy one agent's model object from source cfg into target cfg."""
    src_by = {a.get("id"): a for a in source.get("agents", {}).get("list", [])}
    tgt_by = {a.get("id"): a for a in target.get("agents", {}).get("list", [])}
    if agent_id not in tgt_by or agent_id not in src_by:
        return
    if "model" in src_by[agent_id]:
        tgt_by[agent_id]["model"] = copy.deepcopy(src_by[agent_id]["model"])
    elif "model" in tgt_by[agent_id]:
        del tgt_by[agent_id]["model"]


def handoff_agents(agent_ids_: list[str], reason: str) -> tuple[list[str], list[str]]:
    """Run bin/handoff.sh for each agent. Returns (ok, failed)."""
    ok: list[str] = []
    failed: list[str] = []
    if not agent_ids_:
        return ok, failed
    if not HANDOFF_BIN.is_file():
        # Missing handoff binary — fail closed so we don't rewrite without checkpoint.
        return [], list(agent_ids_)
    for aid in agent_ids_:
        try:
            r = subprocess.run(
                [str(HANDOFF_BIN), aid, reason],
                capture_output=True,
                text=True,
                timeout=HANDOFF_TIMEOUT,
                check=False,
                env={**os.environ, "WARDEN_HOME": str(WARDEN_HOME)},
            )
            if r.returncode == 0:
                ok.append(aid)
            else:
                failed.append(aid)
        except Exception:
            failed.append(aid)
    return ok, failed


def is_provider(model: str, provider: str) -> bool:
    m = (model or "").lower()
    if provider == "claude":
        return m.startswith("anthropic/") or m.startswith("claude-cli/")
    if provider == "openai":
        return m.startswith("openai/") or m.startswith("codex/")
    if provider == "google":
        return m.startswith("google/")
    return False


def demote_provider(cfg: dict, provider: str) -> int:
    changed = 0

    def rewrite(model_obj: dict) -> dict:
        nonlocal changed
        if not isinstance(model_obj, dict):
            return model_obj
        primary = model_obj.get("primary")
        fbs = list(model_obj.get("fallbacks") or [])
        chain = ([primary] if primary else []) + fbs
        keep, demoted = [], []
        for m in chain:
            (demoted if is_provider(m, provider) else keep).append(m)
        if not keep or not demoted:
            return model_obj
        new = {"primary": keep[0], "fallbacks": keep[1:] + demoted}
        if new != {"primary": primary, "fallbacks": fbs}:
            changed += 1
        return new

    defaults = cfg.setdefault("agents", {}).setdefault("defaults", {})
    if defaults.get("model"):
        defaults["model"] = rewrite(defaults["model"])
    for a in cfg.get("agents", {}).get("list", []):
        if a.get("model"):
            a["model"] = rewrite(a["model"])
    return changed


def fetch_claude_usage() -> dict | None:
    try:
        cred = json.loads(CLAUDE_CRED.read_text())
        tok = (cred.get("claudeAiOauth") or {}).get("accessToken")
        if not tok:
            return None
        req = urllib.request.Request(
            "https://api.anthropic.com/api/oauth/usage",
            headers={
                "Authorization": f"Bearer {tok}",
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": "session-warden-rate-guard",
            },
        )
        with urllib.request.urlopen(req, timeout=12) as r:
            return json.loads(r.read().decode())
    except Exception:
        return None


def parse_reset(iso: str | None) -> float | None:
    if not iso:
        return None
    try:
        return datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def fmt_reset(ts: float | None) -> str:
    if not ts:
        return "unknown"
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


def claude_limited() -> tuple[bool | None, float | None, str]:
    """Return (limited, resets_at, detail).

    limited is True/False when usage is known, or None when the usage API
    failed. Callers MUST NOT treat None as "healthy".

    When healthy (not limited), resets_at is the *next* weekly window from
    Anthropic — do not treat that as the end of an active demotion.
    """
    usage = fetch_claude_usage()
    if not usage:
        return None, None, "usage_unavailable"
    week = usage.get("seven_day") or {}
    util = float(week.get("utilization") or 0)
    resets_at = parse_reset(week.get("resets_at"))
    critical = False
    for lim in usage.get("limits") or []:
        if (
            lim.get("kind") == "weekly_all"
            and float(lim.get("percent") or 0) >= UTIL_THRESHOLD
        ):
            critical = True
            resets_at = parse_reset(lim.get("resets_at")) or resets_at
    if util >= UTIL_THRESHOLD or critical:
        return True, resets_at, f"weekly {util:.0f}% used"
    return False, resets_at, f"weekly {util:.0f}% used"


def apply_demotion(provider: str, resets_at: float | None, detail: str) -> dict:
    state = load_json(STATE, {}) or {}
    active = state.get("active") or {}
    if active.get("provider") == provider and active.get("demoted"):
        # Freeze demotion resetsAt once set. Refreshing from a healthy usage
        # payload would advance it to next week's window and lock restore out.
        if detail and detail != active.get("detail"):
            active["detail"] = detail
            state["active"] = active
            save_json(STATE, state)
        return {
            "action": "noop",
            "reason": "already_demoted",
            "provider": provider,
            "resetsAt": active.get("resetsAt"),
            "resetsAtLabel": fmt_reset(active.get("resetsAt")),
            "detail": active.get("detail") or detail,
        }

    cfg = load_cfg()
    if not BASELINE.is_file():
        save_json(BASELINE, snapshot_models(cfg))

    proposed = copy.deepcopy(cfg)
    n = demote_provider(proposed, provider)
    changed = agents_with_primary_change(cfg, proposed)
    ok, failed = handoff_agents(changed, "rate-guard-demote")
    for aid in failed:
        restore_one_agent_model(proposed, cfg, aid)
    # If defaults primary would change but any inheriting agent failed handoff,
    # keep defaults stable (agents with explicit models already restored above).
    if primary_of(cfg.get("agents", {}).get("defaults", {}).get("model")) != primary_of(
        proposed.get("agents", {}).get("defaults", {}).get("model")
    ):
        inheritors = [
            aid
            for aid in agent_ids(cfg)
            if not any(
                a.get("id") == aid and a.get("model")
                for a in cfg.get("agents", {}).get("list", [])
            )
        ]
        if any(aid in failed for aid in inheritors):
            restore_models_defaults = cfg.get("agents", {}).get("defaults", {}).get("model")
            if restore_models_defaults is not None:
                proposed.setdefault("agents", {}).setdefault("defaults", {})[
                    "model"
                ] = copy.deepcopy(restore_models_defaults)

    applied = agents_with_primary_change(cfg, proposed)
    if not applied:
        return {
            "action": "noop",
            "reason": "handoff_blocked" if changed else "no_chain_change",
            "provider": provider,
            "resetsAt": resets_at,
            "resetsAtLabel": fmt_reset(resets_at),
            "detail": detail,
            "chainsChanged": 0,
            "handoffOk": ok,
            "handoffFailed": failed,
        }

    save_cfg(proposed)
    maybe_restart_gateway()
    n = len(applied)

    state["active"] = {
        "provider": provider,
        "demoted": True,
        "since": time.time(),
        "resetsAt": resets_at,
        "detail": detail,
        "chainsChanged": n,
        "handoffOk": ok,
        "handoffFailed": failed,
    }
    save_json(STATE, state)
    return {
        "action": "demoted",
        "provider": provider,
        "resetsAt": resets_at,
        "resetsAtLabel": fmt_reset(resets_at),
        "detail": detail,
        "chainsChanged": n,
        "handoffOk": ok,
        "handoffFailed": failed,
    }


def try_restore() -> dict | None:
    state = load_json(STATE, {}) or {}
    active = state.get("active") or {}
    if not active.get("demoted"):
        return None

    provider = active.get("provider") or "claude"
    now = time.time()
    # Frozen stamp for THIS demotion window — never replace with next week's.
    demotion_resets_at = active.get("resetsAt")

    if demotion_resets_at and now < float(demotion_resets_at) + GRACE_SEC:
        return {
            "action": "noop",
            "reason": "before_reset",
            "provider": provider,
            "resetsAt": demotion_resets_at,
            "resetsAtLabel": fmt_reset(demotion_resets_at),
            "detail": active.get("detail") or "",
        }

    if provider == "claude":
        limited, _fresh_reset, detail = claude_limited()
        if limited is None:
            return {
                "action": "noop",
                "reason": "usage_unavailable",
                "provider": provider,
                "resetsAt": demotion_resets_at,
                "resetsAtLabel": fmt_reset(demotion_resets_at),
                "detail": detail,
            }
        if limited:
            # Still exhausted after the expected window — keep waiting; do not
            # adopt a newer resets_at here (demote path handles fresh demotions).
            if detail and detail != active.get("detail"):
                active["detail"] = detail
                state["active"] = active
                save_json(STATE, state)
            return {
                "action": "noop",
                "reason": "still_limited",
                "provider": provider,
                "resetsAt": demotion_resets_at,
                "resetsAtLabel": fmt_reset(demotion_resets_at),
                "detail": detail,
            }
    else:
        if not demotion_resets_at:
            return {
                "action": "noop",
                "reason": "no_reset_time",
                "provider": provider,
            }

    if not BASELINE.is_file():
        state["active"] = {}
        save_json(STATE, state)
        return {"action": "noop", "reason": "missing_baseline", "provider": provider}

    snap = load_json(BASELINE)
    cfg = load_cfg()
    proposed = copy.deepcopy(cfg)
    restore_models(proposed, snap)
    changed = agents_with_primary_change(cfg, proposed)
    ok, failed = handoff_agents(changed, "rate-guard-restore")
    for aid in failed:
        restore_one_agent_model(proposed, cfg, aid)
    if primary_of(cfg.get("agents", {}).get("defaults", {}).get("model")) != primary_of(
        proposed.get("agents", {}).get("defaults", {}).get("model")
    ):
        inheritors = [
            aid
            for aid in agent_ids(cfg)
            if not any(
                a.get("id") == aid and a.get("model")
                for a in cfg.get("agents", {}).get("list", [])
            )
        ]
        if any(aid in failed for aid in inheritors):
            d = cfg.get("agents", {}).get("defaults", {}).get("model")
            if d is not None:
                proposed.setdefault("agents", {}).setdefault("defaults", {})[
                    "model"
                ] = copy.deepcopy(d)

    applied = agents_with_primary_change(cfg, proposed)
    if not applied:
        return {
            "action": "noop",
            "reason": "handoff_blocked",
            "provider": provider,
            "resetsAt": demotion_resets_at,
            "resetsAtLabel": fmt_reset(demotion_resets_at),
            "handoffFailed": failed,
        }

    save_cfg(proposed)
    maybe_restart_gateway()
    state["lastRestored"] = {
        "provider": provider,
        "at": now,
        # Window we were waiting on — NOT Anthropic's next weekly resets_at.
        "demotionResetsAt": demotion_resets_at,
        "handoffOk": ok,
        "handoffFailed": failed,
    }
    # Only clear demotion if every changed agent handed off; else keep demoted
    # so the next tick can retry remaining agents.
    if failed:
        state["active"] = {
            **active,
            "partialRestore": True,
            "handoffFailed": failed,
            "handoffOk": ok,
        }
    else:
        state["active"] = {}
    save_json(STATE, state)
    return {
        "action": "restored",
        "provider": provider,
        "resetsAtLabel": fmt_reset(demotion_resets_at),
        "handoffOk": ok,
        "handoffFailed": failed,
    }


def status() -> dict:
    state = load_json(STATE, {}) or {}
    active = state.get("active") or {}
    limited, resets_at, detail = claude_limited()
    return {
        "action": "status",
        "claudeLimited": limited,
        "claudeDetail": detail,
        "claudeResetsAt": resets_at,
        "claudeResetsAtLabel": fmt_reset(resets_at),
        "active": active,
        "lastRestored": state.get("lastRestored") or {},
        "baselinePresent": BASELINE.is_file(),
        "utilThreshold": UTIL_THRESHOLD,
    }


def _premature_restore(lr: dict, now: float) -> float | None:
    """If last restore happened before its demotion window ended, return that window."""
    if lr.get("provider") != "claude":
        return None
    demotion_reset = lr.get("demotionResetsAt")
    if demotion_reset is None:
        # Legacy key from the broken fail-safe — only trust it if restore
        # itself looks premature (at < resetsAt). Otherwise ignore: a healthy
        # restore used to store next week's resets_at here.
        demotion_reset = lr.get("resetsAt")
        restored_at = lr.get("at")
        if not demotion_reset or not restored_at:
            return None
        if float(restored_at) >= float(demotion_reset):
            return None
    else:
        restored_at = lr.get("at")
        if not restored_at:
            return None
        if float(restored_at) >= float(demotion_reset):
            return None
    if now < float(demotion_reset) + GRACE_SEC:
        return float(demotion_reset)
    return None


def run_once() -> dict:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    restored = try_restore()
    if restored and restored.get("action") == "restored":
        return restored

    limited, resets_at, detail = claude_limited()
    if limited is True:
        return apply_demotion("claude", resets_at, detail)

    if limited is None:
        # Usage probe failed. Only re-demote if a prior restore was premature
        # relative to the demotion window that was in force — not merely
        # because next week's resets_at is still in the future.
        state = load_json(STATE, {}) or {}
        premature = _premature_restore(state.get("lastRestored") or {}, time.time())
        if premature is not None:
            return apply_demotion(
                "claude",
                premature,
                detail or "usage_unavailable; re-demoting before known reset",
            )
        if restored:
            return restored
        return {"action": "noop", "reason": "usage_unavailable", "detail": detail}

    if restored:
        return restored
    return {"action": "noop", "reason": "healthy", "detail": detail}


def main() -> int:
    ap = argparse.ArgumentParser(description="session-warden rate guard")
    ap.add_argument("--once", action="store_true", help="detect/demote/restore once (default)")
    ap.add_argument("--status", action="store_true", help="print status JSON")
    args = ap.parse_args()
    if args.status:
        emit(status())
        return 0
    emit(run_once())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
