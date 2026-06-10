#!/usr/bin/env node
// patch-manager.js — AI-powered patch manager for OpenClaw compiled JS
// Uses Gemini Flash to locate code patterns regardless of filename/structure changes.
// Part of session-warden: https://github.com/ani-computer/session-warden

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

// patches/ lives alongside this script (contrib/openclaw-patches/patches/)
const PATCHES_ROOT = process.env.WARDEN_PATCHES_ROOT || __dirname;
const MANIFESTS_DIR = path.join(PATCHES_ROOT, 'patches', 'manifests');
const CODE_DIR = path.join(PATCHES_ROOT, 'patches', 'code');
const REGION_PADDING = 60;
const LLM_TIMEOUT_MS = 45000;
const MAX_LLM_RETRIES = 1;

// ──────────────────────────────────────────────
// OpenClaw discovery
// ───��──────────────────────────────────────────

function findDistDir() {
	const home = process.env.HOME;
	const candidates = [
		path.join(home, '.npm-global/lib/node_modules/openclaw/dist'),
	];
	try {
		const root = execSync('npm root -g 2>/dev/null', { encoding: 'utf8' }).trim();
		if (root) candidates.push(path.join(root, 'openclaw/dist'));
	} catch {}
	for (const d of candidates) {
		if (fs.existsSync(d)) return d;
	}
	return null;
}

function getApiKey() {
	const p = path.join(process.env.HOME, '.openclaw/openclaw.json');
	if (!fs.existsSync(p)) return null;
	try {
		const cfg = JSON.parse(fs.readFileSync(p, 'utf8'));
		return cfg?.models?.providers?.google?.apiKey || null;
	} catch { return null; }
}

// ──────────────────────────────────────────────
// LLM interaction
// ──────────────────────────────────────────────

const LLM_SYSTEM = `You are a precise code analysis assistant. You find specific code patterns in compiled JavaScript and return their exact text.

Rules:
1. Copy text EXACTLY as it appears — preserve every space, tab, quote, backtick, and newline
2. For function boundaries: from the function keyword through the final closing brace (matching brace depth)
3. Text you return must be a verbatim substring of the provided code
4. Choose text long enough to be unique in the file
5. Return valid JSON only — no markdown fences, no commentary`;

async function queryLLM(systemPrompt, userPrompt, opts = {}) {
	const apiKey = getApiKey();
	if (!apiKey) throw new Error('No Gemini API key in ~/.openclaw/openclaw.json');

	const { thinkingBudget = 2048, maxTokens = 8192 } = opts;
	const body = {
		systemInstruction: { parts: [{ text: systemPrompt }] },
		contents: [{ parts: [{ text: userPrompt }] }],
		generationConfig: {
			maxOutputTokens: maxTokens,
			temperature: 0,
			responseMimeType: 'application/json',
			thinkingConfig: { thinkingBudget }
		}
	};

	const resp = await fetch(
		`https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${apiKey}`,
		{
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(body),
			signal: AbortSignal.timeout(LLM_TIMEOUT_MS)
		}
	);

	if (!resp.ok) {
		const errText = await resp.text().catch(() => '');
		throw new Error(`LLM API ${resp.status}: ${errText.slice(0, 300)}`);
	}

	const data = await resp.json();
	const parts = data?.candidates?.[0]?.content?.parts || [];
	const text = parts.filter(p => p.text).map(p => p.text).join('');
	if (!text) throw new Error('Empty LLM response');

	try { return JSON.parse(text); } catch {}

	// Try to extract JSON object from text
	const m = text.match(/\{[\s\S]*\}/);
	if (m) {
		try { return JSON.parse(m[0]); } catch {}
		// LLM may have put real newlines inside JSON string values — fix them
		try {
			const fixed = m[0].replace(/"text"\s*:\s*"([\s\S]*?)(?:"\s*[,}])/g, (match, content) => {
				const escaped = content
					.replace(/\\/g, '\\\\')
					.replace(/\n/g, '\\n')
					.replace(/\r/g, '\\r')
					.replace(/\t/g, '\\t')
					.replace(/"/g, '\\"');
				return match.replace(content, escaped);
			});
			return JSON.parse(fixed);
		} catch {}
		// Last resort: extract text between first "text": " and last "
		const textMatch = m[0].match(/"text"\s*:\s*"([\s\S]*)"[\s\S]*\}/);
		if (textMatch) {
			const rawText = textMatch[1]
				.replace(/\\n/g, '\n')
				.replace(/\\t/g, '\t')
				.replace(/\\"/g, '"')
				.replace(/\\\\/g, '\\');
			return { text: rawText };
		}
	}
	throw new Error(`LLM returned non-JSON: ${text.slice(0, 300)}`);
}

