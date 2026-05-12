---
id: nextjs-suspense-dev-fallback
title: "Next.js Turbopack Suspense dev-mode stuck fallback"
scope: global
trigger: "preview verification of RSC pages showing Loading..."
enforcement: soft
version: 1
created: 2026-03-12
updated: 2026-03-12
public: true
---

## Rule

When a Next.js 16 app with Turbopack dev mode shows RSC pages stuck on their Suspense fallback ("Loading...") despite the server returning 200, do not debug the issue in dev mode. Run `npm run build` instead and verify the correct page count in build output — a successful production build with the expected page count is the authoritative verification signal.

## Rationale

Turbopack's dev-mode streaming implementation can leave RSC Suspense boundaries stuck on their fallback state even when the server responds correctly. This is a known dev-mode artifact, not a production bug. Spending time debugging Suspense rendering in dev mode wastes effort — the production build is the ground truth. If the build passes and produces the expected number of pages, the feature is working correctly.

## Examples

**Correct:**
- App shows "Loading..." on RSC page in dev mode → run `npm run build` → build succeeds with 34 pages → consider it verified, move on

**Incorrect:**
- App shows "Loading..." on RSC page in dev mode → spend time adding `loading.tsx` overrides, changing Suspense boundaries, or re-fetching strategies trying to fix a dev-mode artifact
