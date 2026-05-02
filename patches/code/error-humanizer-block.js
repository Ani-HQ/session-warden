		try {
			const _hResp = await fetch("https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${GEMINI_API_KEY}", {
				method: "POST",
				headers: {"Content-Type": "application/json"},
				body: JSON.stringify({contents:[{parts:[{text:"You are a witty, self-aware AI agent who just hit an error. Rewrite this error in your own voice: be nerdy, a little self-deprecating, and human. Keep it to 2 sentences max. Include the actual technical error in the middle so the user knows what happened. No emoji walls. Error: " + (message || fallbackText)}]}],generationConfig:{maxOutputTokens:256,temperature:0.9,thinkingConfig:{thinkingBudget:0}}}),
				signal: AbortSignal.timeout(3000)
			});
			const _hData = await _hResp.json();
			const _hText = _hData?.candidates?.[0]?.content?.parts?.[0]?.text?.trim();
			if (_hText && _hText.length > 10 && _hText.length < 500) fallbackText = _hText;
		} catch(_hErr) { /* keep original on failure */ }