#!/usr/bin/env node
// patch-smart-watchdog.js — smart watchdog + progress heartbeat for openclaw CLI sessions
//
// Part 1: Smart watchdog
//   Snapshots CLI child PIDs at session start (baseline = MCP servers).
//   When no-output timer fires, checks for NEW children spawned since baseline.
//   New children = a tool is running = extend. No new children = API stall = kill.
//
// Part 2: Progress heartbeat
//   During long turns, sends periodic fun status messages to the channel
//   so the team knows the agent is alive and working.
//
// MUST be re-run after every `npm update openclaw` or `npm install -g openclaw`.

const fs = require('fs');
const path = require('path');

const OPENCLAW_DIST = path.join(process.env.HOME, '.npm-global/lib/node_modules/openclaw/dist');

const files = fs.readdirSync(OPENCLAW_DIST);
const runtimeFile = files.find(f => /^execute\.runtime-.*\.js$/.test(f) && !f.includes('.pre-'));
if (!runtimeFile) {
	console.error('ERROR: openclaw runtime file not found in', OPENCLAW_DIST);
	process.exit(1);
}

const filePath = path.join(OPENCLAW_DIST, runtimeFile);
let code = fs.readFileSync(filePath, 'utf8');

// If already patched with v3 (progress heartbeat), nothing to do
if (code.includes('__ocProgressHeartbeat')) {
	console.log('Already patched (v3). No changes needed.');
	process.exit(0);
}

// If patched with older versions, restore from earliest backup
if (code.includes('__ocProcessTreeActive') || code.includes('__ocWatchdogCheck') || code.includes('__baselineChildPids')) {
	const backups = files
		.filter(f => f.startsWith('execute.runtime-') && f.includes('.pre-watchdog-'))
		.sort();
	if (backups.length === 0) {
		console.error('ERROR: old patch detected but no backup found');
		process.exit(1);
	}
	console.log('Restoring from earliest backup:', backups[0]);
	code = fs.readFileSync(path.join(OPENCLAW_DIST, backups[0]), 'utf8');
}

// Backup
const backupName = `${runtimeFile}.pre-watchdog-${new Date().toISOString().replace(/[:.]/g, '-')}`;
fs.writeFileSync(path.join(OPENCLAW_DIST, backupName), code, 'utf8');
console.log('Backup:', backupName);

// ============================================================
// PATCH 1: Add child_process import
// ============================================================
if (!code.includes('node:child_process')) {
	code = code.replace(
		'import path from "node:path";',
		'import path from "node:path";\nimport { execSync as __ocExecSync } from "node:child_process";'
	);
}
console.log('Patched: child_process import');

// ============================================================
// PATCH 2: Replace resetNoOutputTimer with smart watchdog
// ============================================================
const OLD_RESET = [
	'function resetNoOutputTimer(session) {',
	'\tconst turn = session.currentTurn;',
	'\tif (!turn) return;',
	'\tif (turn.noOutputTimer) clearTimeout(turn.noOutputTimer);',
	'\tturn.noOutputTimer = setTimeout(() => {',
	'\t\tcloseLiveSession(session, "abort", createTimeoutError(session, `CLI produced no output for ${Math.round(session.noOutputTimeoutMs / 1e3)}s and was terminated.`));',
	'\t}, session.noOutputTimeoutMs);',
	'}'
].join('\n');