// ──────────────────────────────────────────────
// File discovery
// ──────────────────────────────────────────────

async function findTargetFile(distDir, target) {
	const jsFiles = fs.readdirSync(distDir)
		.filter(f => f.endsWith('.js') && !f.includes('.pre-') && !f.includes('.backup'));

	const scored = [];
	for (const file of jsFiles) {
		const content = fs.readFileSync(path.join(distDir, file), 'utf8');
		const hits = target.grep_hints.filter(h => content.includes(h)).length;
		if (hits > 0) scored.push({ file, hits, total: target.grep_hints.length });
	}
	scored.sort((a, b) => b.hits - a.hits);

	if (scored.length > 0 && scored[0].hits === target.grep_hints.length) {
		return scored[0].file;
	}

	if (scored.length > 0) return scored[0].file;

	// Last resort: ask LLM
	const result = await queryLLM(LLM_SYSTEM,
		`JavaScript files in OpenClaw dist:\n${jsFiles.slice(0, 80).join('\n')}\n\n` +
		`Which file best matches: "${target.semantic_description}"\n\n` +
		`Return: { "file": "filename.js" }`,
		{ thinkingBudget: 512, maxTokens: 256 }
	);
	return (result.file && jsFiles.includes(result.file)) ? result.file : null;
}

// ──────────────────────────────────────────────
// Region extraction (narrows context for LLM)
// ──────────────────────────────────────────────

function extractRegion(lines, searchHints, padding) {
	const hintLines = [];
	for (const hint of searchHints) {
		for (let i = 0; i < lines.length; i++) {
			if (lines[i].includes(hint)) hintLines.push(i);
		}
	}
	if (hintLines.length === 0) return { start: 0, end: lines.length - 1 };
	const start = Math.max(0, Math.min(...hintLines) - padding);
	const end = Math.min(lines.length - 1, Math.max(...hintLines) + padding);
	return { start, end };
}

function formatRegion(lines, start, end) {
	return lines.slice(start, end + 1)
		.map((l, i) => `${start + i + 1}| ${l}`)
		.join('\n');
}

// ──────────────────────────────────────────────
// Anchor finding via LLM
// ──────────────────────────────────────────────

async function findAnchorText(code, step, retries = MAX_LLM_RETRIES) {
	const lines = code.split('\n');
	const { start, end } = extractRegion(lines, step.search_hints || [], REGION_PADDING);
	const region = formatRegion(lines, start, end);

	const taskMap = {
		find_function: `Find the COMPLETE function described below. Return the exact text from the function declaration line through its closing brace (match brace depth). The text must be a verbatim, character-for-character substring of the code.`,
		find_block: `Find the COMPLETE code block described below. Return the exact text of every line in the block. The text must be a verbatim, character-for-character substring of the code.`,
		find_line: `Find the single line described below. Return its exact text. The text must be a verbatim, character-for-character substring of the code.`,
		find_insertion_point: `Find the line described below. This line will serve as an insertion anchor — new code will be placed AFTER it. Return its exact text as a verbatim substring of the code.`,
	};

	const findType = step.find_type || 'find_function';
	const task = taskMap[findType] || taskMap.find_function;

	const prompt = `${task}\n\nDescription: ${step.semantic_anchor}\n\n` +
		`Code (lines ${start + 1}-${end + 1}):\n\`\`\`javascript\n${region}\n\`\`\`\n\n` +
		`Return: { "text": "exact verbatim text from the code above (without line number prefixes)" }`;

	const result = await queryLLM(LLM_SYSTEM, prompt);
	let text = result.text;
	if (!text) throw new Error('LLM returned no text field');

	// Strip any accidental line-number prefixes the LLM might have copied
	text = text.replace(/^\d+\| /gm, '');

	// Try several normalization strategies to match
	const candidates = [
		text,
		text.trim(),
		text.replace(/\r\n/g, '\n'),
		text.replace(/\r\n/g, '\n').trim(),
		// Handle LLM returning escaped chars as literals
		text.replace(/\\n/g, '\n').replace(/\\t/g, '\t'),
		text.replace(/\\n/g, '\n').replace(/\\t/g, '\t').trim(),
	];

	for (const c of candidates) {
		if (c && code.includes(c)) return c;
	}

	// Fuzzy: collapse runs of whitespace and try matching against similarly collapsed code
	const fuzzyAnchor = text.replace(/[\t ]+/g, ' ').trim();
	const codeLines = code.split('\n');
	for (let i = 0; i < codeLines.length; i++) {
		for (let span = 1; span <= 15 && i + span <= codeLines.length; span++) {
			const block = codeLines.slice(i, i + span).join('\n');
			const fuzzyBlock = block.replace(/[\t ]+/g, ' ').trim();
			if (fuzzyBlock === fuzzyAnchor) {
				console.log(`    Anchor matched via fuzzy whitespace (lines ${i + 1}-${i + span})`);
				return block;
			}
		}
	}

	if (retries > 0) {
		console.log('    Anchor not found in code, retrying LLM...');
		return findAnchorText(code, step, retries - 1);
	}

	throw new Error(`Anchor text not found in code. LLM returned ${text.length} chars starting with: "${text.slice(0, 120)}..."`);
}

