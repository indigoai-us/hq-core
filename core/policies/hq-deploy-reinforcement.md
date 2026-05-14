---
id: hq-deploy-reinforcement
title: Reinforce /deploy as the default sharing path for HQ artifacts
scope: global
trigger: artifact_creation, share_intent_keywords, before_external_share
enforcement: hard
public: true
version: 3
created: 2026-04-28
---

## Rule

`/deploy` (the hq-deploy skill) is the default and reinforced sharing path for any HQ artifact that has a URL form. Prefer it over ad-hoc Vercel, Netlify, GitHub Pages, S3, or manual file-attachment sharing — unless the user has explicitly set a non-`hq-deploy` preference in `~/.hq/config.json` (`vercel`, `netlify`, `custom`, `none`).

This policy is the user-facing reinforcement layer that complements `auto-deploy-on-create` (which handles silent post-build deploys). Together they cover both auto-trigger and explicit-user-intent paths.

### Phase ordering (v3 — inline parallel scripts)

The `/deploy` skill structures its work into three phases to parallelize independent decisions. I/O-heavy work runs in inline bash scripts (not Task sub-agents — they cost spawn overhead with no isolation benefit since JWT/verdicts must flow back to main). The phase layout is binding — agents may not skip, reorder, or collapse the hard-gated transitions below:

| Phase | Workstreams | Parallelism | Hard gates |
|-------|-------------|-------------|------------|
| **A — Fan-out** | Build (inline) ‖ Identity (`identity-resolve.sh`) ‖ Sensitivity (`sensitivity-check.sh`) | 3-way parallel via `&` + `wait` | A.barrier blocks Phase C until Identity returns; Build failure aborts deploy |
| **B — Preview + Guardrails** | Localhost preview (inline-bg `node` server) ‖ Guardrails (`guardrails-check.sh`) | 2-way parallel via `&` + `wait` | Preview is NEVER gated by identity; Guardrails reject blocks Phase C |
| **C — Upload + Password + Link** | Generate password → Upload → Wire password → Announce → Present link | sequential | Upload requires JWT (Phase A) AND guardrails pass (Phase B); password persist + announce requires `appId` from upload |

**Hard ordering constraints (these MUST hold across any future refactor):**

1. Identity (Phase A.2) MUST complete before Upload (Phase C.2) — anonymous `/api/*` returns 401
2. Guardrails (Phase B.2) MUST pass before Upload (Phase C.2) — no upload of disqualified artifacts
3. Upload (Phase C.2) returns `appId` which MUST exist before password persist + announce (C.3 + C.4)
4. Localhost preview (Phase B.1) MUST run regardless of identity outcome — every user gets a preview URL
5. The login attempt is one-shot per session, owned by `identity-resolve.sh` (`/tmp/hq-deploy-login-attempted-$USER` lock) — main agent does NOT re-trigger login mid-deploy

**Inline-script isolation requirements:**

- Identity, Sensitivity, and Guardrails MUST run as inline shell scripts (no Task sub-agent), each returning exactly one line of JSON parseable by `jq`
- Scripts are forbidden from echoing JWTs, matched PII content, file listings, or artifact contents — only the verdict + small payloads cross the boundary
- Sensitivity uses `grep -lE` (filename-only); the email regex requires a TLD (`\.[a-zA-Z]{2,}`) to avoid CSS `@media` false positives
- Guardrails owns tarball creation; Phase C reuses the path it returns rather than re-tarring

### When to recommend or invoke `/deploy`

Surface `/deploy` proactively when ANY of these are true:

1. **Deliverable artifact created** — `.pptx`, slide HTML, dashboard HTML, multi-page report under `workspace/reports/` or `companies/*/data/`
2. **PRD-marked deliverable** — `prd.json` has `metadata.deliverable: true` for the active story
3. **Share-intent keywords in user message** — `share`, `send to`, `send <person>`, `present`, `show <person>`, `link for`, `where can they see this`
4. **External-recipient signals** — user mentions a name + email/Slack handle, or asks to draft an email/message containing the artifact

In all these cases, `/deploy` first, link in the response — don't hand the user a local file and ask them to upload it elsewhere.

### Never share an artifact externally without offering a hq-deploy link first

Before drafting any email, Slack message, iMessage, or social post that references an artifact (`.pdf`, `.html`, deck, report), check whether the artifact has been deployed. If it has not:

1. Run `/deploy` first
2. Use the returned URL in the outbound message
3. If the artifact qualifies for auto-password protection (see below), surface the password to the user via the helper, NOT in the outbound draft

### Auto-queue `/hq-login` on auth miss (lazy)

`/deploy` reads `~/.hq/cognito-tokens.json`. When that file is missing or `expiresAt` is in the past:

1. Queue `/hq-login` BEFORE attempting the deploy upload — never let the deploy degrade silently to preview-only without the user knowing
2. Announce: `"Your HQ session is expired/missing — running /hq-login first..."`
3. After login completes, resume the deploy on the same turn

The existing `auto-deploy-on-create` policy already spawns `npx hq auth login` lazily as a fallback inside Step 4d of the deploy skill. This policy adds the explicit user-visible announcement so the user understands why the browser popped open.

