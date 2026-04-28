---
id: hq-oidc-access-denied-diagnose-via-cloudtrail
title: Diagnose OIDC AccessDenied via CloudTrail userIdentity, never by re-reading trust JSON
scope: global
trigger: Debugging AssumeRoleWithWebIdentity AccessDenied errors in GH Actions, GitLab CI, or any OIDC federation
enforcement: hard
public: true
version: 1
created: 2026-04-22
updated: 2026-04-22
source: session-learning
# applies_to: [aws]
---

## Rule

When `AssumeRoleWithWebIdentity` returns `AccessDenied`, do NOT start by re-reading the IAM trust policy JSON. It almost always looks syntactically correct — the mismatch is in the `sub` claim STS actually received, which you cannot see in the trust doc.

ALWAYS pull the CloudTrail event for the failing call first:

```bash
aws cloudtrail lookup-events \
  --lookup-attributes EventName=AssumeRoleWithWebIdentity \
  --max-items 10 --output json \
  | jq -r '.Events[].CloudTrailEvent' \
  | jq 'select(.errorCode == "AccessDenied") | {errorMessage, principalId: .userIdentity.principalId, sessionContext: .userIdentity.sessionContext}'
```

`userIdentity.principalId` contains the exact subject STS compared against the trust policy. That single field reveals:

- ref-vs-environment mismatch (see `hq-oidc-trust-subject-shape-ref-vs-environment`)
- wrong repo name / org case
- wrong branch for ref-based subs
- missing `aud` claim

Only after CloudTrail exposes the real subject should you edit the trust JSON.

## Rationale

Trust policy JSON is a static document; the failure mode is a runtime claim shape mismatch. Humans (and LLMs) re-reading the JSON repeatedly see what they expect to see and miss that the claim token said `:environment:production` when the condition matched `:ref:refs/heads/main`. CloudTrail is the only place the actual subject appears in plain text, and the query completes in seconds. Skipping it wastes debugging cycles on the least informative artifact.
