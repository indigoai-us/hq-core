---
id: hq-static-regression-anchor-forbidden-pattern
title: Anchor forbidden patterns to their invocation context in static regression harnesses
scope: global
trigger: authoring or modifying a static regression harness (grep/regex-based test) that forbids a URL path, flag, or command substring
enforcement: hard
public: true
version: 1
created: 2026-04-22
updated: 2026-04-22
source: session-learning
---

## Rule

When a static regression harness (shell `grep`, ripgrep-based test, static analysis rule) forbids an orphan pattern — e.g. a URL path, CLI flag, or API shape that must never appear bare — **anchor the forbidden pattern to its invocation context** rather than matching the raw string.

Concrete examples:

- Forbidding a bare `gh api repos/...` call: use `^[^#]*gh api +repos/` (skip comment lines, require `gh api` invocation prefix) — not the bare path.
- Forbidding an SDK method: use `\b{sdkClient}\.{method}\(` — not just the method name.
- Forbidding a deprecated env var read: use `process\.env\.{VAR}\b` — not the bare identifier.

The harness's own documentation, prose rationale, or inline comments **must** be able to name the forbidden pattern without tripping the gate. Use `^[^#]*` to strip shell/markdown comment lines, `^[^"']*` to strip string-literal occurrences, or explicit structural anchors that only match at the call site.

Before landing any new regression harness, grep the repo for the forbidden pattern and confirm the harness's own definition file (README, skill file, test source) is NOT a match. If it is, the anchor is too loose.

## Rationale

A regression harness that trips on prose describing the regression gate is worse than useless — it produces false positives on the very documentation that teaches future contributors why the gate exists. Contributors then either delete the documentation (eroding institutional memory) or broaden the harness exclusions (eroding the gate itself). Both outcomes fail.

Anchoring to invocation context fixes both failure modes simultaneously: the harness only matches real call sites, and prose that names the forbidden pattern passes cleanly. The cost is a slightly more complex regex, and the benefit is that the harness and its documentation can coexist in the same repo — typically the same file.

Session evidence: a regression harness that forbade a bare URL pattern tripped on its own explanatory prose in the README. The fix was to anchor the pattern to the `gh api ` invocation prefix, which excluded comment lines and documentation mentions while still catching real API calls.