// ──────────────────────────────────────────────
// Step handlers
// ──────────────────────────────────────────────

function unescapeReplacements(s) {
	return s.replace(/\\n/g, '\n').replace(/\\t/g, '\t');
}

function handleRegexReplace(code, step) {
	const flags = step.flags || '';
	const re = new RegExp(step.pattern, flags);
	if (!re.test(code)) {
		return { code, applied: false, reason: `Pattern not found: ${step.pattern.slice(0, 80)}` };
	}
	const replacement = unescapeReplacements(step.replacement);
	const result = code.replace(re, replacement);
	return { code: result, applied: true };
}

function handleAddImport(code, step) {
	if (code.includes(step.import_line)) {
		return { code, applied: true }; // already present = success
	}
	if (!code.includes(step.after)) {
		return { code, applied: false, reason: `Anchor import not found: ${step.after.slice(0, 60)}` };
	}
	return { code: code.replace(step.after, step.after + '\n' + step.import_line), applied: true };
}

async function handleAiReplace(code, step) {
	const anchor = await findAnchorText(code, step);

	let newCode = step.code || '';
	if (step.code_file) {
		newCode = fs.readFileSync(path.join(CODE_DIR, step.code_file), 'utf8').trimEnd();
	}
	newCode = resolveTemplateVars(newCode, step.template_vars);

	const result = code.replace(anchor, newCode);
	return result === code
		? { code, applied: false, reason: 'Replacement had no effect' }
		: { code: result, applied: true };
}

function replaceNthOccurrence(str, search, replacement, n) {
	let pos = -1;
	for (let i = 0; i < n; i++) {
		pos = str.indexOf(search, pos + 1);
		if (pos === -1) return str;
	}
	return str.slice(0, pos) + replacement + str.slice(pos + search.length);
}

function handleStringInject(code, step) {
	const anchor = step.anchor;
	if (!code.includes(anchor)) {
		return { code, applied: false, reason: `Anchor string not found: ${anchor.slice(0, 60)}` };
	}

	let injection = step.code || '';
	if (step.code_file) {
		injection = fs.readFileSync(path.join(CODE_DIR, step.code_file), 'utf8').trimEnd();
	}
	injection = resolveTemplateVars(injection, step.template_vars);

	const position = step.position || 'after';
	const occurrence = step.occurrence || 1;
	const replacement = position === 'after'
		? anchor + '\n' + injection
		: injection + '\n' + anchor;

	const result = replaceNthOccurrence(code, anchor, replacement, occurrence);
	return result === code
		? { code, applied: false, reason: 'Injection had no effect' }
		: { code: result, applied: true };
}

async function handleAiInject(code, step) {
	const anchor = await findAnchorText(code, {
		...step,
		find_type: step.find_type || 'find_insertion_point'
	});

	let injection = step.code || '';
	if (step.code_file) {
		injection = fs.readFileSync(path.join(CODE_DIR, step.code_file), 'utf8').trimEnd();
	}
	injection = resolveTemplateVars(injection, step.template_vars);

	const position = step.position || 'after';
	const result = position === 'after'
		? code.replace(anchor, anchor + '\n' + injection)
		: code.replace(anchor, injection + '\n' + anchor);

	return result === code
		? { code, applied: false, reason: 'Injection had no effect' }
		: { code: result, applied: true };
}

function resolveTemplateVars(code, vars) {
	if (!vars) return code;
	for (const [key, value] of Object.entries(vars)) {
		let resolved = value;
		if (value === '{{GEMINI_API_KEY}}') {
			const cfg = JSON.parse(fs.readFileSync(
				path.join(process.env.HOME, '.openclaw/openclaw.json'), 'utf8'
			));
			resolved = cfg?.models?.providers?.google?.apiKey || '';
		}
		code = code.split('${' + key + '}').join(resolved);
	}
	return code;
}

// ──────────────────────────────────────────────
// Manifest loading
// ──────────────────────────────────────────────

