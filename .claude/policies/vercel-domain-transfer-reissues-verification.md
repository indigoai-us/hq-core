---
id: hq-vercel-domain-transfer-reissues-verification
title: Vercel domain transfer between projects reissues vc-domain-verify TXT
scope: global
trigger: moving a Vercel domain from one project to another on the same team
enforcement: soft
public: true
version: 1
created: 2026-04-15
updated: 2026-04-15
source: task-completion
applies_to: [vercel]
---

## Rule

ALWAYS: When transferring a Vercel domain between projects on the same team (DELETE from project A → POST to project B), expect Vercel to issue a NEW `vc-domain-verify` TXT token and return `verified:false` on the POST. The `_vercel.{apex}` TXT RRset is multi-valued (one token per subdomain across all projects on the team), so UPSERT the new token into the existing RRset preserving all prior values, wait for DNS propagation, then POST `/v9/projects/{project}/domains/{domain}/verify` to complete the transfer.

ALWAYS: If a subdomain redirect shim (e.g. `old-alias.example.com` → `target.example.com`) exists in the source project, DELETE the shim BEFORE deleting the target domain — otherwise the DELETE returns `409 domain_is_redirect` and blocks the transfer.

ALWAYS: Ship the `next.config.mjs` host-matched redirect commit to the destination project BEFORE transferring the domain. This closes the zero-duplicate-content window: the moment DNS starts resolving the transferred domain to the destination, the first request is already a 308, never a direct content serve.

NEVER: Assume `vercel domains add {domain} --force` can transfer a domain across projects via the CLI — it returns 403 when the domain is claimed by another project. Use the REST API (`/v9/projects/{id}/domains/{domain}`) with the CLI's auth token directly.

## Rationale

Discovered during `hq.{your-domain}.ai → www.{your-domain}.ai` consolidation (apr 2026):

1. `vercel domains add hq.{your-domain}.ai --force` → 403 Not authorized — CLI doesn't cross the project boundary
2. `DELETE /v9/projects/{source-project}/domains/hq.{your-domain}.ai` → 409 `domain_is_redirect` because `{shim}.{your-domain}.ai` was a redirect shim pointing to it; had to delete the shim first
3. `POST /v9/projects/{destination-project}/domains` succeeded but returned `verified:false` with a fresh pending TXT token (`a628900f063c4f5739b3`), even though the previous project's token (`3e91f0fc6eb7a5d29a3e`) was still in DNS. Vercel treats the transfer as a fresh ownership claim
4. Route53 UPSERT had to submit the ENTIRE existing RRset (4 prior tokens for sibling subdomains) plus the new token, because UPSERT replaces the full set — dropping values would have broken unrelated subdomain verifications
5. `POST /verify` then returned `verified:true` and the 308 redirect went live immediately

The pre-flight `next.config.mjs` redirect commit ensured there was no window during which `hq.{your-domain}.ai` served content directly from the destination project — the redirect rule was live before Vercel even routed traffic there.
