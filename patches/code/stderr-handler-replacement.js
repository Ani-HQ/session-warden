		onStderr: (chunk) => {
			if (session) {
				session.stderr += chunk;
				if (session.stderr.length > CLAUDE_LIVE_MAX_STDERR_CHARS) {
					closeLiveSession(session, "abort", createOutputLimitError(session, "Claude CLI stderr exceeded limit."));
					return;
				}
			}
		}