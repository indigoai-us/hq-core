---
id: hq-cross-repo-privilege-tier-surface-scope
title: Surface scope + shortcuts before implementing new identity/privilege tiers
scope: global
trigger: proposing work that introduces a new identity tier, role, group, or privilege primitive across multiple repos (e.g. Cognito group, RBAC role, feature flag tier, API scope)
when: privilege || tier || role
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
public: true
version: 1
created: 2026-04-24
updated: 2026-04-24
source: user-correction
---

## Rule

Before implementing any new identity tier, role, group, or privilege primitive that will be referenced from more than one repo, STOP and surface to the user:

1. **Scope of the change** — which repos need updates, which IaC files define the primitive, which code paths will check it, which env vars/secrets it introduces.
2. **Alternative shortcuts** — can this be accomplished with an existing tier (add a user to an existing group), a config flag, a feature flag, or a one-off allowlist? At least one lightweight alternative MUST be surfaced.
3. **Governance cost** — new privilege primitives are trivially cheap to create and painful to audit. A new group, role, or feature-flag tier adds permanent surface area: future code reads it, future PRs check it, future audits must account for it.

Only proceed with the implementation AFTER the user explicitly picks the new-tier path over the shortcut alternatives.

### Signals that this rule applies

- Proposing a new Cognito group, IAM role, workspace membership, or team
- Adding a new `role` enum value, `permission` bit, or `scope` claim
- Introducing a new env var like `*_ADMIN_USERS`, `*_ALLOWED_ROLES`, or an allowlist that will be referenced from multiple services
- Creating a new feature-flag tier that gates more than one code path

### What "surface" means concretely

A message to the user of the form:

> This introduces a new `platform-admin` group that will be checked in three repos (middleware, IaC, authorizer). Alternative shortcuts:
>
> 1. Add the user to the existing `admin` group and gate the new UI behind an env-var allowlist — no new tier
> 2. Use a feature flag keyed on email, no auth-layer change
> 3. Proceed with the new tier as proposed
>
> Which path should I take?

## Rationale

Identity/privilege primitives are write-once, audit-forever. A group added in a 5-minute PR requires every future authorizer, middleware, and admin dashboard to account for it. The marginal cost of adding one tier is near-zero; the marginal cost of auditing a system with a dozen overlapping tiers is significant.

Surfacing scope + shortcuts upfront lets the user make the governance tradeoff explicitly instead of discovering it six months later during a cleanup.
