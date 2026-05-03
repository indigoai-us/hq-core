---
id: hq-oidc-migration-plan-both-subject-shapes
title: OIDC migration from IAM-user keys must plan for both ref-based and environment-based sub shapes
scope: global
trigger: Migrating a CI workflow (GH Actions, GitLab) from long-lived IAM keys to OIDC web identity federation
enforcement: hard
public: true
version: 1
created: 2026-04-22
updated: 2026-04-22
source: session-learning
# applies_to: [aws]
---

## Rule

Before cutting any workflow over from IAM-user access keys to OIDC federation, inventory ALL jobs that will assume the target role and classify each by subject shape:

| Job type | Typical `environment:` | OIDC `sub` claim shape |
|---|---|---|
| Deploy / release | `environment: production` (or staging) | `repo:<org>/<repo>:environment:<name>` |
| Scheduled smoke test | none | `repo:<org>/<repo>:ref:refs/heads/<branch>` |
| PR preview build | none (usually) | `repo:<org>/<repo>:pull_request` or `ref:` variant |
| Tag-triggered release | none | `repo:<org>/<repo>:ref:refs/tags/<tag>` |

The trust policy MUST accept every shape in use on day one. Use a single `StringLike` condition:

```json
"StringLike": {
  "token.actions.githubusercontent.com:sub": "repo:<org>/<repo>:*"
}
```

NOT two parallel `StringEquals` conditions — that pattern fails open when any future job adds a new shape (tag pushes, workflow_call, etc.) and fails closed right now for whichever shape you forgot.

The `repo:<org>/<repo>:*` wildcard stays locked to a single repo (the prefix is anchored), so it is strictly tighter than leaving the claim unconstrained while covering every legitimate variant.

## Rationale

An OIDC migration on a backend service passed the deploy job's first run but broke the scheduled smoke test immediately — both jobs hit the same role with different subject shapes. The fix was trivial (`StringEquals` → `StringLike`), but diagnosis burned an hour because the trust policy "looked right" for the only job anyone had tested. Planning both shapes upfront makes this a zero-downtime migration instead of a post-cutover scramble. The wildcard form is not a security compromise: the `repo:<org>/<repo>:` prefix is still byte-exact, so no other repo can assume the role.
