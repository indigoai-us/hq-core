---
id: hq-rust-helper-extension-audit-call-sites
title: When fixing a helper bug class, audit all call sites — don't ship a parallel safe helper
scope: global
trigger: Discovering a bug class in a shared helper function (Rust, TypeScript, Python — language-agnostic). Examples: `truncate_str` panicking on non-ASCII, `parse_int` accepting negatives, `escape_html` missing an entity
enforcement: hard
public: true
version: 1
created: 2026-04-25
updated: 2026-04-25
source: session-learning
---

## Rule

ALWAYS audit every existing call site of a buggy helper before declaring the fix done. The default fix is to repair the original helper in place, not to introduce a parallel "safer" version (e.g. `truncate_str` → `truncate_chars`) and leave the original.

Workflow when you find a helper bug:

1. Grep all call sites of the original helper (`rg -n 'truncate_str\(' --type rust`)
2. For each call site, classify: does it carry the bug? (e.g. could the input be non-ASCII?)
3. Fix the original helper signature in place — every call site benefits without code churn
4. If the fix changes the signature meaningfully (return type, parameter shape), update every call site in the same change
5. Only introduce a parallel helper when the new behavior is genuinely additive (different semantics, different return type) AND the old helper is correct for its existing callers

Anti-pattern: ship `truncate_chars` next to `truncate_str`, document "use the new one going forward," and leave 12 latent panics in the existing tree.

## Rationale

Parallel helpers create two compounding problems:

1. **Latent bugs persist** — every existing call site is still wired to the unsafe helper. The bug ships every time those code paths run on real input. The "fix" is paper.
2. **Confusion at every new call site** — future authors face two near-identical helpers and pick wrong half the time. The codebase grows two slowly-diverging implementations and the team's mental model fractures.

Fixing in place avoids both. The helper's contract was always "truncate this string safely"; the bug was an implementation defect, not a design choice. Repairing the implementation matches the original contract and propagates the fix to every existing caller for free.

When the signature genuinely needs to change (e.g. `truncate_str(s, n) -> &str` → `truncate_chars(s, n) -> String` because borrowing no longer works), do the migration as one change: rename, update all call sites, delete the old function. Don't half-migrate.
