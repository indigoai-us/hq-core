---
id: hq-tsup-dts-ship-prebuilt-dist
title: Ship pre-built dist for tsup libraries — don't rely on install-time rebuilds
scope: global
trigger: publishing or consuming a tsup-built TypeScript library with a `prepare` script that regenerates `.d.ts` on install
enforcement: soft
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
---

## Rule

NEVER trust `tsup --dts` to produce consistent `.d.ts` output across install environments. When a consumer `npm install`s the library from git, the `prepare` script runs inside the consumer's nested `node_modules/<lib>/` directory, not the library's source repo. Environmental differences change the output:

- Parent `tsconfig.json` leakage — TypeScript's default config resolution walks up the directory tree. A nested install inside a consumer repo with its own tsconfig can silently inherit `strict`, `moduleResolution`, `paths`, or `jsx` settings that alter declaration emit.
- Module resolution paths differ — `@types/*` packages available in the source repo may be absent or different versions under the consumer's lockfile.
- Runtime tsup/TypeScript versions may differ if the library pins neither exactly.

Result: the `.d.ts` a consumer sees after `npm install` is NOT the same as what `tsup` produced in the source repo. Exported types go missing, generics collapse to `any`, or entire modules fail to resolve.

**Fix:** commit the `dist/` tree to git (for `github:owner/repo` installs) or publish to npm with `files: ["dist"]`. Keep `prepare` for local dev only, or drop it entirely and rely on an explicit `build` script gated behind CI.

## Rationale

`tsup`'s DTS generation invokes the TypeScript compiler with an ephemeral config derived from the library's `tsconfig.json` + flags. That config assumes the library's source tree is the project root. When npm/pnpm triggers `prepare` inside a nested install path, TypeScript's config discovery walks up from `node_modules/<lib>/src/` and finds the *consumer's* tsconfig first — which was never written with this library in mind. The same input code compiles to different declarations in the two locations. Shipping the dist tree directly makes install deterministic and removes an entire class of "types broken for my teammate but not me" reports.
