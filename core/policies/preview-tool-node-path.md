---
id: preview-tool-node-path
title: "preview_start requires absolute node paths (fnm not in PATH)"
scope: global
trigger: "preview_start fails with 'No such file or directory'"
enforcement: soft
version: 1
created: 2026-04-01
updated: 2026-04-01
source: task-completion
public: true
---

## Rule

The preview_start tool's shell environment does not have fnm (or nvm) in PATH. Commands like `npm`, `npx`, and bare `node` are not found.

When configuring launch.json entries:
1. Use `/opt/homebrew/bin/node` as `runtimeExecutable` (absolute path)
2. Use `node_modules/.bin/{tool}` (e.g. `node_modules/.bin/next`) in `runtimeArgs` instead of `npm run dev`
3. Next.js 16 uses Turbopack by default with no `--no-turbopack` opt-out. If Turbopack panics in dev, there is no webpack fallback — production Vercel builds use a different pipeline and are unaffected.

## Rationale

The Claude Preview MCP tool spawns processes directly without sourcing shell profiles (`.zshrc`, `.bashrc`). Since fnm is initialized via shell profile eval, `npm`/`npx`/`node` are not on PATH. Using absolute paths to the Homebrew-installed node binary bypasses this entirely. Discovered when {your-project} launch.json with `"runtimeExecutable": "npm"` failed repeatedly.
