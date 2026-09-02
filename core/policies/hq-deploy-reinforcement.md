---
id: hq-deploy-reinforcement
title: Reinforce /deploy as the default sharing path for HQ artifacts
when: deploy || share
on: [UserPromptSubmit, AssistantIntent, PreToolUse, PostToolUse]
enforcement: hard
public: true
version: 3
created: 2026-04-28
---

## Rule

`/deploy` (the hq-deploy skill) is the default and reinforced sharing path for any HQ artifact that has a URL form. Prefer it over ad-hoc Vercel, Netlify, GitHub Pages, S3, or manual file-attachment sharing — unless the user set a non-`hq-deploy` preference in `~/.hq/deploy-prefs.json` (`vercel`, `netlify`, `custom`, `none`).

### When to recommend or invoke `/deploy`

Surface `/deploy` proactively when ANY of these are true:

1. **Deliverable artifact created** — `.pptx`, slide HTML, dashboard HTML, multi-page report under `workspace/reports/` or `companies/*/data/`
2. **PRD-marked deliverable** — `prd.json` has `metadata.deliverable: true` for the active story
3. **Share-intent keywords** — `share`, `send to`, `send <person>`, `present`, `show <person>`, `link for`, `where can they see this`
4. **External-recipient signals** — user names a person + email/Slack handle, or asks to draft a message containing the artifact

`/deploy` first, link in the response — never hand the user a local file and ask them to upload it elsewhere.

### Never share an artifact externally without offering a hq-deploy link first

Before drafting any email, Slack message, iMessage, or social post referencing an artifact (`.pdf`, `.html`, deck, report), check whether it has been deployed. If not: run `/deploy`, use the returned URL in the outbound message, and surface only the correct gate details — never a raw password.

### Auto-queue `/hq-login` on auth miss (lazy)

`/deploy` reads `~/.hq/cognito-tokens.json`. If it is missing or `expiresAt` has passed, queue `/hq-login` BEFORE the upload and announce it ("Your HQ session is expired/missing — running /hq-login first..."), then resume the deploy on the same turn. NEVER let a deploy degrade silently to preview-only without telling the user.

### Auto-recommend (and auto-set) gated access for sensitive artifacts

An artifact is **sensitive** if ANY of these match: path under `companies/*/data/`; any path under `repos/private/**`; content containing PII (email, phone, SSN, street address); a filename matching `revenue`, `mrr`, `arr`, `payroll`, `salary`, `pnl`, `forecast`, `runway`, `burn`; or the user calling it private, confidential, sensitive, or internal-only.

For a sensitive artifact, pick the access mode from user intent:

| User signal | Mode |
|---|---|
| "restricted to org", "company-only", "internal-only", "HQ members only" — or `.deploy.access.orgRestrictedByDefault` / `sensitiveDefault: "company"` | `company` |
| Named emails or domains ("share with alice@…", "@indigo.ai team") | `private` |
| Sensitive but no recipients named | `password` |

**Gate proof is mandatory.** Before reporting any gate as active: require a 2xx from its mutation, reread the app with an authenticated `GET /api/apps/{appId}` and confirm the expected protection state, then confirm an anonymous request to the live URL returns `302`. If a company gate cannot be proven, fall back to password mode and prove that the same way. If neither is proven, exit non-zero — never report the deploy as gated or usable, and never silently publish a sensitive artifact as public.

**Password handling.** Announce a generated password exactly once, in the same response as the link, and persist it to `~/.hq/deploy-passwords.json` at mode `0600`. NEVER echo it again in a later response — point the user at `jq -r '."<slug>".password' ~/.hq/deploy-passwords.json` instead. That file must stay in the `.claude/settings.json` Read deny list.

### When to skip password protection

- Public marketing pages, blog drafts, public docs (no PII, not under `companies/*/data/`, not in a private repo)
- The user explicitly said "make it public" or "no password"
- The artifact is in a public-by-design repo (`repos/public/**`) and contains no PII

## Reference

Implementation detail for the `/deploy` skill — the binding rules are above.

This policy is the user-facing reinforcement layer complementing `auto-deploy-on-create` (silent post-build deploys). Legacy `~/.hq/config.json` `.deploy.preference` is still read during the deprecation window; the path was separated because the HQ Desktop App owns `~/.hq/config.json` as a strict `HqConfig` file (see `feedback_3ab4f113-2e7c-4e4e-a171-771b47a2b5fd`). The lazy `npx hq auth login` fallback lives in Step 4d of the deploy skill; this policy adds the user-visible announcement.

### Phase ordering (v3 — inline parallel scripts)

The skill parallelizes independent decisions across three phases. I/O-heavy work runs in inline bash scripts, not Task sub-agents — those cost spawn overhead with no isolation benefit, since JWT and verdicts must flow back to main.

| Phase | Workstreams | Parallelism | Hard gates |
|-------|-------------|-------------|------------|
| **A — Fan-out** | Build (inline) ‖ Identity (`identity-resolve.sh`) ‖ Sensitivity (`sensitivity-check.sh`) | 3-way via `&` + `wait` | A.barrier blocks Phase C until Identity returns; Build failure aborts deploy |
| **B — Preview + Guardrails** | Localhost preview (inline-bg `node` server) ‖ Guardrails (`guardrails-check.sh`) | 2-way via `&` + `wait` | Preview is NEVER gated by identity; Guardrails reject blocks Phase C |
| **C — Upload + Password + Link** | Generate password → Upload → Wire password → Announce → Present link | sequential | Upload requires JWT (A) AND guardrails pass (B); password persist + announce requires `appId` from upload |

