function __ocGetChildPids(pid) {
	if (!pid) return new Set();
	try {
		const out = __ocExecSync(`pgrep -P ${pid} 2>/dev/null`, { timeout: 3000, encoding: "utf8" });
		return new Set(out.trim().split("\n").filter(Boolean));
	} catch { return new Set(); }
}
function __ocGetProcessRchar(pid) {
	if (!pid) return -1;
	try {
		const out = __ocExecSync(`awk '/^rchar:/{print $2}' /proc/${pid}/io 2>/dev/null`, { timeout: 2000, encoding: "utf8" });
		const val = parseInt(out.trim(), 10);
		return Number.isFinite(val) ? val : -1;
	} catch { return -1; }
}
const __OC_WATCHDOG_IO_RECHECK_MS = 30000;
const __OC_MAX_WATCHDOG_EXTENSIONS = 20;
const __OC_PROGRESS_INTERVAL_MS = 30000;
const __OC_PROGRESS_MESSAGES = [
	["⚙️", "crunching...", "▰▰▱▱▱▱▱▱▱▱"],
	["🔧", "deep in the toolchain...", "▰▰▰▰▱▱▱▱▱▱"],
	["🧠", "thinking hard...", "▰▰▰▰▰▰▱▱▱▱"],
	["⛏️", "mining for answers...", "▰▰▰▰▰▰▰▰▱▱"],
	["🏗️", "still building...", "▰▰▰▰▰▰▰▰▰▱"],
	["🔬", "almost there...", "▰▰▰▰▰▰▰▰▰▰"],
	["🐢", "slow and steady...", "▰▰▰▱▱▱▱▱▱▱"],
	["🪄", "working some magic...", "▰▰▰▰▰▱▱▱▱▱"],
	["📡", "fetching data...", "▰▰▰▰▰▰▰▱▱▱"],
	["🧩", "piecing it together...", "▰▰▰▰▰▰▰▰▰▱"]
];
function __ocProgressHeartbeat(session) {
	const turn = session.currentTurn;
	if (!turn) return;
	const elapsed = Math.round((Date.now() - turn.startedAtMs) / 1000);
	const idx = (turn.__progressCount || 0) % __OC_PROGRESS_MESSAGES.length;
	turn.__progressCount = (turn.__progressCount || 0) + 1;
	const mins = Math.floor(elapsed / 60);
	const secs = elapsed % 60;
	const timeStr = mins > 0 ? mins + "m " + secs + "s" : secs + "s";
	const [emoji, text, bar] = __OC_PROGRESS_MESSAGES[idx];
	const msg = emoji + " " + text + " (" + timeStr + ")\n" + bar;
	const sessionKey = session.__sessionKey;
	if (sessionKey) {
		try {
			executeDeps.enqueueSystemEvent(msg, { sessionKey, contextKey: "progress:heartbeat" });
			executeDeps.requestHeartbeatNow(scopedHeartbeatWakeOptions(sessionKey, { reason: "cli:progress:heartbeat" }));
			console.error(`[PROGRESS] heartbeat sent for ${sessionKey} (${timeStr}, tick ${turn.__progressCount})`);
		} catch (e) { console.error(`[PROGRESS] heartbeat failed: ${e.message}`); }
	}
	turn.__progressTimer = setTimeout(() => __ocProgressHeartbeat(session), __OC_PROGRESS_INTERVAL_MS);
}
function resetNoOutputTimer(session) {
	const turn = session.currentTurn;
	if (!turn) return;
	if (turn.noOutputTimer) clearTimeout(turn.noOutputTimer);
	turn.__noOutputExtensions = 0;
	turn.noOutputTimer = setTimeout(() => {
		__ocWatchdogCheck(session, session.noOutputTimeoutMs);
	}, session.noOutputTimeoutMs);
}
function __ocWatchdogCheck(session, timeoutMs) {
	const turn = session.currentTurn;
	if (!turn) return;
	const pid = session.managedRun?.pid;
	const extensions = turn.__noOutputExtensions || 0;
	const baseline = session.__baselineChildPids || new Set();
	const current = __ocGetChildPids(pid);
	const newChildren = [...current].filter(p => !baseline.has(p));
	if (extensions < __OC_MAX_WATCHDOG_EXTENSIONS && newChildren.length > 0) {
		turn.__noOutputExtensions = extensions + 1;
		console.error(`[WATCHDOG] new children detected: ${newChildren.join(",")} (ext ${turn.__noOutputExtensions}/${__OC_MAX_WATCHDOG_EXTENSIONS}), extending`);
		if (turn.noOutputTimer) clearTimeout(turn.noOutputTimer);
		turn.noOutputTimer = setTimeout(() => { __ocWatchdogCheck(session, timeoutMs); }, timeoutMs);
		return;
	}
	const rchar = __ocGetProcessRchar(pid);
	const lastRchar = turn.__lastWatchdogRchar ?? -1;
	turn.__lastWatchdogRchar = rchar;
	const ioActive = rchar > 0 && lastRchar >= 0 && rchar > lastRchar;
	if (extensions < __OC_MAX_WATCHDOG_EXTENSIONS && ioActive) {
		turn.__noOutputExtensions = extensions + 1;
		const delta = rchar - lastRchar;
		console.error(`[WATCHDOG] I/O active (+${delta}B rchar, ext ${turn.__noOutputExtensions}/${__OC_MAX_WATCHDOG_EXTENSIONS}), rechecking in ${__OC_WATCHDOG_IO_RECHECK_MS / 1000}s`);
		if (turn.noOutputTimer) clearTimeout(turn.noOutputTimer);
		turn.noOutputTimer = setTimeout(() => { __ocWatchdogCheck(session, timeoutMs); }, __OC_WATCHDOG_IO_RECHECK_MS);
		return;
	}
	if (extensions >= __OC_MAX_WATCHDOG_EXTENSIONS) {
		console.error(`[WATCHDOG] max extensions (${__OC_MAX_WATCHDOG_EXTENSIONS}) reached for PID ${pid}, killing`);
	} else {
		console.error(`[WATCHDOG] no stdout, no new children, no I/O activity for PID ${pid} (rchar=${rchar}, lastRchar=${lastRchar}), killing`);
	}
	closeLiveSession(session, "abort", createTimeoutError(session, `CLI produced no output for ${Math.round(timeoutMs / 1e3)}s and was terminated.`));
}