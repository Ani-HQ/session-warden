		closing: false,
		__baselineChildPids: new Set(),
		__sessionKey: params.context.params.sessionKey || null
	};
	setTimeout(() => { try { session.__baselineChildPids = __ocGetChildPids(managedRun.pid); console.error("[WATCHDOG] baseline captured:", [...session.__baselineChildPids].join(",")); } catch {} }, 30000);
	managedRun.wait()