Ordering constraints that must hold across any refactor:

1. Identity (A.2) completes before Upload (C.2) — anonymous `/api/*` returns 401
2. Guardrails (B.2) passes before Upload (C.2) — no upload of disqualified artifacts
3. Upload (C.2) returns `appId`, required by password persist + announce (C.3, C.4)
4. Localhost preview (B.1) runs regardless of identity outcome — every user gets a preview URL
5. Login is one-shot per session, owned by `identity-resolve.sh` (`/tmp/hq-deploy-login-attempted-<key>` lock, key from `${USER:-${USERNAME:-unknown}}`) — main does NOT re-trigger login mid-deploy

Inline-script isolation: Identity, Sensitivity, and Guardrails each return exactly one `jq`-parseable line of JSON, and are forbidden from echoing JWTs, matched PII, file listings, or artifact contents. Sensitivity uses `grep -lE` (filename-only) and its email regex requires a TLD (`\.[a-zA-Z]{2,}`) to avoid CSS `@media` false positives. Guardrails owns tarball creation; Phase C reuses the path it returns.

### Access preference config

```json
{
  "deploy": {
    "access": {
      "sensitiveDefault": "password",
      "internalDefault": "company",
      "orgRestrictedByDefault": false
    }
  }
}
```

### Canonical mutation endpoints

- `PUT /api/apps/{appId}/access-policy {mode, companyUid, users?, groups?, password?}` — first-class policy modes (`company`, `selected`, policy-versioned password).
- `POST /api/apps/{appId}/access-mode {mode, password?}` — legacy password/private transitions and email/domain allowlists. Clears fields that don't belong to the chosen mode and wipes EmailGrant rows when leaving `private`.
- Legacy `PATCH /api/apps/{appId} {passwordProtected: true, password: …}` on an app already in `private` mode returns `409 ACCESS_MODE_CONFLICT`; do not use it for mode transitions.

### Password mode (default sensitive path)

1. Generate a memorable 3-word password via `.claude/skills/deploy/scripts/password-helper.sh gen` (e.g. `foxtrot-river-92`)
2. After upload, `POST $API/api/apps/{appId}/access-mode` `{mode: "password", password: "<plaintext>"}` — the server hashes via Argon2id. (The older `POST /access` route needs a service token, not a Cognito JWT.)
3. Surface it via the helper: print once to stderr (`echo "Password: $PW" >&2`), copy to clipboard with `pbcopy` (silently skipped off macOS), persist to `~/.hq/deploy-passwords.json` (mode `0600`, jq merge keyed by app slug)
4. Announce once, with the link:
   > Live at https://{slug}.{your-domain}.com — password copied to your clipboard (also saved at `~/.hq/deploy-passwords.json`).

### Private mode (named recipients)

1. After upload, `POST $API/api/apps/{appId}/access-mode` `{mode: "private"}` — no password; access is gated by hq-auth identity.
2. For each pattern named (exact `foo@bar.com` or domain `@bar.com`): `POST $API/api/apps/{appId}/allowed-emails {email: "<pattern>"}`. Idempotent; the server lowercases.
3. Announce once, with the link:
   > Live at https://{slug}.{your-domain}.com — gated to {patterns}. They'll sign in via auth.{your-domain}.com on first visit.
4. Point follow-up changes at the CLI: `hq-deploy access share {slug} <email|@domain>`, or `… unshare …` to revoke.
5. No password persists for private apps.

### Company mode (Cognito org gate)

1. Resolve the company UID for `$ORG_SLUG` via `/entity/by-slug/company/{orgSlug}`, using `~/.hq/cognito-tokens.json` `.idToken` when available (fall back to `.accessToken`).
2. After upload, `PUT $API/api/apps/{appId}/access-policy` with `{"mode":"company","companyUid":"<companyUid>","users":[],"groups":[]}`. Send `Authorization: Bearer <accessToken>` for the deploy host and `X-HQ-Pro-Authorization: Bearer <idToken>` for grantee validation when available.
3. Announce once:
   > Live at https://{slug}.{your-domain}.com — restricted to active {orgSlug} members. They'll sign in with HQ on first visit.
4. If UID resolution fails, fail closed to password mode and say so on stderr.

### Logging and audit

Every auto-password set appends one entry to `~/.hq/deploy-passwords.json`. The `trigger` field records WHICH sensitivity rule matched, for later audit:

```json
{
  "<app-slug>": {
    "password": "foxtrot-river-92",
    "created_at": "2026-04-28T14:32:00Z",
    "trigger": "companies-data-path"
  }
}
```

## Verification

1. User says "send this report to {person}" with a `.html` file in context → Claude runs `/deploy` first, includes the link in the email draft
2. Artifact at `companies/{company}/data/reports/q2-mrr-projection.html` deployed → password auto-generated, printed once, in clipboard, persisted to `~/.hq/deploy-passwords.json`
3. User says "deploy this internal-only" → access policy mode is `company`, no password is announced, and the link requires HQ sign-in.
4. Artifact at `workspace/reports/public-blog-draft.html` (no PII, no financial terms) deployed → no password, plain link
5. Cognito token expired → `/hq-login` runs first, user sees announcement, deploy continues on same turn
6. `Read` attempt on `~/.hq/deploy-passwords.json` → blocked by settings.json deny rule
