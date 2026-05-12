---
id: vercel-deploy-checks
enforcement: hard
scope: global
tags: [vercel, deploy, company-isolation, sso, framework-detection]
public: true
created: 2026-05-11
provenance: claude-md-extracted
---

## Rule

Before any `vercel deploy`, `vercel --prod`, `vercel link`, or other Vercel CLI write operation:

1. **Verify org/team.** Run `vercel whoami` and `vercel teams ls`. The active scope MUST match the company's `vercel_team` in `companies/manifest.yaml`. Cross-company deploys are blocked by the Cross-Company Credential Isolation rule — this is the verification step.
2. **Confirm framework detection.** Vercel's auto-detection can pick the wrong framework on monorepos, custom `package.json` shapes, or projects with sibling `next.config` files. Read the project's `vercel.json` (or run `vercel inspect`) and compare against expected framework before letting the build run.
3. **Do not chase preview SSO failures.** Vercel preview deploys gated behind team SSO routinely produce `401 Unauthorized` for unauthenticated visitors. This is expected, not a deploy bug. If verification needs an SSO-free URL, fall back to local testing (`vercel dev`, `bun run dev`, or repo-native dev server) instead of trying to disable SSO, generate bypass tokens, or whitelist IPs.

## Rationale

- Wrong-team deploys are a hard-to-reverse blast: a live deployment to the wrong customer's project, billed to the wrong account, surfacing the wrong domain. Two-second `vercel whoami` averts that.
- Framework misdetection silently breaks the deploy *after* the build — wasted ~5 minutes of CI time and a confusing failure mode.
- SSO debugging is a rabbit hole; many sessions have burned >30 min trying to "get the preview URL to work" before reverting to local verification. The local fallback is faster and equivalent for most pre-merge checks.

## Related

- Cross-Company Credential Isolation (Rule in `.claude/CLAUDE.md`) — never deploy to one company's project from another's context
- `companies/manifest.yaml` — `vercel_team` per company
