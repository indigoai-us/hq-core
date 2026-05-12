---
id: hq-bugfix-requires-tests
title: Every bugfix must include test coverage
scope: global
trigger: bug fix, broken behavior, regression, hotfix
enforcement: soft
tier: 1
version: 1
created: 2026-04-05
updated: 2026-04-05
source: user-correction
public: true
---

## Rule

When fixing a bug or broken behavior, always add tests or E2E coverage that would catch the regression if it recurred. If unsure about test type or scope (unit vs integration vs E2E, which assertions), ask the user before proceeding.

A bugfix without a regression test is incomplete.

## Rationale

The attribution health 0.02x ROAS bug (time-window mismatch + lead preference) existed for weeks without detection. Adding E2E tests after the fix ensures the same class of bug is caught automatically. Bugs that are fixed without tests tend to recur — the test is the proof that the fix works and the guardrail that keeps it working.
