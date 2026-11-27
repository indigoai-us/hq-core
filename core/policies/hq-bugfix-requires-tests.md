---
id: hq-bugfix-requires-tests
title: Risk-rated verification for bugfixes and PR reviews
scope: global
trigger: bug fix, broken behavior, regression, hotfix, pr review
when: test
on: [PreToolUse, UserPromptSubmit, AssistantIntent]
enforcement: soft
tier: 1
version: 2
created: 2026-04-05
updated: 2026-11-26
source: user-correction
public: true
---

## Rule

Match verification to the blast radius of the change.

1. **Require new behavioral tests for Tier A invariants and repeat regressions.** Add a behavioral, integration, or E2E test that fails without the fix when a bug affects:
   - tenant or cross-account isolation,
   - authentication, authorization, or access control,
   - billing, payments, or quota enforcement,
   - data corruption, data loss, or destructive migrations,
   - security boundaries or secret handling, or
   - a bug class that has already regressed before.
2. **Do not reject PRs for lacking a new unit test when risk is already bounded.** Reviewers (human or agent) must not reject or block a pull request for missing a new unit test when the change:
   - hardens types, schemas, or runtime invariants verified by typecheck, lint, or schema checks,
   - is a config, copy, workflow, or documentation change, or
   - is already covered by existing behavioral, integration, or E2E tests.
3. **Prefer behavioral checks over source-text pinning.** When adding a test, assert observable behavior or contract invariants. Avoid tests that read source files only to match implementation text. Never skip, weaken, or fake an existing test to make a PR pass.

## Rationale

Requiring a new unit test for every bugfix leads to heavily mocked and source-text-pinning tests that increase maintenance churn and cause false review rejections on low-risk fixes. Concentrating new behavioral and E2E coverage on high-impact invariants (isolation, auth, billing, data integrity, security) and repeat regressions protects critical paths while letting type-enforced, config, documentation, and already-covered fixes ship cleanly.
