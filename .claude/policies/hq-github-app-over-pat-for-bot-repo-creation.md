---
id: hq-github-app-over-pat-for-bot-repo-creation
title: Prefer a scoped GitHub App over a fine-grained PAT for bot repo-creation scopes
scope: global
trigger: Setting up bot credentials that need to create repositories, manage org-level resources, or act on behalf of an automation
enforcement: soft
public: true
version: 1
created: 2026-04-23
updated: 2026-04-23
source: session-learning
---

## Rule

ALWAYS prefer a scoped **GitHub App** (installed on a single organization) over a **fine-grained PAT** when a bot or automation needs repo-creation scope, org-admin permissions, or any scope that would be catastrophic if leaked.

Why the App wins:

| Property | GitHub App installation token | Fine-grained PAT |
|---|---|---|
| Lifetime | ~1 hour (auto-rotated by the App) | Up to 1 year (user sets it) |
| Scope | One org + one installation | Every org + every scope on the PAT, until revoked |
| Rotation | Automatic per request | Manual / calendar-driven |
| Leak blast radius | Bounded to installed org + install permissions | Every resource the PAT can reach |
| Revocation UX | Uninstall App from org (single click) | Requires the user to find + delete the PAT |
| Audit trail | App-specific audit events per action | Attributed to the owning user |

Use a fine-grained PAT only when:

1. You genuinely cannot run a GitHub App (e.g. no server to host the App's private key + JWT minting).
2. The PAT has a single, narrow scope that couldn't be harmful (e.g. read-only `metadata`).
3. You've set a PAT expiry ≤ 30 days and scheduled rotation.

NEVER use a classic PAT for bot automation if a fine-grained PAT or App can do the job.

## Implementation sketch (GitHub App)

```
1. Create GitHub App in org settings → generate private key (.pem)
2. Install App into target org, pin to a specific repo list or "All repositories"
3. Bot code: sign a short-lived JWT with the App's private key →
   POST /app/installations/{installation_id}/access_tokens
   → receive ~1h installation token → use for API calls
4. Store the private key in Secrets Manager / 1Password; NEVER check it in
```

## Rationale

Captured 2026-04-23 while designing a repo-creation bot. The initial impulse was to issue a fine-grained PAT with `contents: write + administration: write` scoped to the org. That PAT would have lived up to a year on the server and, if exfiltrated, would have granted the attacker the ability to create and archive every repo in the org until the PAT was rotated.

A GitHub App scoped to the same org, with identical permissions, ships ~1-hour installation tokens minted on demand. A leaked token is expired within the hour; a leaked App private key can be rotated via App settings without re-auth'ing any caller.

The operational cost of the App is one-time (generate key, install); the security improvement is permanent.

## Related

- `.claude/policies/hq-never-echo-tokens-stdout.md` — secrets hygiene
- `companies/*/policies/*credential-access*` — per-company credential storage
