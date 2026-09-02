#!/usr/bin/env python3
"""Fleet worker catalog, detect, credits-first routing, and invoke.

Used by lib/workers.sh and lib/router.sh. No network. Detection is PATH-only.
Routing is heuristic — it must not spend the credits it is trying to save.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

COST_RANK = {"cheap": 0, "mid": 1, "frontier": 2}

LOW_RE = re.compile(
    r"\b(summarize|summary|format|rename|lookup|regex|typo|prettier|"
    r"indent|what does|explain briefly|list the|convert to|translate)\b",
    re.I,
)
MID_RE = re.compile(
    r"\b(implement|fix|write a script|add a test|unit test|bug|"
    r"function|feature|patch)\b",
    re.I,
)
HIGH_RE = re.compile(
    r"\b(architecture|architect|multi-?file|refactor|security|design|"
    r"migrate|rewrite|audit|use frontier|use opus)\b",
    re.I,
)
TOOLS_RE = re.compile(
    r"\b(edit|implement|refactor|commit|test|patch|apply|repo|file|"
    r"create|write|fix)\b",
    re.I,
)


def warden_home() -> Path:
    raw = os.environ.get("WARDEN_HOME")
    if raw:
        return Path(raw)
    return Path(__file__).resolve().parent.parent


def catalog_path() -> Path:
    override = os.environ.get("WARDEN_WORKERS_CATALOG")
    if override:
        return Path(override)
    return warden_home() / "config" / "workers.json"


def overlay_dir() -> Path:
    override = os.environ.get("WARDEN_WORKERS_D")
    if override:
        return Path(override)
    return warden_home() / "config" / "workers.d"


def routing_file() -> Path | None:
    override = os.environ.get("WARDEN_ROUTING_FILE")
    if override:
        p = Path(override)
        return p if p.is_file() else None
    home = warden_home()
    for name in ("routing.yaml", "routing.json"):
        p = home / "config" / name
        if p.is_file():
            return p
    return None


def rate_guard_state_path() -> Path:
    return warden_home() / "state" / "rate-guard" / "state.json"


def worker_search_path() -> str:
    extra = os.environ.get("WARDEN_WORKER_PATH", "")
    if extra:
        return extra + os.pathsep + os.environ.get("PATH", "")
    return os.environ.get("PATH", "")


def _load_json(path: Path) -> dict | list | None:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None


def _workers_from_blob(blob) -> list[dict]:
    if blob is None:
        return []
    if isinstance(blob, list):
        return [w for w in blob if isinstance(w, dict) and w.get("id")]
    if isinstance(blob, dict):
        if isinstance(blob.get("workers"), list):
            return [w for w in blob["workers"] if isinstance(w, dict) and w.get("id")]
        if blob.get("id"):
            return [blob]
    return []


def load_catalog() -> list[dict]:
    by_id: dict[str, dict] = {}
    for w in _workers_from_blob(_load_json(catalog_path())):
        by_id[w["id"]] = w
    overlay = overlay_dir()
    if overlay.is_dir():
        for path in sorted(overlay.glob("*.json")):
            if path.name.endswith(".example.json"):
                continue
            for w in _workers_from_blob(_load_json(path)):
                by_id[w["id"]] = w
    return list(by_id.values())


def detect_worker(worker: dict, search_path: str | None = None) -> bool:
    path = search_path if search_path is not None else worker_search_path()
    cmds = (worker.get("detect") or {}).get("commands") or []
    if not cmds:
        return False
    for cmd in cmds:
        if shutil.which(cmd, path=path):
            continue
        return False
    return True


def demoted_provider() -> str:
    blob = _load_json(rate_guard_state_path())
    if not isinstance(blob, dict):
        return ""
    active = blob.get("active") or {}
    if active.get("demoted") is True:
        return str(active.get("provider") or "")
    return ""


def annotate(workers: list[dict]) -> list[dict]:
    path = worker_search_path()
    skipped = demoted_provider()
    out = []
    for w in workers:
        item = dict(w)
        item["detected"] = detect_worker(w, path)
        item["demoted"] = bool(skipped) and w.get("provider") == skipped
        item["available"] = item["detected"] and not item["demoted"]
        out.append(item)
    return out


def glob_to_re(pattern: str) -> re.Pattern:
    out: list[str] = []
    i = 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def path_matches(pattern: str, paths: list[str]) -> bool:
    if not paths:
        return False
    rx = glob_to_re(pattern.replace("\\", "/"))
    return any(rx.match(p.replace("\\", "/")) for p in paths)


def classify_complexity(task: str, paths: list[str]) -> str:
    text = task.strip()
    if HIGH_RE.search(text) or len(paths) >= 3:
        return "high"
    # "fix the typo" must stay low — typo/summarize/format beat a lone "fix".
    if LOW_RE.search(text) and not HIGH_RE.search(text):
        return "low"
    if len(text) < 80 and text.endswith("?") and not TOOLS_RE.search(text):
        return "low"
    if MID_RE.search(text) or TOOLS_RE.search(text):
        return "mid"
    return "mid"


def needs_tools(task: str, paths: list[str]) -> bool:
    if classify_complexity(task, paths) == "low":
        return False
    if paths:
        return True
    return bool(TOOLS_RE.search(task))


def parse_flow_map(raw: str) -> dict:
    body = raw.strip()
    if body.startswith("{") and body.endswith("}"):
        body = body[1:-1]
    out: dict[str, str] = {}
    for part in body.split(","):
        if ":" not in part:
            continue
        key, val = part.split(":", 1)
        out[key.strip()] = val.strip().strip("\"'")
    return out


def parse_routing_yaml(text: str) -> dict:
    """Documented subset only. No PyYAML dependency."""
    policy = "credits-first"
    rules: list[dict] = []
    current: dict | None = None
    in_match = False
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        stripped = line.strip()
        if stripped.startswith("policy:"):
            policy = stripped.split(":", 1)[1].strip()
            continue
        if stripped == "rules:":
            continue
        if stripped.startswith("- "):
            if current:
                rules.append(current)
            current = {"match": {}, "worker": ""}
            in_match = False
            rest = stripped[2:]
            if rest.startswith("match:"):
                rhs = rest.split(":", 1)[1].strip()
                if rhs.startswith("{"):
                    current["match"] = parse_flow_map(rhs)
                    in_match = False
                else:
                    in_match = True
            elif rest.startswith("worker:"):
                current["worker"] = rest.split(":", 1)[1].strip().strip("\"'")
            continue
        if current is None:
            continue
        if stripped.startswith("worker:"):
            current["worker"] = stripped.split(":", 1)[1].strip().strip("\"'")
            in_match = False
            continue
        if stripped.startswith("match:"):
            rhs = stripped.split(":", 1)[1].strip()
            if rhs.startswith("{"):
                current["match"] = parse_flow_map(rhs)
                in_match = False
            else:
                in_match = True
            continue
        if in_match and ":" in stripped:
            key, val = stripped.split(":", 1)
            current.setdefault("match", {})[key.strip()] = val.strip().strip("\"'")
    if current:
        rules.append(current)
    return {"policy": policy, "rules": [r for r in rules if r.get("worker")]}


def load_routing() -> dict:
    path = routing_file()
    if path is None:
        return {"policy": "credits-first", "rules": []}
    text = path.read_text()
    if path.suffix == ".json" or text.lstrip().startswith("{"):
        blob = json.loads(text)
        if not isinstance(blob, dict):
            return {"policy": "credits-first", "rules": []}
        blob.setdefault("policy", "credits-first")
        blob.setdefault("rules", [])
        return blob
    return parse_routing_yaml(text)


def rule_matches(rule: dict, task: str, paths: list[str], tags: list[str], complexity: str) -> bool:
    match = rule.get("match") or {}
    if not match:
        return True
    if "path" in match and not path_matches(str(match["path"]), paths):
        return False
    if "complexity" in match and str(match["complexity"]) != complexity:
        return False
    if "tag" in match and str(match["tag"]) not in tags:
        return False
    if "contains" in match and str(match["contains"]).lower() not in task.lower():
        return False
    return True


def capable(worker: dict, require_tools: bool) -> bool:
    caps = set(worker.get("capabilities") or [])
    if require_tools:
        return bool(caps & {"tools", "repo"})
    return "chat" in caps or "code" in caps or bool(caps)


def cost_key(worker: dict) -> tuple:
    rank = COST_RANK.get(str(worker.get("costClass") or "mid"), 1)
    kind_bias = 0 if worker.get("kind") == "model" else 1
    return (rank, kind_bias, worker.get("id") or "")


def pick_smart(available: list[dict], complexity: str, require_tools: bool) -> list[dict]:
    pool = [w for w in available if capable(w, require_tools)]
    if not pool:
        pool = list(available)
    if complexity == "high":
        frontier = [w for w in pool if w.get("costClass") == "frontier"]
        if frontier:
            pool = frontier
        else:
            mid = [w for w in pool if w.get("costClass") == "mid"]
            if mid:
                pool = mid
    elif complexity == "low" and not require_tools:
        cheap = [w for w in pool if w.get("costClass") == "cheap"]
        if cheap:
            pool = cheap
    else:
        # mid: cheapest that can do the job; frontier only if nothing cheaper
        non_front = [w for w in pool if w.get("costClass") != "frontier"]
        if non_front:
            pool = non_front
    return sorted(pool, key=cost_key)


def route(task: str, paths: list[str] | None = None, tags: list[str] | None = None, host: str = "") -> dict:
    paths = paths or []
    tags = tags or []
    workers = annotate(load_catalog())
    available = [w for w in workers if w.get("available")]
    complexity = classify_complexity(task, paths)
    require_tools = needs_tools(task, paths)
    routing = load_routing()
    reason = "credits-first"
    chosen: dict | None = None
    rule_source = ""

    for idx, rule in enumerate(routing.get("rules") or []):
        if not rule_matches(rule, task, paths, tags, complexity):
            continue
        wanted = str(rule.get("worker") or "")
        hit = next((w for w in available if w.get("id") == wanted), None)
        if hit:
            chosen = hit
            reason = "user-rule"
            rule_source = f"rules[{idx}]"
            break

    if chosen is None:
        ranked = pick_smart(available, complexity, require_tools)
        chosen = ranked[0] if ranked else None
        if chosen is None:
            reason = "none-available"
        elif require_tools:
            reason = "credits-first-tools"
        elif complexity == "high":
            reason = "credits-first-high"
        else:
            reason = "credits-first"

    fallbacks: list[str] = []
    if chosen is not None:
        rest = [w for w in available if w.get("id") != chosen.get("id")]
        if reason.startswith("credits-first") or chosen.get("id"):
            rest = pick_smart(rest, complexity, require_tools) if rest else []
        fallbacks = [w["id"] for w in rest]

    result = {
        "worker": chosen.get("id") if chosen else "",
        "label": chosen.get("label") if chosen else "",
        "kind": chosen.get("kind") if chosen else "",
        "provider": chosen.get("provider") if chosen else "",
        "costClass": chosen.get("costClass") if chosen else "",
        "reason": reason,
        "complexity": complexity,
        "needsTools": require_tools,
        "fallback": fallbacks[0] if fallbacks else "",
        "fallbacks": fallbacks,
        "self": bool(host) and chosen is not None and chosen.get("id") == host,
        "host": host,
        "rule": rule_source,
        "demotedProvider": demoted_provider(),
        "available": [w["id"] for w in available],
    }
    return result


def expand_argv(worker: dict, prompt: str, cwd: str) -> list[str]:
    invoke = worker.get("invoke") or {}
    argv = invoke.get("argv") or []
    return [str(part).replace("{{prompt}}", prompt).replace("{{cwd}}", cwd) for part in argv]


def invoke_worker(worker_id: str, prompt: str, cwd: str | None = None) -> dict:
    workers = {w["id"]: w for w in load_catalog()}
    worker = workers.get(worker_id)
    if worker is None:
        return {
            "worker": worker_id,
            "exit": 2,
            "stdout": "",
            "stderr": f"unknown worker: {worker_id}",
            "argv": [],
        }
    workdir = cwd or os.getcwd()
    argv = expand_argv(worker, prompt, workdir)
    timeout = int((worker.get("invoke") or {}).get("timeoutSec") or 180)
    env = os.environ.copy()
    extra = os.environ.get("WARDEN_WORKER_PATH")
    if extra:
        env["PATH"] = extra + os.pathsep + env.get("PATH", "")
    use_stdin = bool((worker.get("invoke") or {}).get("stdin"))
    try:
        proc = subprocess.run(
            argv,
            input=prompt if use_stdin else None,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=workdir,
            env=env,
            check=False,
        )
        return {
            "worker": worker_id,
            "exit": proc.returncode,
            "stdout": proc.stdout or "",
            "stderr": proc.stderr or "",
            "argv": argv,
            "timeoutSec": timeout,
        }
    except FileNotFoundError as exc:
        return {
            "worker": worker_id,
            "exit": 127,
            "stdout": "",
            "stderr": str(exc),
            "argv": argv,
        }
    except subprocess.TimeoutExpired:
        return {
            "worker": worker_id,
            "exit": 124,
            "stdout": "",
            "stderr": f"worker timed out after {timeout}s",
            "argv": argv,
            "timeoutSec": timeout,
        }


def print_workers_table(workers: list[dict]) -> None:
    rows = annotate(workers)
    print(f"{'id':<16} {'kind':<8} {'cost':<9} {'avail':<6} {'commands'}")
    for w in rows:
        cmds = ",".join((w.get("detect") or {}).get("commands") or [])
        flag = "yes" if w.get("available") else ("skip" if w.get("demoted") else "no")
        print(f"{w.get('id', ''):<16} {w.get('kind', ''):<8} {w.get('costClass', ''):<9} {flag:<6} {cmds}")


def cmd_catalog(args: argparse.Namespace) -> int:
    workers = load_catalog()
    if args.json:
        print(json.dumps({"workers": annotate(workers)}, indent=2))
    else:
        print_workers_table(workers)
    return 0


def cmd_detect(args: argparse.Namespace) -> int:
    workers = annotate(load_catalog())
    available = [w["id"] for w in workers if w.get("available")]
    if args.json:
        print(json.dumps({"available": available, "count": len(available)}))
    else:
        print(len(available))
    return 0


def cmd_route(args: argparse.Namespace) -> int:
    task = args.task
    if not task and args.file:
        task = Path(args.file).read_text()
    if not task and not sys.stdin.isatty():
        task = sys.stdin.read()
    if not task:
        print("route: --task is required (or pass --file / stdin)", file=sys.stderr)
        return 2
    result = route(task, paths=args.path or [], tags=args.tag or [], host=args.host or "")
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        if not result["worker"]:
            print("no available worker", file=sys.stderr)
            return 1
        extra = f" fallback={result['fallback']}" if result["fallback"] else ""
        print(f"{result['worker']}  ({result['costClass']}, {result['reason']}, complexity={result['complexity']}){extra}")
    return 0 if result["worker"] else 1


def cmd_invoke(args: argparse.Namespace) -> int:
    prompt = args.prompt
    if not prompt and args.file:
        prompt = Path(args.file).read_text()
    if not prompt and not sys.stdin.isatty():
        prompt = sys.stdin.read()
    if not prompt:
        print("invoke: --prompt is required (or pass --file / stdin)", file=sys.stderr)
        return 2
    result = invoke_worker(args.worker, prompt, cwd=args.cwd)
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        if result.get("stderr"):
            sys.stderr.write(result["stderr"])
            if not result["stderr"].endswith("\n"):
                sys.stderr.write("\n")
        sys.stdout.write(result.get("stdout") or "")
    return int(result.get("exit") or 0)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="dispatch.py")
    sub = p.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("catalog", help="list workers")
    c.add_argument("--json", action="store_true")
    c.set_defaults(func=cmd_catalog)

    d = sub.add_parser("detect", help="count available workers")
    d.add_argument("--json", action="store_true")
    d.set_defaults(func=cmd_detect)

    r = sub.add_parser("route", help="pick a worker")
    r.add_argument("--task", default="")
    r.add_argument("--file", default="")
    r.add_argument("--path", action="append", default=[])
    r.add_argument("--tag", action="append", default=[])
    r.add_argument("--host", default="")
    r.add_argument("--json", action="store_true")
    r.set_defaults(func=cmd_route)

    i = sub.add_parser("invoke", help="run a worker")
    i.add_argument("--worker", required=True)
    i.add_argument("--prompt", default="")
    i.add_argument("--file", default="")
    i.add_argument("--cwd", default="")
    i.add_argument("--json", action="store_true")
    i.set_defaults(func=cmd_invoke)
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