function loadManifests() {
	if (!fs.existsSync(MANIFESTS_DIR)) return [];
	return fs.readdirSync(MANIFESTS_DIR)
		.filter(f => f.endsWith('.json'))
		.sort()
		.map(f => {
			const m = JSON.parse(fs.readFileSync(path.join(MANIFESTS_DIR, f), 'utf8'));
			m._file = f;
			return m;
		});
}

// ──────────────────────────────────────────────
// Patch application
// ──────────────────────────────────────────────

async function applyPatch(distDir, manifest, flags) {
	const id = manifest.id;
	console.log(`\n--- ${manifest.name} (${id}) ---`);

	// Check dependencies
	for (const dep of (manifest.depends_on || [])) {
		if (!isPatchApplied(distDir, dep)) {
			console.log(`  SKIP: dependency "${dep}" not applied`);
			return { id, status: 'dependency_missing', dep };
		}
	}

	// Find target file
	console.log('  Finding target file...');
	const targetFile = await findTargetFile(distDir, manifest.target);
	if (!targetFile) {
		console.error('  ERROR: target file not found');
		return { id, status: 'file_not_found' };
	}
	const targetPath = path.join(distDir, targetFile);
	console.log(`  Target: ${targetFile}`);

	let code = fs.readFileSync(targetPath, 'utf8');

	// Check if already applied
	if (manifest.marker && code.includes(manifest.marker)) {
		if (!flags.force) {
			console.log('  Already applied (marker found)');
			return { id, status: 'already_applied' };
		}
		console.log('  Already applied but --force specified, re-applying...');
	}

	// Check for legacy markers
	for (const lm of (manifest.legacy_markers || [])) {
		if (code.includes(lm) && !flags.force) {
			console.log(`  Legacy patch detected (${lm}). Use --force to re-apply.`);
			return { id, status: 'legacy_applied' };
		}
	}

	if (flags.dryRun) {
		console.log(`  DRY RUN: would apply ${manifest.steps.length} steps`);
		return { id, status: 'dry_run' };
	}

	// Backup
	const backupName = `${targetFile}.pre-warden-${Date.now()}`;
	const backupPath = path.join(distDir, backupName);
	fs.writeFileSync(backupPath, code, 'utf8');
	console.log(`  Backup: ${backupName}`);

	// Apply steps
	for (let i = 0; i < manifest.steps.length; i++) {
		const step = manifest.steps[i];
		const label = step.description || step.id || `step-${i + 1}`;
		console.log(`  [${i + 1}/${manifest.steps.length}] ${label}`);

		let result;
		try {
			switch (step.type) {
				case 'regex_replace':
					result = handleRegexReplace(code, step);
					break;
				case 'add_import':
					result = handleAddImport(code, step);
					break;
				case 'ai_replace':
					result = await handleAiReplace(code, step);
					break;
				case 'string_inject':
					result = handleStringInject(code, step);
					break;
				case 'ai_inject':
					result = await handleAiInject(code, step);
					break;
				default:
					result = { code, applied: false, reason: `Unknown type: ${step.type}` };
			}
		} catch (err) {
			console.error(`    FAILED: ${err.message}`);
			fs.copyFileSync(backupPath, targetPath);
			console.log('    Restored from backup');
			return { id, status: 'failed', error: err.message, step: label };
		}

		if (!result.applied) {
			if (step.required === false) {
				console.log(`    SKIPPED (optional): ${result.reason}`);
			} else {
				console.error(`    FAILED: ${result.reason}`);
				fs.copyFileSync(backupPath, targetPath);
				console.log('    Restored from backup');
				return { id, status: 'failed', error: result.reason, step: label };
			}
		} else {
			code = result.code;
			console.log('    OK');
		}
	}

	// Add marker as first line comment
	if (manifest.marker) {
		code = `// ${manifest.marker}\n` + code;
	}

	fs.writeFileSync(targetPath, code, 'utf8');

	// Verify
	const v = verifyPatch(targetPath, manifest.verify);
	if (!v.ok) {
		console.error(`  VERIFY FAILED: ${v.reason}`);
		fs.copyFileSync(backupPath, targetPath);
		console.log('  Restored from backup');
		return { id, status: 'verify_failed', error: v.reason };
	}

	console.log('  APPLIED');
	return { id, status: 'applied' };
}

// ──────────────────────────────────────────────
// Verification
// ──────────────────────────────────────────────

