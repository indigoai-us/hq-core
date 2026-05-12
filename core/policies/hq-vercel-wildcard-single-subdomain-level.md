---
id: hq-vercel-wildcard-single-subdomain-level
title: Vercel wildcard custom domains match exactly one subdomain level — flatten nested previews
scope: global
trigger: Designing preview URLs or multi-tenant hostname schemes on Vercel
enforcement: hard
public: true
version: 1
created: 2026-04-23
updated: 2026-04-23
source: session-learning
# applies_to: [vercel]
---

## Rule

Vercel wildcard custom domains (`*.example.com`) match EXACTLY ONE subdomain level. A host like `preview.{slug}.example.com` (two labels under `example.com`) does NOT match `*.example.com` — and Vercel does not support 2-level wildcards like `*.*.example.com` on custom domains.

When designing preview / tenant URL schemes, ALWAYS flatten to a single label:

| ❌ Does NOT work with `*.example.com` | ✅ DOES work with `*.example.com` |
|---|---|
| `preview.{slug}.example.com` | `preview-{slug}.example.com` |
| `staging.api.example.com` | `staging-api.example.com` |
| `{tenant}.admin.example.com` | `{tenant}-admin.example.com` or `admin-{tenant}.example.com` |

If a nested hierarchy is genuinely required (e.g. `api.{tenant}.example.com` for DNS clarity), you must attach each specific parent zone (e.g. `*.{tenant}.example.com`) as its own Vercel custom domain — one per tenant. This does not scale; flattening is almost always the right answer.

## Rationale

Vercel's custom-domain wildcard implementation mirrors DNS wildcard semantics (RFC 4592 §2.1.1): the wildcard label matches one and only one label. Requests for a 2-label subdomain fall through to a 404 / "no such deployment" page even though DNS resolves.

Captured 2026-04-23 during a preview-URL design discussion where `preview.{slug}.domain.com` was specified in a PRD and silently failed at attachment time because the matching wildcard only covered `*.domain.com`. Flattening to `preview-{slug}.domain.com` solved it with no infrastructure change.

## Related

- `.claude/policies/vercel-cross-team-domains.md` — team ownership edge case for wildcards
- `.claude/policies/hq-dns-wildcard-shadows-deleted-subdomain.md` — adjacent wildcard gotcha at the DNS layer
