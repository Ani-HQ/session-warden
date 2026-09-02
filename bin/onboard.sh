#!/usr/bin/env bash
# onboard.sh — detect hosts + workers, write credits-first rules, install skills.
# Does not require OpenClaw. install.sh remains the fleet-supervisor installer.
#
# Usage:
#   bin/onboard.sh [--host all|openclaw|hermes|claude-code|codex|grok] [--dry-run]

set -uo pipefail

WARDEN_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WARDEN_HOME

if [ -f "${WARDEN_HOME}/config/thresholds.env" ]; then
  # shellcheck disable=SC1091
  source "${WARDEN_HOME}/config/thresholds.env"
fi

# shellcheck source=../lib/workers.sh
source "${WARDEN_HOME}/lib/workers.sh"

ONBOARD_HOME="${WARDEN_ONBOARD_HOME:-$HOME}"
SKILLS_DIR="${WARDEN_SKILLS_DIR:-${WARDEN_HOME}/skills}"
OPENCLAW_HOME="${WARDEN_OPENCLAW_HOME:-${ONBOARD_HOME}/.openclaw}"

usage() {
  cat <<'EOF'
Usage: session-warden onboard [--host all|openclaw|hermes|claude-code|codex|grok] [--dry-run]

Detect installed CLIs, write config/routing.yaml if missing, and install a
short route skill into each host harness you already use. No OpenClaw
required. Extra Anthropic quota is gone — this keeps frontier for hard work.
EOF
}

dry_run=0
host_filter="all"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --host)
      host_filter="${2:-}"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

want_host() {
  local name="$1"
  [ "$host_filter" = "all" ] || [ "$host_filter" = "$name" ]
}

detect_hosts() {
  detected_hosts=()
  if [ -f "${OPENCLAW_HOME}/openclaw.json" ] || [ -d "${OPENCLAW_HOME}/agents" ]; then
    detected_hosts+=("openclaw")
  fi
  local hermes
  for hermes in "${ONBOARD_HOME}"/.hermes-*; do
    if [ -d "$hermes" ]; then
      detected_hosts+=("hermes")
      break
    fi
  done
  if command -v claude >/dev/null 2>&1; then
    detected_hosts+=("claude-code")
  fi
  if command -v codex >/dev/null 2>&1; then
    detected_hosts+=("codex")
  fi
  if command -v grok >/dev/null 2>&1; then
    detected_hosts+=("grok")
  fi
}

host_in() {
  local needle="$1" h
  for h in "${detected_hosts[@]+"${detected_hosts[@]}"}"; do
    [ "$h" = "$needle" ] && return 0
  done
  return 1
}

install_skill() {
  local dest="$1" src="$2"
  if [ "$dry_run" = "1" ]; then
    echo "  would install $src → $dest"
    return 0
  fi
  mkdir -p "$dest"
  cp "$src" "${dest}/SKILL.md"
  echo "  installed ${dest}/SKILL.md"
}

append_agents_snippet() {
  local dest="$1" snippet="$2"
  if [ "$dry_run" = "1" ]; then
    echo "  would append route snippet → $dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ] && grep -q "session-warden route" "$dest"; then
    echo "  already mentioned in $dest"
    return 0
  fi
  {
    echo ""
    echo "## session-warden route"
    echo ""
    cat "$snippet"
  } >> "$dest"
  echo "  appended snippet → $dest"
}

detect_hosts

echo "session-warden onboard"
echo "======================"
echo ""
echo "Extra Anthropic quota is gone. Keep frontier harnesses for architecture,"
echo "refactors, and security. The warden routes busywork to cheaper workers."
echo ""

if [ "${#detected_hosts[@]}" -eq 0 ]; then
  echo "hosts:    none detected (openclaw home, ~/.hermes-*, claude, codex, grok)"
else
  echo "hosts:    ${detected_hosts[*]}"
fi

