#!/usr/bin/env bash
# test-progress-card.sh — bar, throttle, message-id reuse

source "$WARDEN_HOME/lib/progress-card.sh"

echo "  progress-card: bar and percent"

assert_eq "████░░░░░░░░░░" "$(progress_card_bar 2 7 14)" "2/7 fills two of fourteen"
assert_eq "██████████░░░░░░" "$(progress_card_bar 10 16 16)" "10/16 fills ten of sixteen"
assert_eq "░░░░" "$(progress_card_bar 0 10 4)" "zero done is empty bar"
assert_eq "████" "$(progress_card_bar 10 10 4)" "complete is full bar"
assert_eq "40" "$(progress_card_percent 23 57)" "23/57 is 40 percent"
assert_eq "0" "$(progress_card_percent 0 0)" "zero total is 0 percent"

echo "  progress-card: tone and body"

assert_eq "info" "$(progress_card_tone start)" "start is info"
assert_eq "info" "$(progress_card_tone update)" "update is info"
assert_eq "success" "$(progress_card_tone "done")" "done is success"
assert_eq "danger" "$(progress_card_tone blocked)" "blocked is danger"

body=$(progress_card_body "Dahej tier-1" 23 57 "Flow-Tech Valves" "wrote row 23")
assert_contains "$body" "Dahej tier-1  23/57" "body names the task and count"
assert_contains "$body" "40%" "body includes percent"
assert_contains "$body" "now  Flow-Tech Valves" "body includes now line"
assert_contains "$body" "last wrote row 23" "body includes last line"

echo "  progress-card: presentation"

pres=$(progress_card_presentation "Dahej" "info" "hello" "https://example.com/sheet")
assert_contains "$pres" '"type": "url"' "sheet becomes a URL button"
assert_contains "$pres" "Open sheet" "button label is Open sheet"
assert_contains "$pres" "https://example.com/sheet" "sheet URL is in the presentation"

plain=$(progress_card_presentation "Dahej" "info" "hello" "")
assert_not_contains "$plain" "Open sheet" "no sheet button without a URL"

echo "  progress-card: infer + slug"

assert_eq "channel:1464144827741376522" \
  "$(progress_card_infer_discord "agent:dash:discord:channel:1464144827741376522")" \
  "infer discord snowflake from session key"
assert_eq "channel:99" "$(progress_card_normalize_discord_target "99")" \
  "bare snowflake becomes channel:id"
assert_eq "dash-agent_dash_discord_channel_1" \
  "$(progress_card_slug dash "agent:dash:discord:channel:1")" \
  "slug sanitizes the channel key"

echo "  progress-card: throttle"

export WARDEN_PROGRESS_THROTTLE_SECONDS=45
export WARDEN_PROGRESS_EVERY_N=5
unset PROGRESS_CARD_FORCE

fresh=$(jq -n --argjson ts "$(date +%s)" '{done:20, now:"a", last_sent_at:$ts}')
rc=0; progress_card_should_emit start 0 "" "" || rc=$?
assert_eq "0" "$rc" "start always emits"
rc=0; progress_card_should_emit "done" 57 "x" "$fresh" || rc=$?
assert_eq "0" "$rc" "done always emits"
rc=0; progress_card_should_emit blocked 20 "stuck" "$fresh" || rc=$?
assert_eq "0" "$rc" "blocked always emits"
rc=0; progress_card_should_emit update 21 "a" "$fresh" || rc=$?
assert_eq "1" "$rc" "one more item inside 45s is throttled"
rc=0; progress_card_should_emit update 25 "a" "$fresh" || rc=$?
assert_eq "0" "$rc" "plus five items emits even inside 45s"

old=$(jq -n --argjson ts "$(( $(date +%s) - 50 ))" '{done:20, now:"a", last_sent_at:$ts}')
rc=0; progress_card_should_emit update 21 "b" "$old" || rc=$?
assert_eq "0" "$rc" "changed now after 45s emits"
rc=0; progress_card_should_emit update 20 "a" "$old" || rc=$?
assert_eq "1" "$rc" "unchanged after 45s stays quiet"

