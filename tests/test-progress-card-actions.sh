#!/usr/bin/env bash
# test-progress-card-actions.sh — payload parse, allowlist, latest state

echo "  progress-card-actions: helpers"

cat > "$SANDBOX/progress-card-actions-test.mjs" <<'JS'
import assert from "node:assert/strict";
import { mkdirSync, utimesSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const {
  parsePayload,
  isAllowed,
  resolveAllowed,
  latestProgressState,
} = await import(pathToFileURL(process.env.PLUGIN_INDEX).href);

const fails = [];
function check(name, fn) {
  try {
    fn();
    console.log("PASS|" + name);
  } catch (err) {
    fails.push(name + ": " + (err.message || err));
    console.log("FAIL|" + name + ": " + (err.message || err));
  }
}

check("parse stop payload", () => {
  assert.deepEqual(parsePayload("stop:dash"), { action: "stop", agent: "dash" });
});
check("parse steer payload", () => {
  assert.deepEqual(parsePayload("steer:bloop"), { action: "steer", agent: "bloop" });
});
check("reject harvest payload", () => {
  assert.equal(parsePayload("promote:dash:skill"), null);
});
check("reject empty payload", () => {
  assert.equal(parsePayload(""), null);
});

check("authorized sender always allowed", () => {
  assert.equal(isAllowed("9", [], true), true);
});
check("allowlisted sender allowed", () => {
  assert.equal(isAllowed("9", ["9", "8"], false), true);
});
check("unknown sender denied", () => {
  assert.equal(isAllowed("7", ["9"], false), false);
});
check("empty sender denied", () => {
  assert.equal(isAllowed("", [], false), false);
});

process.env.WARDEN_PROGRESS_ALLOWED_USER_IDS = "11,22";
delete process.env.WARDEN_DISCORD_ALLOWED_USER_IDS;
delete process.env.WARDEN_TELEGRAM_ALLOWED_USER_IDS;
check("env allowlist", () => {
  assert.deepEqual(resolveAllowed(), ["11", "22"]);
});
check("plugin config overrides env", () => {
  assert.deepEqual(resolveAllowed(["99"]), ["99"]);
});

const home = process.env.FAKE_HOME;
mkdirSync(join(home, "state", "progress"), { recursive: true });
const older = join(home, "state", "progress", "dash-old.json");
const newer = join(home, "state", "progress", "dash-new.json");
writeFileSync(older, JSON.stringify({ channel: "old" }));
writeFileSync(newer, JSON.stringify({ channel: "agent:dash:discord:channel:1" }));
utimesSync(older, 1, 1);
check("latest state is newest file", () => {
  const state = latestProgressState("dash", home);
  assert.equal(state.channel, "agent:dash:discord:channel:1");
});
check("missing agent has no state", () => {
  assert.equal(latestProgressState("missing", home), null);
});

if (fails.length) process.exit(1);
JS

export PLUGIN_INDEX="${REAL_WARDEN_HOME:-$WARDEN_HOME}/contrib/openclaw-plugins/progress-card-actions/helpers.js"
export FAKE_HOME="$SANDBOX/progress-home"
mkdir -p "$FAKE_HOME"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP|progress-card-actions helpers need node"
  return 0
fi

out=$(node "$SANDBOX/progress-card-actions-test.mjs" 2>&1) || true
while IFS= read -r line; do
  case "$line" in
    PASS|FAIL|SKIP|'') ;;
    PASS*|FAIL*|SKIP*)
      result="${line%%|*}"
      msg="${line#*|}"
      case "$result" in
        PASS) assert_eq "1" "1" "$msg" ;;
        FAIL) assert_eq "pass" "fail" "$msg" ;;
        SKIP) echo "SKIP|$msg" >> "$TEST_RESULTS_FILE" ;;
      esac
      ;;
  esac
done <<< "$out"

# If node printed a stack instead of PASS/FAIL lines, fail loudly.
if ! printf '%s\n' "$out" | grep -q '^PASS|'; then
  assert_eq "helpers ran" "$out" "progress-card-actions node helpers ran"
fi