worker_json=$(workers_catalog_json 2>/dev/null || echo '{"workers":[]}')
avail=$(printf '%s' "$worker_json" | python3 -c 'import json,sys; w=json.load(sys.stdin).get("workers") or []; print(" ".join(x["id"] for x in w if x.get("available")))')
missing=$(printf '%s' "$worker_json" | python3 -c 'import json,sys; w=json.load(sys.stdin).get("workers") or []; print(" ".join(x["id"] for x in w if not x.get("available")))')
avail_n=$(printf '%s' "$worker_json" | python3 -c 'import json,sys; w=json.load(sys.stdin).get("workers") or []; print(sum(1 for x in w if x.get("available")))')
miss_n=$(printf '%s' "$worker_json" | python3 -c 'import json,sys; w=json.load(sys.stdin).get("workers") or []; print(sum(1 for x in w if not x.get("available")))')
echo "workers:  ${avail:-none} (${avail_n} ready; ${miss_n} missing${missing:+ — $missing})"
echo "policy:   credits-first — cheapest capable worker; frontier only when the ask is hard"

routing_dst="${WARDEN_HOME}/config/routing.yaml"
routing_src="${WARDEN_HOME}/config/routing.yaml.example"
if [ -f "$routing_dst" ]; then
  echo "rules:    $routing_dst (already present)"
elif [ "$dry_run" = "1" ]; then
  echo "rules:    would write $routing_dst"
else
  cp "$routing_src" "$routing_dst"
  echo "rules:    wrote $routing_dst from the example — edit to pin paths or models"
fi

echo "skills:"
installed_any=0

if want_host openclaw && host_in openclaw; then
  src="${SKILLS_DIR}/openclaw/SKILL.md"
  dest="${OPENCLAW_HOME}/skills/session-warden-route"
  [ -f "$src" ] && install_skill "$dest" "$src" && installed_any=1
fi

if want_host hermes && host_in hermes; then
  src="${SKILLS_DIR}/hermes/SKILL.md"
  if [ -f "$src" ]; then
    for hermes in "${ONBOARD_HOME}"/.hermes-*; do
      [ -d "$hermes" ] || continue
      install_skill "${hermes}/skills/session-warden-route" "$src"
      installed_any=1
    done
  fi
fi

if want_host claude-code && host_in claude-code; then
  src="${SKILLS_DIR}/claude-code/SKILL.md"
  dest="${ONBOARD_HOME}/.claude/skills/session-warden-route"
  [ -f "$src" ] && install_skill "$dest" "$src" && installed_any=1
fi

if want_host codex && host_in codex; then
  src="${SKILLS_DIR}/codex/SKILL.md"
  if [ -f "$src" ]; then
    if [ -d "${ONBOARD_HOME}/.codex" ]; then
      install_skill "${ONBOARD_HOME}/.codex/skills/session-warden-route" "$src"
    else
      append_agents_snippet "${ONBOARD_HOME}/.codex/AGENTS.md" "$src"
    fi
    installed_any=1
  fi
fi

if want_host grok && host_in grok; then
  src="${SKILLS_DIR}/grok/SKILL.md"
  if [ -f "$src" ]; then
    if [ -d "${ONBOARD_HOME}/.grok" ]; then
      install_skill "${ONBOARD_HOME}/.grok/skills/session-warden-route" "$src"
    else
      echo "  grok: no ~/.grok skills dir — copy ${src} into your grokbot skills folder"
    fi
    installed_any=1
  fi
fi

if [ "$installed_any" = "0" ]; then
  if [ "$host_filter" != "all" ] && ! host_in "$host_filter"; then
    echo "  host '$host_filter' not detected — nothing installed"
  else
    echo "  none (no matching host detected)"
  fi
fi

echo ""
if [ "$dry_run" = "1" ]; then
  echo "dry-run:  no files written"
fi
echo "try:      session-warden route --task \"fix the typo in README\" --json"
echo "then:     session-warden run --task \"fix the typo in README\""
