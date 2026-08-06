---
id: hq-pack-policies-excluded-from-core-release
title: Builder/admin-only pack content stays out of the hq-core release — but an adopted capability pack may be promoted into core
when: pack
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
public: true
version: 2
created: 2026-05-27
updated: 2026-08-06
source: session-learning
tags: [infrastructure, hq-core, hq-packages]
---

## Rule

Builder-only and admin-only pack content — the `hq-pack-admin` tooling, release
plumbing, and anything that only makes sense inside the HQ build org — is
deliberately EXCLUDED from the base hq-core release. Keep it in its pack and
listed under `core.yaml` exclusions. That part of this policy is unchanged.

Capability packs are different. A pack whose contributions have become
load-bearing for ordinary HQ users MAY be promoted wholesale into core —
skills, workers, knowledge, policies, and hooks together. Promotion is a
deliberate, one-time decision made by the HQ owner, not something to infer.

When deciding where a new default-tooling or capability policy belongs:

- If the concern is builder/admin-only → the pack, and exclude it from the
  release.
- If the concern is optional tooling not yet adopted as an HQ default → the
  pack, so hosts that skip the pack do not inherit irrelevant guardrails.
- If the concern is already an HQ-wide default that core assumes → `core/policies`.

## Precedent

`hq-pack-engineering` was promoted into core on 2026-08-06 (23 skills, 6
workers, 4 knowledge sets, 3 policies, 3 hooks). Its guardrails —
`e2e-testing-standards`, `hq-bugfix-requires-tests`, `hq-no-test-shortcuts` —
now ship with the base release because HQ's own charter already treats them as
non-negotiable, so gating them behind an optional install left core asserting
rules it did not ship.

Note the one exception made during that promotion: the pack's older, soft copy
of `hq-prefer-agent-browser` was NOT copied over the newer hard-enforcement
version already in core. When promoting a pack, diff every colliding file
rather than copying wholesale — a pack can carry a stale fork of something core
has since advanced.

## Rationale

hq-core is the lean release-shipped scaffold, so the default answer for
optional tooling is still "put it in the pack." But leanness is not an absolute:
when nearly every host installs a pack and core's own charter depends on its
rules, the split costs more than it saves. The test is adoption, not category.
