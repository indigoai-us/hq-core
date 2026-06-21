---
id: hq-cluster-test-failures-by-root-cause
title: Cluster test failures by error message before claiming a fix is complete
scope: global
trigger: Investigating a failing test suite where multiple tests fail simultaneously
when: test
on: [UserPromptSubmit, AssistantIntent, PreToolUse]
enforcement: soft
tier: 1
public: true
version: 1
created: 2026-04-25
updated: 2026-04-25
source: session-learning
---

## Rule

NEVER conflate "failing tests" with "one root cause." When investigating test failures:

1. Group failing tests by their error message / stack signature into clusters
2. Characterize each cluster: what shared mechanism is breaking these tests?
3. Treat each cluster as an independent failure mode requiring its own fix
4. Land each fix as a separate, focused commit (or PR) — not a "fix the test suite" omnibus

When reporting status, partition the count: "Fixed 12 of 37 — remaining 25 split across 4 unrelated drift classes (brand renames, missing mock exports, CSS class drift, fixture path changes)." That report is correct. "Tests fixed" is wrong if any of the 25 remain red.

## Rationale

A failing test suite is rarely one bug. In practice, a single suite run can surface 4+ independent failure modes simultaneously — e.g. a UTF-8 byte-slice panic in one helper, a jsdom Storage regression across all tests using `localStorage`, brand-rename drift after a global string replace, missing mock exports from a refactored test util, and CSS class name drift from a design-system upgrade. Each has its own root cause, its own fix, and its own blast radius.

Treating "the tests are broken" as a single ticket creates two failure modes:

1. **Premature victory.** The first fix (often the largest cluster) green-lights confidence; remaining failures get rationalized as "drift" or "flakes" and shipped past. The 25 unaddressed failures stay red, mask future regressions, and erode trust in the suite over weeks.
2. **Bundled commits.** A "fix the test suite" commit conflates 4 unrelated changes. When one of them later regresses, bisect lands on the bundle and the team has to manually demix which change broke what.

Clustering by error message is a 2-minute discipline that preserves the suite as a precision instrument rather than a binary "passing / failing" indicator.