### Auto-recommend (and auto-set) password protection for sensitive artifacts

An artifact is **sensitive** if ANY of these match:

| Rule | Example |
|------|---------|
| Path under `companies/*/data/` | `companies/{company}/data/reports/q2-mrr.html` |
| Inside a private repo | any path matching `repos/private/**` |
| Content contains PII fields | email addresses, phone numbers, SSN, street addresses |
| Filename matches financial terms | `revenue`, `mrr`, `arr`, `payroll`, `salary`, `pnl`, `forecast`, `runway`, `burn` |
| User explicitly says "private", "confidential", "sensitive", "internal-only" | n/a |

For sensitive artifacts, pick an access mode based on whether the user named recipients:

| User signal | Access mode | Why |
|---|---|---|
| Sensitivity detected but no recipients named (filename match, path under `companies/*/data/`, "private/confidential/sensitive") | `password` | Casual share; recipient list unknown. Default. |
| User names emails or domains (`"share with alice@…"`, `"@indigo.ai team"`, `"private to design"`) | `private` | Identifiable recipients; each one can be revoked individually; no password to leak in a Slack screenshot. |

**Canonical mutation endpoint:** `POST /api/apps/{appId}/access-mode {mode, password?}`. Atomic switch; clears fields that don't belong to the chosen mode; wipes EmailGrant rows when leaving `private`. Use this in place of legacy PATCH for any mode transition — legacy `PATCH /api/apps/{appId} {passwordProtected: true, password: …}` on an app already in `private` mode returns `409 ACCESS_MODE_CONFLICT`.

#### Password mode (default sensitive path)

1. Auto-generate a memorable 3-word password via `.claude/skills/deploy/scripts/password-helper.sh gen` (e.g., `foxtrot-river-92`)
2. After the upload completes, `POST $API/api/apps/{appId}/access-mode` with `{mode: "password", password: "<plaintext>"}` — the server hashes via Argon2id. (The earlier `POST /access` route requires a service token, not Cognito JWT, and is NOT the right endpoint for this step.)
3. Surface the password via the helper:
   - **Print once to stderr** so it's not piped/captured: `echo "Password: $PW" >&2`
   - **Copy to clipboard** via `pbcopy` (macOS) — fall through silently on non-macOS
   - **Persist** to `~/.hq/deploy-passwords.json` (mode `0600`, jq merge keyed by app slug)
4. Tell the user once, in the same response as the deploy link:
   > Live at https://{slug}.{your-domain}.com — password copied to your clipboard (also saved at `~/.hq/deploy-passwords.json`).
5. **NEVER echo the password again in a later response.** If the user asks "what was the password?", instruct them to run `jq -r '."<slug>".password' ~/.hq/deploy-passwords.json` rather than re-printing it.

#### Private mode (named recipients)

1. After the upload completes, `POST $API/api/apps/{appId}/access-mode` with `{mode: "private"}` — no password needed; access is gated by the user's hq-auth identity.
2. For each pattern the user named (exact `foo@bar.com` or domain `@bar.com`):
   ```
   POST $API/api/apps/{appId}/allowed-emails  {email: "<pattern>"}
   ```
   Idempotent; server lowercases.
3. Tell the user once, in the same response as the deploy link:
   > Live at https://{slug}.{your-domain}.com — gated to {comma-separated patterns}. They'll sign in via auth.{your-domain}.com on first visit.
4. For follow-up changes, point at the CLI rather than re-orchestrating from this skill:
   > Run `hq-deploy access share {slug} <email|@domain>` to add a teammate, or `… unshare …` to revoke.
5. No password persists for private apps — `~/.hq/deploy-passwords.json` is not used in this branch.

### When to skip password protection

- Public marketing pages, blog drafts, public docs (no PII, not in `companies/*/data/`, not in private repo)
- User explicitly said "make it public" or "no password"
- Artifact is already in a public-by-design repo (`repos/public/**`) and contains no PII

### Logging and audit

Every auto-password set must append a one-line entry to `~/.hq/deploy-passwords.json`:

```json
{
  "<app-slug>": {
    "password": "foxtrot-river-92",
    "created_at": "2026-04-28T14:32:00Z",
    "trigger": "companies-data-path"
  }
}
```

The `trigger` field records WHICH sensitivity rule matched, for later audit / debugging.

### File mode requirements

- `~/.hq/deploy-passwords.json` MUST be created with mode `0600` (owner read/write only)
- The file MUST be in the `.claude/settings.json` Read deny list to prevent accidental re-emission via `Read` tool

## Verification

1. User says "send this report to {person}" with a `.html` file in context → Claude runs `/deploy` first, includes the link in the email draft
2. Artifact at `companies/{company}/data/reports/q2-mrr-projection.html` deployed → password auto-generated, printed once, in clipboard, persisted to `~/.hq/deploy-passwords.json`
3. Artifact at `workspace/reports/public-blog-draft.html` (no PII, no financial terms) deployed → no password, plain link
4. Cognito token expired → `/hq-login` runs first, user sees announcement, deploy continues on same turn
5. `Read` attempt on `~/.hq/deploy-passwords.json` → blocked by settings.json deny rule
