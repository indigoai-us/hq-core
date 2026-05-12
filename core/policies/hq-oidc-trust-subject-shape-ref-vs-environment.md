---
id: hq-oidc-trust-subject-shape-ref-vs-environment
title: GH Actions OIDC sub claim switches between ref and environment — use StringLike repo:*
scope: global
trigger: Writing or debugging an IAM role trust policy for GitHub Actions OIDC federation
enforcement: hard
public: true
version: 1
created: 2026-04-22
updated: 2026-04-22
source: back-pressure-failure
# applies_to: [aws]
---

## Rule

When a GitHub Actions job declares `environment: <name>`, the OIDC token's `sub` claim switches from

```
repo:<org>/<repo>:ref:refs/heads/<branch>
```

to

```
repo:<org>/<repo>:environment:<name>
```

The IAM trust policy must accept both shapes while staying locked to a single repo. Use one `StringLike` condition on `token.actions.githubusercontent.com:sub` with the value `repo:<org>/<repo>:*` — NOT two parallel `StringEquals` entries.

Good:

```json
{
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
    },
    "StringLike": {
      "token.actions.githubusercontent.com:sub": "repo:{your-org}/{your-repo}:*"
    }
  }
}
```

Bad (misses one of the two subject shapes):

```json
"StringEquals": {
  "token.actions.githubusercontent.com:sub":
    "repo:{your-org}/{your-repo}:ref:refs/heads/main"
}
```

When `AssumeRoleWithWebIdentity` returns `AccessDenied`, the fastest diagnosis is CloudTrail, not the trust JSON:

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --max-items 5 --output json \
  | jq -r '.Events[].CloudTrailEvent' | jq -r '.userIdentity.principalId // .userIdentity.sessionContext // .errorMessage'
```

The `userIdentity.principalId` field (or the decoded `sub` in the event) reveals the exact subject STS saw, which makes the ref-vs-environment mismatch immediately obvious.

## Rationale

On 2026-04-22, a scheduled smoke-test workflow began failing with `AccessDenied` after a migration from long-lived IAM user keys to OIDC federation. The trust policy looked correct for the deploy job (`environment: production` → env-based sub) but the scheduled smoke test had no `environment:` declaration, so its `sub` was ref-based. Re-reading the trust JSON several times showed nothing — it was literally a different claim shape. CloudTrail surfaced the mismatch in one query. `StringLike repo:<org>/<repo>:*` handles both without widening beyond the repo, and is strictly tighter than two separate `StringEquals` conditions because it forces the `repo:...` prefix.
