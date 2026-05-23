# OpenClaw patches (contrib)

These scripts patch OpenClaw's compiled JavaScript to fix specific runtime issues. They are version-specific and must be re-run after every `npm update -g openclaw`.

These patches are maintained on a best-effort basis. They work by locating known code patterns in compiled JS and replacing them. When OpenClaw updates change the compiled output structure, patches may need updating.

## Available patches

### patch-output-limits.sh

Bumps hardcoded stdout buffer limits that kill sessions mid-turn when processing large outputs (images, long tool results).

```bash
bash contrib/openclaw-patches/patch-output-limits.sh
```

### patch-smart-watchdog.js

Replaces the naive no-output watchdog with one that checks for running child processes before killing. Also adds periodic progress messages so the team knows the agent is alive during long turns.

```bash
node contrib/openclaw-patches/patch-smart-watchdog.js
```

### patch-error-humanizer.sh

Rewrites generic error messages into human-readable messages using Gemini Flash.

```bash
bash contrib/openclaw-patches/patch-error-humanizer.sh
```

### patch-manager.js (AI-powered)

Uses Gemini Flash to locate code patterns semantically, regardless of filename or structure changes. Define patches as JSON manifests in `patches/manifests/`.

```bash
node contrib/openclaw-patches/patch-manager.js apply --all
node contrib/openclaw-patches/patch-manager.js list
```

## Writing new patches

Create a JSON manifest in `patches/manifests/` and the replacement code in `patches/code/`. See existing manifests for the format.
