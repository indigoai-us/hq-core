---
id: hq-nextjs-host-redirect-requires-domain-attachment
title: Next.js host-scoped redirects require Vercel domain attachment, not just DNS
scope: global
trigger: configuring a host-matched redirect (`has: [{type: host, value: ...}]`) in next.config.*
enforcement: soft
public: true
version: 1
created: 2026-04-20
updated: 2026-04-20
source: session-learning
applies_to: [vercel]
---

## Rule

ALWAYS: For a Next.js `has: [{type: host, value: "sub.example.com"}]` redirect to fire, the host MUST be attached as a domain to the same Vercel project that serves the Next app. DNS CNAME to `cname.vercel-dns.com` alone is **not** sufficient.

Without attachment, Vercel's edge returns `DEPLOYMENT_NOT_FOUND` before the request ever reaches the Next.js runtime — the redirect rule in `next.config.mjs` is never evaluated.

Correct setup for a redirect-only shim `old.example.com → new.example.com`:
1. DNS: CNAME `old.example.com → cname.vercel-dns.com` (Route53 or equivalent)
2. Vercel: attach `old.example.com` as a domain on the destination project (`POST /v10/projects/{id}/domains`) + complete TXT verification
3. Next config: `redirects()` entry with `has: [{type: "host", value: "old.example.com"}]` + `destination: "https://new.example.com/:path*"` + `permanent: true`
4. Deploy destination project — only now does the 308 fire

## Rationale

A subdomain had DNS pointing at `cname.vercel-dns.com` and a `next.config.mjs` host-matched redirect in what was believed to be the serving project — but every request returned `DEPLOYMENT_NOT_FOUND`. Vercel's edge routing layer resolves incoming hosts against the team's attached-domains table *before* dispatching to any project's runtime; unknown hosts never reach Next.js. Once the domain was formally attached to the destination project, the redirect fired immediately.

Mental model: Vercel domain attachment is request-admission. Next.js redirects are request-shaping. You cannot shape what was never admitted.

