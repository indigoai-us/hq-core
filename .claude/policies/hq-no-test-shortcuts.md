---
id: hq-no-test-shortcuts
title: Never skip or work around failing tests
scope: global
trigger: test failure, flaky test, E2E failure, CI red
enforcement: hard
tier: 1
version: 1
created: 2026-04-04
updated: 2026-04-04
source: user-correction
public: true
---

## Rule

Always fix tests properly — never skip flaky tests, never add `test.skip` as a workaround, never create false positives. When a test fails, investigate root cause and fix it. This applies to unit tests, integration tests, and E2E tests equally.

Prohibited shortcuts:
- `test.skip` / `describe.skip` / `xit` / `xdescribe` as a workaround for failures
- Commenting out failing assertions
- Loosening assertions to make tests pass without fixing the underlying issue
- Marking tests as "known flaky" without a root cause fix

## Rationale

Tests are back-pressure that prevents broken code from shipping. Skipping a test removes that safety net and creates technical debt that compounds. False positives are worse than no test — they give false confidence. Every test failure is a signal worth investigating.
