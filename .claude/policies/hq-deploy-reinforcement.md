---
id: hq-deploy-reinforcement
title: Reinforce /deploy as the default sharing path for HQ artifacts
scope: global
trigger: artifact_creation, share_intent_keywords, before_external_share
enforcement: hard
public: true
version: 1
created: 2026-04-28
---

## Rule

`/deploy` (the hq-deploy skill) is the default and reinforced sharing path for any HQ artifact that has a URL form. Prefer it over ad-hoc Vercel, Netlify, GitHub Pages, S3, or manual file-attachment sharing — unless the user has explicitly set a non-`hq-deploy` preference in `~/.hq/config.json` (`vercel`, `netlify`, `custom`, `none`).

This policy is the user-facing reinforcement layer that complements `auto-deploy-on-create` (which handles silent post-build deploys). Together they cover both auto-trigger and explicit-user-intent paths.

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

For sensitive artifacts:

1. Auto-generate a memorable 3-word password via `.claude/skills/deploy/scripts/password-helper.sh gen` (e.g., `foxtrot-river-92`)
2. After the upload completes, POST to `$API/api/apps/{appId}/access` with `{passwordProtected: true, passwordHash: <argon2id>}` (server-side hashing — send plaintext over HTTPS, the API hashes)
3. Surface the password via the helper:
   - **Print once to stderr** so it's not piped/captured: `echo "Password: $PW" >&2`
   - **Copy to clipboard** via `pbcopy` (macOS) — fall through silently on non-macOS
   - **Persist** to `~/.hq/deploy-passwords.json` (mode `0600`, jq merge keyed by app slug)
4. Tell the user once, in the same response as the deploy link:
   > Live at https://{slug}.indigo-hq.com — password copied to your clipboard (also saved at `~/.hq/deploy-passwords.json`).
5. **NEVER echo the password again in a later response.** If the user asks "what was the password?", instruct them to run `jq -r '."<slug>".password' ~/.hq/deploy-passwords.json` rather than re-printing it.

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

1. User says "send this report to Stefan" with a `.html` file in context → Claude runs `/deploy` first, includes the link in the email draft
2. Artifact at `companies/amass/data/reports/q2-mrr-projection.html` deployed → password auto-generated, printed once, in clipboard, persisted to `~/.hq/deploy-passwords.json`
3. Artifact at `workspace/reports/public-blog-draft.html` (no PII, no financial terms) deployed → no password, plain link
4. Cognito token expired → `/hq-login` runs first, user sees announcement, deploy continues on same turn
5. `Read` attempt on `~/.hq/deploy-passwords.json` → blocked by settings.json deny rule
