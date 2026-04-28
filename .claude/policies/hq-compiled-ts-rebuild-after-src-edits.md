---
id: hq-compiled-ts-rebuild-after-src-edits
title: Rebuild dist after editing src in compiled TypeScript packages — never hand-edit dist
scope: global
trigger: editing a fallback constant, default config, or any runtime value in `src/` of a compiled TypeScript package whose published artifact lives in `dist/`
enforcement: soft
public: true
version: 1
created: 2026-04-25
updated: 2026-04-25
source: session-learning
---

## Rule

When updating any runtime value (model fallback, default URL, version constant, feature flag default) in a compiled TypeScript package, follow this exact sequence:

1. Edit the value in `src/` only.
2. Run `npm run typecheck` (or equivalent) — fix any type errors before continuing.
3. Run `npm run build` (or the package's publish-build script).
4. Verify the new value is present in `dist/`: `grep -r "<new-value>" dist/`.
5. Verify the OLD value is gone from `dist/`: `grep -r "<old-value>" dist/` should return zero matches.

**Never** hand-edit a `dist/` file. Even when the change looks trivial, the next `npm run build` will silently overwrite your edit and reintroduce the old value. The codex-engine pattern (and every tsup/tsc/esbuild output tree) is regenerated from `src/` — `dist/` is an artifact, not source.

If `dist/` is committed to git (common for `github:owner/repo`-style installs), commit the rebuilt `dist/` in the same commit as the `src/` edit — don't split them across commits.

## Rationale

Two recurring failure modes:

- **Hand-editing `dist/` only:** the change ships once, then the next routine rebuild regresses runtime to the old value. Hard to debug because git blame on `src/` looks correct.
- **Editing `src/` and forgetting to rebuild:** the consumer installs the package and sees the old value because `dist/` still contains it. Especially common with `prepare` scripts that don't re-trigger after a manual `npm install` from a local path or git tag.

The `typecheck → build → grep dist` ritual is short, mechanical, and catches both cases. The final `grep dist` step is the load-bearing part — it's the negative scan that proves the old value is gone from the artifact, not just the source. Pair it with a positive `grep` for the new value to confirm the build actually emitted what you expect.