const NEW_RESET = [
	'function __ocGetChildPids(pid) {',
	'\tif (!pid) return new Set();',
	'\ttry {',
	'\t\tconst out = __ocExecSync(`pgrep -P ${pid} 2>/dev/null`, { timeout: 3000, encoding: "utf8" });',
	'\t\treturn new Set(out.trim().split("\\n").filter(Boolean));',
	'\t} catch { return new Set(); }',
	'}',
	'const __OC_MAX_WATCHDOG_EXTENSIONS = 20;',
	'const __OC_PROGRESS_INTERVAL_MS = 60000;',
	'const __OC_PROGRESS_MESSAGES = [',
	'\t["⚙️", "crunching...", "▰▰▱▱▱▱▱▱▱▱"],',
	'\t["🔧", "deep in the toolchain...", "▰▰▰▰▱▱▱▱▱▱"],',
	'\t["🧠", "thinking hard...", "▰▰▰▰▰▰▱▱▱▱"],',
	'\t["⛏️", "mining for answers...", "▰▰▰▰▰▰▰▰▱▱"],',
	'\t["🏗️", "still building...", "▰▰▰▰▰▰▰▰▰▱"],',
	'\t["🔬", "almost there...", "▰▰▰▰▰▰▰▰▰▰"],',
	'\t["🐢", "slow and steady...", "▰▰▰▱▱▱▱▱▱▱"],',
	'\t["🪄", "working some magic...", "▰▰▰▰▰▱▱▱▱▱"],',
	'\t["📡", "fetching data...", "▰▰▰▰▰▰▰▱▱▱"],',
	'\t["🧩", "piecing it together...", "▰▰▰▰▰▰▰▰▰▱"]',
	'];',
	'function __ocProgressHeartbeat(session) {',
	'\tconst turn = session.currentTurn;',
	'\tif (!turn) return;',
	'\tconst elapsed = Math.round((Date.now() - turn.startedAtMs) / 1000);',
	'\tconst idx = (turn.__progressCount || 0) % __OC_PROGRESS_MESSAGES.length;',
	'\tturn.__progressCount = (turn.__progressCount || 0) + 1;',
	'\tconst mins = Math.floor(elapsed / 60);',
	'\tconst secs = elapsed % 60;',
	'\tconst timeStr = mins > 0 ? mins + "m " + secs + "s" : secs + "s";',
	'\tconst [emoji, text, bar] = __OC_PROGRESS_MESSAGES[idx];',
	'\tconst msg = emoji + " " + text + " (" + timeStr + ")\\n" + bar;',
	'\tconst sessionKey = session.__sessionKey;',
	'\tif (sessionKey) {',
	'\t\ttry {',
	'\t\t\texecuteDeps.enqueueSystemEvent(msg, { sessionKey, contextKey: "progress:heartbeat" });',
	'\t\t\texecuteDeps.requestHeartbeatNow(scopedHeartbeatWakeOptions(sessionKey, { reason: "cli:progress:heartbeat" }));',
	'\t\t\tconsole.error(`[PROGRESS] heartbeat sent for ${sessionKey} (${timeStr}, tick ${turn.__progressCount})`);',
	'\t\t} catch (e) { console.error(`[PROGRESS] heartbeat failed: ${e.message}`); }',
	'\t}',
	'\tturn.__progressTimer = setTimeout(() => __ocProgressHeartbeat(session), __OC_PROGRESS_INTERVAL_MS);',
	'}',
	'function resetNoOutputTimer(session) {',
	'\tconst turn = session.currentTurn;',
	'\tif (!turn) return;',
	'\tif (turn.noOutputTimer) clearTimeout(turn.noOutputTimer);',
	'\tturn.__noOutputExtensions = 0;',
	'\tturn.noOutputTimer = setTimeout(() => {',
	'\t\t__ocWatchdogCheck(session, session.noOutputTimeoutMs);',
	'\t}, session.noOutputTimeoutMs);',
	'}',
	'function __ocWatchdogCheck(session, timeoutMs) {',
	'\tconst turn = session.currentTurn;',
	'\tif (!turn) return;',
	'\tconst pid = session.managedRun?.pid;',
	'\tconst extensions = turn.__noOutputExtensions || 0;',
	'\tconst baseline = session.__baselineChildPids || new Set();',
	'\tconst current = __ocGetChildPids(pid);',
	'\tconst newChildren = [...current].filter(p => !baseline.has(p));',
	'\tif (extensions < __OC_MAX_WATCHDOG_EXTENSIONS && newChildren.length > 0) {',
	'\t\tturn.__noOutputExtensions = extensions + 1;',
	'\t\tconsole.error(`[WATCHDOG] new children detected: ${newChildren.join(",")} (ext ${turn.__noOutputExtensions}/${__OC_MAX_WATCHDOG_EXTENSIONS}), extending`);',
	'\t\tif (turn.noOutputTimer) clearTimeout(turn.noOutputTimer);',
	'\t\tturn.noOutputTimer = setTimeout(() => { __ocWatchdogCheck(session, timeoutMs); }, timeoutMs);',
	'\t\treturn;',
	'\t}',
	'\tif (extensions >= __OC_MAX_WATCHDOG_EXTENSIONS) {',
	'\t\tconsole.error(`[WATCHDOG] max extensions (${__OC_MAX_WATCHDOG_EXTENSIONS}) reached for PID ${pid}, killing`);',
	'\t}',
	'\tcloseLiveSession(session, "abort", createTimeoutError(session, `CLI produced no output for ${Math.round(timeoutMs / 1e3)}s and was terminated.`));',
	'}'
].join('\n');

