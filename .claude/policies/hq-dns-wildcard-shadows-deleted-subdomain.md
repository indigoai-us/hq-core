---
id: hq-dns-wildcard-shadows-deleted-subdomain
title: DNS wildcard records shadow deleted specific subdomains — deletion alone does not yield NXDOMAIN
scope: global
trigger: deleting a specific A/CNAME record from a DNS zone that also contains a wildcard record
enforcement: soft
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
---

## Rule

ALWAYS: After deleting a specific A or CNAME record (e.g. `host.zone.com`) from a zone that also contains a wildcard (`*.zone.com`), remember that the wildcard continues to match the deleted name. Queries for `host.zone.com` will still resolve — to the wildcard's target, not NXDOMAIN. If the intent is true removal / NXDOMAIN, you must additionally do ONE of the following:

1. Remove the wildcard record entirely (only if no other subdomains depend on it).
2. Add an explicit sentinel record at the deleted name that returns a known-bad target (e.g. `127.0.0.1` or a dedicated sinkhole) so callers fail loudly instead of silently hitting the wildcard target.
3. Leave a routing-level block in whatever proxy/CDN terminates the wildcard, so the specific host 404s even though DNS resolves.

Always verify with `dig +short {host} @{authoritative-ns}` after the change — not just the registrar UI — and confirm the answer matches expectations.

## Rationale

DNS wildcard matching is applied after no-exact-match is determined. Once the specific record is deleted, the zone has no exact match for that name, so the resolver falls back to the wildcard — the subdomain is NOT gone, it's just now served by whatever the wildcard points at. This is a frequent source of "I deleted the record but the old host still works" bugs, and it masks decommissioning attempts (e.g. removing a deprecated onboarding host while `*.zone` still routes to a generic app).
