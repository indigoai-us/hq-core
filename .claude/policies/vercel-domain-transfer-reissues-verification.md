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