if (!code.includes(OLD_RESET)) {
	console.error('ERROR: could not find resetNoOutputTimer function to patch');
	process.exit(1);
}
code = code.replace(OLD_RESET, NEW_RESET);
console.log('Patched: resetNoOutputTimer + watchdog + progress heartbeat');

// ============================================================
// PATCH 3: Patch createTurn initial timer + start progress timer
// ============================================================
const OLD_TURN_TIMER = [
	'\tturn.noOutputTimer = setTimeout(() => {',
	'\t\tcloseLiveSession(params.session, "abort", createTimeoutError(params.session, `CLI produced no output for ${Math.round(params.noOutputTimeoutMs / 1e3)}s and was terminated.`));',
	'\t}, params.noOutputTimeoutMs);'
].join('\n');

const NEW_TURN_TIMER = [
	'\tturn.__noOutputExtensions = 0;',
	'\tturn.__progressCount = 0;',
	'\tturn.__progressTimer = setTimeout(() => __ocProgressHeartbeat(params.session), __OC_PROGRESS_INTERVAL_MS);',
	'\tturn.noOutputTimer = setTimeout(() => {',
	'\t\t__ocWatchdogCheck(params.session, params.noOutputTimeoutMs);',
	'\t}, params.noOutputTimeoutMs);'
].join('\n');

if (!code.includes(OLD_TURN_TIMER)) {
	console.error('WARNING: could not find createTurn timer to patch (non-critical)');
} else {
	code = code.replace(OLD_TURN_TIMER, NEW_TURN_TIMER);
	console.log('Patched: createTurn timer + progress timer');
}

// ============================================================
// PATCH 4: Clear progress timer in clearTurnTimers
// ============================================================
const OLD_CLEAR = [
	'function clearTurnTimers(turn) {',
	'\tif (turn.noOutputTimer) {',
	'\t\tclearTimeout(turn.noOutputTimer);',
	'\t\tturn.noOutputTimer = null;',
	'\t}',
	'\tif (turn.timeoutTimer) {',
	'\t\tclearTimeout(turn.timeoutTimer);',
	'\t\tturn.timeoutTimer = null;',
	'\t}',
	'}'
].join('\n');

const NEW_CLEAR = [
	'function clearTurnTimers(turn) {',
	'\tif (turn.noOutputTimer) {',
	'\t\tclearTimeout(turn.noOutputTimer);',
	'\t\tturn.noOutputTimer = null;',
	'\t}',
	'\tif (turn.timeoutTimer) {',
	'\t\tclearTimeout(turn.timeoutTimer);',
	'\t\tturn.timeoutTimer = null;',
	'\t}',
	'\tif (turn.__progressTimer) {',
	'\t\tclearTimeout(turn.__progressTimer);',
	'\t\tturn.__progressTimer = null;',
	'\t}',
	'}'
].join('\n');

if (!code.includes(OLD_CLEAR)) {
	console.error('WARNING: could not patch clearTurnTimers for progress cleanup');
} else {
	code = code.replace(OLD_CLEAR, NEW_CLEAR);
	console.log('Patched: clearTurnTimers (clears progress timer)');
}

// ============================================================
// PATCH 5: Add baseline child snapshot + sessionKey at session creation
// ============================================================
const OLD_SESSION = 'closing: false\n\t};\n\tmanagedRun.wait()';
const NEW_SESSION = [
	'closing: false,',
	'\t\t__baselineChildPids: new Set(),',
	'\t\t__sessionKey: params.context.params.sessionKey || null',
	'\t};',
	'\tsetTimeout(() => { try { session.__baselineChildPids = __ocGetChildPids(managedRun.pid); } catch {} }, 5000);',
	'\tmanagedRun.wait()'
].join('\n');

if (!code.includes(OLD_SESSION)) {
	console.error('WARNING: could not patch session creation');
} else {
	code = code.replace(OLD_SESSION, NEW_SESSION);
	console.log('Patched: session creation (baseline PIDs + sessionKey)');
}

fs.writeFileSync(filePath, code, 'utf8');
console.log('\nAll patches applied to:', filePath);
console.log('Restart gateway to apply: openclaw gateway restart');