export PROGRESS_CARD_FORCE=1
rc=0; progress_card_should_emit update 21 "a" "$fresh" || rc=$?
assert_eq "0" "$rc" "--force bypasses throttle"
unset PROGRESS_CARD_FORCE

echo "  progress-card: parse and merge ids"

assert_eq "m1" "$(progress_card_parse_message_id '{"messageId":"m1"}')" \
  "parse messageId"
assert_eq "m2" "$(progress_card_parse_message_id '{"result":{"id":"m2"}}')" \
  "parse result.id"

merged=$(progress_card_merge_message '{"messages":[]}' discord "channel:1" "abc")
assert_eq "abc" "$(progress_card_existing_id "$merged" discord "channel:1")" \
  "merge stores the id"
merged=$(progress_card_merge_message "$merged" discord "channel:1" "def")
assert_eq "def" "$(progress_card_existing_id "$merged" discord "channel:1")" \
  "merge replaces the same target"

echo "  progress-card: send then edit reuses id"

mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/openclaw" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$SANDBOX/openclaw-invocations"
if [ "\$2" = "send" ]; then
  echo '{"messageId":"card-1"}'
elif [ "\$2" = "edit" ]; then
  echo '{"messageId":"card-1"}'
fi
MOCK
chmod +x "$SANDBOX/bin/openclaw"
export PATH="$SANDBOX/bin:$PATH"
: > "$SANDBOX/openclaw-invocations"

export WARDEN_DRY_RUN=0
rm -f "$(progress_card_state_path "$(progress_card_slug dash "agent:dash:discord:channel:1")")"

out=$("$WARDEN_HOME/bin/progress-card.sh" start \
  --agent dash \
  --channel "agent:dash:discord:channel:1" \
  --title "Dahej tier-1" \
  --done 0 --total 57 \
  --now "starting" \
  --discord-target "channel:1")
assert_contains "$out" "sent 1" "start delivers once"
assert_file_exists "$(progress_card_state_path "$(progress_card_slug dash "agent:dash:discord:channel:1")")" \
  "start writes state"
assert_contains "$(tr '\n' ' ' < "$SANDBOX/openclaw-invocations")" "message send" "start calls message send"

: > "$SANDBOX/openclaw-invocations"
out=$("$WARDEN_HOME/bin/progress-card.sh" update \
  --agent dash \
  --channel "agent:dash:discord:channel:1" \
  --done 1 --total 57 \
  --now "company 1")
assert_contains "$out" "skipped throttle" "immediate +1 is throttled"
assert_not_contains "$(cat "$SANDBOX/openclaw-invocations")" "message" "throttled tick does not call openclaw"

: > "$SANDBOX/openclaw-invocations"
out=$("$WARDEN_HOME/bin/progress-card.sh" update \
  --agent dash \
  --channel "agent:dash:discord:channel:1" \
  --done 5 --total 57 \
  --now "company 5")
assert_contains "$out" "sent 1" "plus five items delivers"
inv=$(tr '\n' ' ' < "$SANDBOX/openclaw-invocations")
assert_contains "$inv" "message edit" "follow-up edits in place"
assert_contains "$inv" "--message-id card-1" "edit reuses the start id"

echo "  progress-card: dual targets"

rm -f "$(progress_card_state_path "$(progress_card_slug dash "agent:dash:discord:channel:1")")"
: > "$SANDBOX/openclaw-invocations"
out=$("$WARDEN_HOME/bin/progress-card.sh" start \
  --agent dash \
  --channel "agent:dash:discord:channel:1" \
  --title "Dahej" \
  --total 10 \
  --discord-target "channel:1" \
  --telegram-target "999")
assert_contains "$out" "sent 2" "start fans out to discord and telegram"

echo "  progress-card: dry-run"

export WARDEN_DRY_RUN=1
: > "$SANDBOX/openclaw-invocations"
out=$("$WARDEN_HOME/bin/progress-card.sh" start \
  --agent dash \
  --channel "agent:dash:other" \
  --title "x" --total 1 \
  --discord-target "channel:9")
assert_contains "$out" "sent 1" "dry-run still reports sent"
assert_empty "$(cat "$SANDBOX/openclaw-invocations")" "dry-run does not invoke openclaw"
unset WARDEN_DRY_RUN
