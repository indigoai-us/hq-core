---
id: hq-confirm-session-scope-after-plan-approval
title: Confirm per-session execution scope after ExitPlanMode for multi-phase or high-blast-radius plans
scope: global
trigger: an `ExitPlanMode`-approved plan that spans 3+ phases, contains production-mutating steps (live API calls, git tag push, repo rename, DNS change, payment/auth provider mutations), or is structured as a multi-session migration
when: /plan || /deep-plan || /brainstorm
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
public: true
version: 1
created: 2026-04-24
updated: 2026-04-24
source: session-learning
---

## Rule

ALWAYS confirm the user's per-session execution scope before starting work when an approved plan meets ANY of:

- Spans 3+ distinct phases / checkpoints
- Touches production infrastructure (live API mutations, DNS records, paid-tier provider state, git tag push, repo rename, package publish)
- Is framed as a migration, cutover, or multi-session effort

Users frequently approve the **shape** of a large plan via `ExitPlanMode` without intending to execute every phase in the current turn. Treat plan approval as a scope-confirmed design, not an execute-all authorization.

Before beginning the first mutating step, use `AskUserQuestion` to pose a single scope question such as:

> "Plan is approved. How far should I take this in the current session — through Phase 1 only, through Phase N, or all the way to production cutover?"

Offer 2–4 concrete stopping points tied to the phases in the plan. Record the chosen stopping point and stop when reached, even if time/tokens remain.

This rule does NOT apply when:
- The plan is a single phase or a trivially reversible edit set
- The user explicitly said "execute the full plan in this session" at approval time
- The plan was already framed as "Phase 1 only" and the approval referred to that single phase

## Rationale

Observed during a multi-phase migration session where the user approved a Phase 1→4 plan intending only Phase 1 to run today. Without a scope-confirmation step, the assistant treated `ExitPlanMode` approval as authorization for the entire plan. Blast-radius thresholds (live APIs, DNS, tag pushes) make silent over-execution expensive to reverse; a 10-second confirmation before the first mutation is cheap insurance.

Composes with `core/policies/hq-announce-before-irreversible.md` (per-action authorization) by gating the overall session envelope rather than each individual step.
