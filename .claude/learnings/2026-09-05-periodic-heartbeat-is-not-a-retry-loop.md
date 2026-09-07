# Any "N identical events means something is wrong" detector needs a time window, or every scheduled job becomes a false positive

**Problem shape:** a detector declares a fault from repetition alone: the last N
tool calls are identical, the last N log lines match, the last N requests are the
same. It fires correctly on the pathology it was written for, and then it fires
forever on a healthy periodic job that happens to emit exactly the same event on
a schedule. In Session Warden this was `burn_detect_loop`: six identical tool
calls in the transcript tail meant "stuck in a retry loop", and an OpenClaw agent
woken hourly to run one fixed probe produced six identical calls too, just spread
over six hours.

**The procedure:**
1. When a repetition detector misfires, do not tune N. Raising the repeat count
   only delays a periodic emitter, it never excludes it, because a heartbeat will
   always reach any N given enough hours.
2. Find the dimension the two cases actually differ on. For repetition it is
   almost always **rate**: the pathology emits as fast as it can, the schedule
   emits at its period. Retry loops append within seconds; heartbeats are 30 to
   60 minutes apart, so anything from a couple of minutes up to about ten sits in
   a wide, safe gap.
3. Add the rate test as an AND on the existing rule, never as a replacement.
   Identical AND inside the window. The old rule still has to hold, so nothing
   that used to be caught stops being caught for a timing reason.
4. Carry the per-event timestamp from the enclosing record, not from the event.
   In JSONL transcripts the `timestamp` lives on the line, while the `tool_use`
   block lives inside `message.content[]`, so bind the line before you iterate
   its content: `. as $line | .message.content[]? | {..., ts: ($line.timestamp)}`.
5. Make missing timestamps fall back to the old rule rather than to "no alert".
   A detector that silently goes quiet on data it cannot parse is worse than one
   that occasionally over-reports, because nobody notices the silence.
6. Check the alert throttle interacts sanely. A cooldown does not save you here:
   if the scan interval is shorter than the cooldown and the periodic event lands
   just before a scan, the signature is fresh again on every cooldown expiry, so
   the page repeats at exactly the cooldown period, forever.

**Why this works / the trap it avoids:** repetition is a proxy for "not making
progress", and the proxy is only valid when the repetitions are tightly packed.
Spread the same events over hours and repetition stops implying anything at all,
because a healthy scheduler is definitionally a machine that repeats. The time
span between the first and last of the N restores what the proxy was standing in
for: work that is retrying, rather than work that is scheduled. It is also the
cheapest possible discriminator. No state, no history, no per-agent config, just
two numbers already present on the lines being read.

**Evidence:** Session Warden, 2026-09-05. Agent `isaac` ran an hourly heartbeat
turn (`ls ~/.openclaw/handoffs/isaac/*.md; df -h /`, then reply HEARTBEAT_OK) and
paged as "looks stuck in a retry loop" every hour from Sep 3 to Sep 5, plus a hit
on Aug 27, while its session tokens grew about 1k per hour, which is to say it
was idle. Fixed by `WARDEN_LOOP_WINDOW_SECS` (default 600) in `lib/burn.sh`:
the last N identical calls now also have to span 600 seconds or less. See
`tests/test-burn.sh` for the hourly-vs-tight pair.
