function clearTurnTimers(turn) {
	if (turn.noOutputTimer) {
		clearTimeout(turn.noOutputTimer);
		turn.noOutputTimer = null;
	}
	if (turn.timeoutTimer) {
		clearTimeout(turn.timeoutTimer);
		turn.timeoutTimer = null;
	}
	if (turn.__progressTimer) {
		clearTimeout(turn.__progressTimer);
		turn.__progressTimer = null;
	}
}