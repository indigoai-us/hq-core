---
id: hq-nextjs-clean-types-after-page-delete
title: Clean .next cache after deleting Next.js pages
scope: global
trigger: deleting a page file from a Next.js app, then running typecheck
enforcement: soft
version: 1
created: 2026-03-29
updated: 2026-03-29
source: task-completion
public: true
---

## Rule

After deleting a Next.js page file, run `rm -rf .next` before `tsc --noEmit` or `pnpm typecheck`. The `.next/types/validator.ts` cache retains references to deleted pages and causes false TS2307 errors.

## Rationale

Discovered when deleting `site/src/app/donate/page.tsx` — typecheck failed with "Cannot find module '../../src/app/donate/page.js'" from the cached validator until `.next` was cleared.
