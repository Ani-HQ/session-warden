#!/usr/bin/env node
// patch-watchdog-stall-cap.js — fix silent agent hangs on stalled connections.
//
// PROBLEM (observed 2026-06-08):
//   Agent CLI turns stall in ep_poll on half-open Anthropic API sockets (or a
//   hung MCP/child). The existing smart watchdog treats ANY rchar increase as
//   "I/O active" and extends up to __OC_MAX_WATCHDOG_EXTENSIONS (20) times at
//   __OC_WATCHDOG_IO_RECHECK_MS (30s) each = ~10 min of tolerating trickle
//   keepalive bytes before killing. Meanwhile the gateway abandons the turn at
//   its ~5 min ceiling, so the channel goes silent with no reply and the CLI
//   lingers. Confirmed: stalled procs show ~96-2279B rchar deltas (keepalive
//   noise), never real token streaming.
//
// FIX:
//   1. Require a MEANINGFUL rchar delta (> __OC_WATCHDOG_MIN_IO_BYTES) to count
//      as "I/O active". Trickle keepalives no longer fool the watchdog, so a
//      stalled turn is killed on the first check after no-output instead of
//      ~10 min later. Real token streaming (hundreds of KB / 30s) still extends.
//   2. Add a generous wall-clock HARD CAP (__OC_HARD_TURN_CAP_MS, 25 min) as a
//      final backstop so no turn can hang forever in any weird state. Generous
//      so it never kills legitimate long agent work (which keeps extending via
//      children / real streaming anyway).
//
//   The kill path (closeLiveSession -> managedRun.cancel + failTurn) already
//   terminates the child AND resets session state, so no extra reset is needed.
//
// Idempotent. Edits the CURRENT live runtime (which already has the IO-liveness
// watchdog). Does NOT touch patch-smart-watchdog.js (stale; would regress).
// MUST be re-run after every `npm update openclaw`.

const fs = require('fs');
const path = require('path');

const DIST = path.join(process.env.HOME, '.npm-global/lib/node_modules/openclaw/dist');
const files = fs.readdirSync(DIST);
const runtimeFile = files.find(f => /^execute\.runtime-.*\.js$/.test(f) && !f.includes('.pre-'));
if (!runtimeFile) { console.error('ERROR: runtime file not found in', DIST); process.exit(1); }

const filePath = path.join(DIST, runtimeFile);
let code = fs.readFileSync(filePath, 'utf8');

if (code.includes('__OC_HARD_TURN_CAP_MS') && code.includes('__OC_WATCHDOG_MIN_IO_BYTES')) {
	console.log('Already patched (stall-cap). No changes needed.');
	process.exit(0);
}

// sanity: confirm this runtime has the IO-liveness watchdog we're extending
if (!code.includes('const __OC_WATCHDOG_IO_RECHECK_MS = 30000;') ||
    !code.includes('const ioActive = rchar > 0 && lastRchar >= 0 && rchar > lastRchar;')) {
	console.error('ERROR: live runtime does not match expected IO-liveness watchdog shape.');
	console.error('Aborting to avoid a bad patch. Inspect the runtime manually.');
	process.exit(1);
}

// backup
const backup = `${runtimeFile}.pre-stallcap-${new Date().toISOString().replace(/[:.]/g, '-')}`;
fs.writeFileSync(path.join(DIST, backup), code, 'utf8');
console.log('Backup:', backup);

// 1) new constants after the recheck-interval constant
code = code.replace(
	'const __OC_WATCHDOG_IO_RECHECK_MS = 30000;',
	'const __OC_WATCHDOG_IO_RECHECK_MS = 30000;\n' +
	'const __OC_WATCHDOG_MIN_IO_BYTES = 65536;\n' +
	'const __OC_HARD_TURN_CAP_MS = 1500000;'
);
console.log('Patched: added __OC_WATCHDOG_MIN_IO_BYTES + __OC_HARD_TURN_CAP_MS');

// 2) meaningful I/O threshold
code = code.replace(
	'const ioActive = rchar > 0 && lastRchar >= 0 && rchar > lastRchar;',
	'const ioActive = rchar > 0 && lastRchar >= 0 && (rchar - lastRchar) > __OC_WATCHDOG_MIN_IO_BYTES;'
);
console.log('Patched: ioActive now requires a meaningful rchar delta');

// 3) wall-clock hard cap, checked before any extension logic
code = code.replace(
	'const pid = session.managedRun?.pid;\n\tconst extensions = turn.__noOutputExtensions || 0;',
	'const pid = session.managedRun?.pid;\n' +
	'\tconst __ocElapsedMs = Date.now() - (turn.startedAtMs || Date.now());\n' +
	'\tif (__ocElapsedMs > __OC_HARD_TURN_CAP_MS) {\n' +
	'\t\tconsole.error(`[WATCHDOG] hard turn cap exceeded for PID ${pid} (elapsed ${Math.round(__ocElapsedMs / 1e3)}s > ${Math.round(__OC_HARD_TURN_CAP_MS / 1e3)}s), killing`);\n' +
	'\t\tcloseLiveSession(session, "abort", createTimeoutError(session, `Turn exceeded hard cap of ${Math.round(__OC_HARD_TURN_CAP_MS / 1e3)}s (stalled connection) and was terminated.`));\n' +
	'\t\treturn;\n' +
	'\t}\n' +
	'\tconst extensions = turn.__noOutputExtensions || 0;'
);
console.log('Patched: wall-clock hard cap in __ocWatchdogCheck');

// verify all three landed
const ok = code.includes('__OC_WATCHDOG_MIN_IO_BYTES = 65536;') &&
           code.includes('(rchar - lastRchar) > __OC_WATCHDOG_MIN_IO_BYTES;') &&
           code.includes('__ocElapsedMs > __OC_HARD_TURN_CAP_MS');
if (!ok) { console.error('ERROR: one or more replacements did not apply. Not writing.'); process.exit(1); }

fs.writeFileSync(filePath, code, 'utf8');
console.log('\nApplied to:', filePath);
console.log('Restart gateway to take effect.');
