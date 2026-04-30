#!/usr/bin/env bash
# patch-error-humanizer.sh — patches OpenClaw gateway to use Gemini Flash
# for humanizing error messages instead of showing generic "Something went wrong"
#
# FRAGILE: operates on compiled JS, will need re-running after openclaw updates.
# Safe to re-run (idempotent: checks for marker before patching).

set -euo pipefail

OPENCLAW_DIR="${HOME}/.npm-global/lib/node_modules/openclaw"
TARGET_FILE="${OPENCLAW_DIR}/dist/agent-runner.runtime-BoV2OgHJ.js"
BACKUP_FILE="${TARGET_FILE}.pre-humanizer-backup"
MARKER="__OPENCLAW_ERROR_HUMANIZER_PATCHED__"

if [ ! -f "$TARGET_FILE" ]; then
  echo "ERROR: target file not found: $TARGET_FILE"
  echo "OpenClaw may have been updated — check for new filename."
  find "$OPENCLAW_DIR/dist" -name "agent-runner.runtime-*.js" -type f 2>/dev/null
  exit 1
fi

if grep -q "$MARKER" "$TARGET_FILE" 2>/dev/null; then
  echo "Already patched (marker found). Skipping."
  exit 0
fi

GEMINI_KEY=$(jq -r '.models.providers.google.apiKey // empty' "${HOME}/.openclaw/openclaw.json" 2>/dev/null)
if [ -z "$GEMINI_KEY" ]; then
  echo "ERROR: no Google API key found in openclaw.json"
  exit 1
fi

cp "$TARGET_FILE" "$BACKUP_FILE"
echo "Backed up to: $BACKUP_FILE"

node -e "
const fs = require('fs');
let file = fs.readFileSync(process.argv[1], 'utf8');
const key = process.argv[2];
const marker = process.argv[3];
let changed = false;

// 1) Replace sync fallback string with error-detail version
const syncOld = '⚖️ Something went wrong while processing your request. Please try again, or use /new to start a fresh session.';
// Use a regex to be safe with unicode
const syncRe = /return \"[^\"]*Something went wrong while processing your request[^\"]*\";/;
if (syncRe.test(file)) {
  file = file.replace(syncRe, 'return \"⚠️ Ran into a hiccup: \" + collapseRepeatedFailureDetail(message).slice(0, 200) + \". Try again, or use /new to start fresh.\"; /* ' + marker + ' */');
  changed = true;
}

// 2) const fallbackText -> let fallbackText (using regex to handle any whitespace)
if (/\bconst fallbackText = isBilling\b/.test(file)) {
  file = file.replace(/\bconst fallbackText = isBilling\b/, 'let fallbackText = isBilling');
  changed = true;
}

// 3) Insert Gemini humanizer after buildExternalRunFailureText(message);
const anchor = 'buildExternalRunFailureText(message);';
if (file.includes(anchor) && !file.includes('_hResp')) {
  const geminiBlock = anchor + \`
\t\t\ttry {
\t\t\t\tconst _hResp = await fetch(\"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=\${key}\", {
\t\t\t\t\tmethod: \"POST\",
\t\t\t\t\theaders: {\"Content-Type\": \"application/json\"},
\t\t\t\t\tbody: JSON.stringify({contents:[{parts:[{text:\"You are a witty, self-aware AI agent who just hit an error. Rewrite this error in your own voice: be nerdy, a little self-deprecating, and human. Keep it to 2 sentences max. Include the actual technical error in the middle so the user knows what happened. No emoji walls. Error: \" + (message || fallbackText)}]}],generationConfig:{maxOutputTokens:256,temperature:0.9,thinkingConfig:{thinkingBudget:0}}}),
\t\t\t\t\tsignal: AbortSignal.timeout(3000)
\t\t\t\t});
\t\t\t\tconst _hData = await _hResp.json();
\t\t\t\tconst _hText = _hData?.candidates?.[0]?.content?.parts?.[0]?.text?.trim();
\t\t\t\tif (_hText && _hText.length > 10 && _hText.length < 500) fallbackText = _hText;
\t\t\t} catch(_hErr) { /* keep original on failure */ }\`;
  file = file.replace(anchor, geminiBlock);
  changed = true;
}

if (!changed) {
  console.error('ERROR: no patch targets found — file structure may have changed');
  process.exit(1);
}

fs.writeFileSync(process.argv[1], file);
console.log('Patched successfully.');
" "$TARGET_FILE" "$GEMINI_KEY" "$MARKER"

echo "Patch applied. Restart gateway to take effect."
echo "  openclaw gateway restart"
