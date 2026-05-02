	turn.__noOutputExtensions = 0;
	turn.__progressCount = 0;
	turn.__progressTimer = setTimeout(() => __ocProgressHeartbeat(params.session), __OC_PROGRESS_INTERVAL_MS);
	turn.noOutputTimer = setTimeout(() => {
		__ocWatchdogCheck(params.session, params.noOutputTimeoutMs);
	}, params.noOutputTimeoutMs);