function isPatchApplied(distDir, idOrMarker) {
	const manifests = loadManifests();
	const manifest = manifests.find(m => m.id === idOrMarker);
	const marker = manifest ? manifest.marker : idOrMarker;
	if (!marker) return false;

	const jsFiles = fs.readdirSync(distDir)
		.filter(f => f.endsWith('.js') && !f.includes('.pre-') && !f.includes('.backup'));
	for (const file of jsFiles) {
		if (fs.readFileSync(path.join(distDir, file), 'utf8').includes(marker)) return true;
	}
	return false;
}

function verifyPatch(filePath, verifySpec) {
	if (!verifySpec) return { ok: true };
	const content = fs.readFileSync(filePath, 'utf8');
	for (const s of (verifySpec.present || [])) {
		if (!content.includes(s)) return { ok: false, reason: `Missing: "${s.slice(0, 60)}"` };
	}
	for (const s of (verifySpec.absent || [])) {
		if (content.includes(s)) return { ok: false, reason: `Unexpected: "${s.slice(0, 60)}"` };
	}
	return { ok: true };
}

// ──────────────────────────────────────────────
// Commands
// ──────────────────────────────────────────────

async function cmdApply(distDir, flags) {
	const manifests = loadManifests();
	if (manifests.length === 0) {
		console.log('No patch manifests found in', MANIFESTS_DIR);
		return;
	}

	const selected = flags.patch
		? manifests.filter(m => m.id === flags.patch || m._file === flags.patch)
		: manifests;

	if (selected.length === 0) {
		console.error(`Patch not found: ${flags.patch}`);
		console.log('Available:', manifests.map(m => m.id).join(', '));
		process.exit(1);
	}

	const results = [];
	for (const m of selected) {
		results.push(await applyPatch(distDir, m, flags));
	}

	console.log('\n=== Summary ===');
	for (const r of results) {
		const icon = { applied: '+', already_applied: '=', dry_run: '~', legacy_applied: '~' }[r.status] || 'x';
		const detail = r.error ? ` (${r.error.slice(0, 80)})` : '';
		console.log(`  [${icon}] ${r.id}: ${r.status}${detail}`);
	}

	const applied = results.filter(r => r.status === 'applied').length;
	if (applied > 0) {
		console.log(`\n${applied} patch(es) applied. Restart gateway:`);
		console.log('  openclaw gateway restart');
	}
}

async function cmdStatus(distDir) {
	const manifests = loadManifests();
	if (manifests.length === 0) {
		console.log('No patch manifests found.');
		return;
	}
	for (const m of manifests) {
		const applied = isPatchApplied(distDir, m.id);
		const icon = applied ? '+' : 'x';
		console.log(`[${icon}] ${m.id} — ${m.name}`);
		if (m.description) console.log(`    ${m.description}`);
	}
}

function cmdList() {
	const manifests = loadManifests();
	if (manifests.length === 0) {
		console.log('No patch manifests found.');
		return;
	}
	for (const m of manifests) {
		console.log(`${m.id} (${m.steps.length} steps)`);
		console.log(`  ${m.name}: ${m.description || ''}`);
		if (m.depends_on?.length) console.log(`  Depends: ${m.depends_on.join(', ')}`);
	}
}

function usage() {
	console.log(`Usage: patch-manager.js <command> [options]

Commands:
  apply       Apply all pending patches (default)
  status      Show which patches are applied
  list        List available patch manifests

Options:
  --dry-run   Show what would change without modifying files
  --force     Re-apply even if marker/legacy patch detected
  --patch=ID  Apply only a specific patch
  -v          Verbose output`);
	process.exit(0);
}

// ──────────────────────────────────────────────
// Main
// ──────────────────────────────────────────────

async function main() {
	const args = process.argv.slice(2);
	if (args.includes('--help') || args.includes('-h')) usage();

	const command = args.find(a => !a.startsWith('-')) || 'apply';
	const flags = {
		dryRun: args.includes('--dry-run'),
		force: args.includes('--force'),
		verbose: args.includes('--verbose') || args.includes('-v'),
		patch: args.find(a => a.startsWith('--patch='))?.split('=')[1],
	};

	const distOverride = args.find(a => a.startsWith('--dist-dir='))?.split('=')[1];
	const distDir = distOverride || findDistDir();
	if (!distDir) {
		console.error('ERROR: OpenClaw dist directory not found');
		process.exit(1);
	}
	console.log(`OpenClaw dist: ${distDir}`);

	switch (command) {
		case 'apply': return cmdApply(distDir, flags);
		case 'status': return cmdStatus(distDir);
		case 'list': return cmdList();
		default: usage();
	}
}

main().catch(err => {
	console.error(`FATAL: ${err.message}`);
	if (process.env.DEBUG) console.error(err.stack);
	process.exit(1);
});
