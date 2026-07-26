#!/usr/bin/env python3
import json
import os
import re
from pathlib import Path

script = Path(os.environ.get("SCRIPT_DIR", Path.home() / "session-warden/contrib/fleet-live"))
out = Path(os.environ.get("FLEET_OUT", "/var/www/fleet"))
src = script / "index.html"
live = json.loads((out / "live.json").read_text())
html = src.read_text()
boot = json.dumps(live, separators=(",", ":"), ensure_ascii=False)


def repl(match: re.Match) -> str:
    return match.group(1) + boot + match.group(3)


html2, n = re.subn(
    r'(<script id="bootstrap" type="application/json">)(.*?)(</script>)',
    repl,
    html,
    count=1,
    flags=re.S,
)
if n != 1:
    raise SystemExit("bootstrap placeholder missing")

tmp = out / "index.html.tmp"
tmp.write_text(html2)
tmp.replace(out / "index.html")
(out / "index.html").chmod(0o644)
print(
    f"baked index.html with {len(live.get('agents', []))} agents, "
    f"boot={len(boot)} bytes"
)
