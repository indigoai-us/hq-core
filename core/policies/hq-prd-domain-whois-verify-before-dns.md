---
id: hq-prd-domain-whois-verify-before-dns
title: WHOIS-verify every domain referenced in a PRD before committing DNS / Vercel decisions
scope: global
trigger: About to configure DNS, Vercel custom domains, or email routing based on a domain declared in a PRD
enforcement: soft
public: true
version: 1
created: 2026-04-23
updated: 2026-04-23
source: session-learning
---

## Rule

NEVER assume a domain referenced in a PRD is registered or owned by the caller — WHOIS-check every domain before committing ANY of:

- DNS record creation / deletion
- Vercel custom-domain attachment
- Route53 hosted zone setup
- Email routing (MX / SPF / DKIM)
- Certificate requests

Pre-flight check (add one line per domain listed in the PRD):

```bash
for d in example.com otherdomain.com; do
  echo "=== $d ==="
  whois "$d" | grep -iE '^(Domain Name:|Registrar:|Registry Expiry Date:|Name Server:|No match|NOT FOUND)' | head -20
done
```

Interpret the result:

| Signal | Action |
|--------|--------|
| `No match for` / `NOT FOUND` / `Domain not found` | Domain is UNREGISTERED — pause the PRD and confirm with the user before registering anything. The PRD may be aspirational or based on a typo |
| `Registrar: <their-registrar>` + `Registry Expiry Date:` in the future + ns matches owner's registrar | OK to proceed |
| Registered, but ns / registrar differs from what the PRD expected | Pause — the domain may be owned by someone else or parked |
| Expiry date within 30 days | Flag to user before investing in DNS work |

## Rationale

Observed during a multi-PRD session where an aspirational domain appeared in three places (PRD body, README, DNS plan) and the orchestrator proceeded to design a DNS + Vercel topology around it. The domain had never been registered. A single WHOIS earlier would have caught it and avoided sunk cost on DNS wiring that could not be satisfied.

PRDs are drafted from ideas, not ownership manifests — the authoring step has no hook that validates domain registration. The execution step must.

This rule composes with:

- `core/policies/hq-pre-deploy-domain-check.md` — deploy-registry lookup for owned projects (assumes ownership is established)
- `core/policies/hq-cmd-run-project-preflight-pause-stale-state.md` — generic preflight pause

## Related

- `core/policies/hq-pre-deploy-domain-check.md`
- `core/policies/hq-cmd-run-project-preflight-pause-stale-state.md`
