---
id: hq-vitest-conversion-keep-assert-strict
title: Keep node:assert/strict when converting test files between Node --test and vitest
scope: global
trigger: converting a test file from Node's built-in `--test` runner to vitest (or vice versa)
enforcement: soft
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
---

## Rule

ALWAYS keep `import { ... } from 'node:assert/strict'` (and all `assert.*` calls in the test body) unchanged when converting a test file between Node's `--test` runner and vitest. The test framework (`describe`/`it`/`beforeAll`) and the assertion library are orthogonal APIs — swapping one does not require swapping the other.

Correct conversion shape:

```diff
- import { describe, it, before } from 'node:test';
+ import { describe, it, beforeAll } from 'vitest';
  import assert from 'node:assert/strict';  // ← unchanged

  describe('foo', () => {
-   before(async () => { ... });
+   beforeAll(async () => { ... });
    it('does the thing', () => {
      assert.equal(actual, expected);  // ← unchanged, do not rewrite to expect(actual).toBe(expected)
    });
  });
```

Do NOT rewrite `assert.equal(a, b)` → `expect(a).toBe(b)` during the conversion. That's a separate, optional refactor.

## Rationale

A 3-line import swap is dramatically easier to review than a 14-line `assert.*` → `expect(...)` rewrite. Vitest runs `node:assert` assertions natively — there is no behavioral benefit to rewriting them. Reviewers spend their attention on the framework migration (the actual concern) rather than on mechanical assertion rewrites. If a subsequent PR wants to adopt `expect()` for better error messages or snapshot support, that's a standalone refactor with its own justification.
