---
id: hq-turbopack-stale-css-reset-dev-cache
title: Reset Turbopack dev cache when CSS changes don't surface in preview
scope: global
trigger: preview verification shows stale CSS after a source edit (Next.js 16 + Turbopack dev)
enforcement: soft
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
---

## Rule

When Turbopack's dev server keeps serving stale CSS after a source edit — especially across `_next/dev/static/chunks/*.css` where new utility classes or keyframes don't appear in the response — do all three:

1. `rm -rf .next/dev` (NOT `.next/` — leave build output alone)
2. Restart the dev server via `preview_stop` then `preview_start`
3. Re-run the verification query

Do NOT rely on `touch`-ing the source file, forcing a browser reload, or waiting for HMR to pick up the change — none of those reliably invalidate Turbopack's compiled chunk cache for CSS.

## Rationale

Turbopack writes compiled CSS chunks to `.next/dev/static/chunks/` and hashes them for cache busting, but its dev-mode invalidation has edge cases around Tailwind JIT regeneration, `@keyframes` additions, and class-name churn. Once a chunk is cached, subsequent requests for the same logical stylesheet can return the pre-edit bytes even though the source tree is fresh. `.next/dev` is the chunk cache; removing it forces a clean recompile on the next request. A full server restart is needed because the in-memory module graph also holds references to the stale chunk metadata.

Touch-reload, file-watcher nudges, and hard browser refresh all go through the same dev server, which is exactly where the stale cache lives — so they observe the same cached bytes. The `.next/dev` wipe + server restart is the shortest path back to ground truth.
