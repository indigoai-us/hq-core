---
name: new-hire
description: Onboard a human teammate end-to-end — invite, role, groups, secrets, file access, onboarding packet, and acceptance follow-through. Use when someone new joins a company or an existing teammate needs their access brought up to their role.
allowed-tools: Bash, Read, Write, AskUserQuestion
---

# /new-hire — Onboard a Human Teammate

One flow from "we hired someone" to "they have everything their role needs and
know where to start." The failure mode this skill kills: a new teammate gets an
invite email and nothing else — no groups, no secrets, no map of the company —
and spends their first week asking for access one credential at a time.

**Usage:**
```
/new-hire                          # interview from scratch
/new-hire {email}                  # onboard a specific person
/new-hire {email} {company}        # skip company resolution
```

For **fleet agents** (identities like `agt-…@agents.{your-domain}.ai`), use
`/new-agent` instead — agents need runtime bootstrap and probe verification
that humans don't.

## Process

### 1. Resolve person + company

- Check current state: `hq members list --company {co}`. If the person already
  has an active membership → **top-up mode**: diff their access against the
  role's needs and grant only gaps (role changes go through `hq groups` /
  membership updates, not a re-invite).
- Company must be in `companies/manifest.yaml` and cloud-backed (`cloud_uid`
  present). Not cloud-backed → route to `/designate-team` first.

### 2. Interview — define the role before the grants

Batched (one AskUserQuestion call, skip anything already known):

1. **Who**: name + email (work email they'll authenticate with).
2. **Role**: `admin` or `member` in the vault, and their functional role
   (engineering, finance, ops, design, GTM…) — the function drives the access
   bundle.
3. **Access bundle**: which repos, secrets, knowledge areas, and tools does the
   function need on day one? Prefer naming an existing teammate to mirror
   ("same access as X") — then read X's grants as the template.
4. **Intro context**: who do they report to, which Slack channels matter, any
   first-week priorities for the onboarding packet.

### 3. Derive the access bundle

Build the manifest before granting. For each item, prefer what exists in the
vault (`hq secrets list --company {co}`) over minting new credentials.

- **Least privilege**: `--permission read` unless their function writes
  (e.g. an engineer deploying needs write on deploy keys; a finance analyst
  reading Stripe does not).
- **Groups first**: if the company uses `hq groups`, add the person to the
  right group and let group ACLs carry the standing access — per-person shares
  are for exceptions, not the baseline.
- **Payment/production keys**: verify scope before sharing (a Stripe key's
  prefix — `rk_` restricted vs `sk_` full — can be checked without exposure via
  `hq secrets exec --company {co} --only KEY -- sh -c 'printf %s "$KEY" | cut -c1-3'`).
  Flag full-scope keys to the owner before including them in an onboarding
  bundle.
- Anything the role needs that HQ can't grant (GitHub org seat, SaaS seats,
  payroll) goes in the report as an action item with an owner — not silently
  dropped.

### 4. Invite + grants

**Invite** (skip in top-up mode):
```bash
hq invite {email} --company {slug} --role {admin|member} --inviter "{Owner Name}"
```
- Default path emails the claim link via Resend. With `--no-email`, the CLI
  prints the claim link — surface it ONLY as a Markdown inline link per
  `core/policies/hq-secure-link-render-as-markdown.md`; it is a single-use
  capability.

**Groups**:
```bash
hq groups add {group} --member {email} --company {slug}   # or equivalent
```

**Secrets** — per manifest key:
```bash
hq secrets share KEY --company {slug} --with {email} --permission read
```
(`--permission` is required; full key path, e.g. `SHOPIFY/CLIENT_ID`, not a
prefix.)

**File ACLs** — knowledge areas, playbooks, dashboards via `/hq-files`
grants or `/hq-share` for one-off packets.

### 5. Write the onboarding packet

Create `companies/{co}/people/{name-slug}/onboarding.md` in the team vault:

- **Start here**: what the company does, who's who (reporting line, key
  contacts), which Slack channels to join.
- **Your access**: the granted bundle in plain language — what each credential
  or path is for, and the house rules that govern it (link the company's hard
  policies rather than restating them).
- **Setup checklist**: `hq login` → `/accept` (if link not yet claimed) →
  `hq team-sync` → `hq secrets list --company {co}` shows their keys.
- **First week**: the priorities from Step 2.4.

The packet syncs to them on `hq team-sync` — it outlives the welcome message
and is the single place to update as their access evolves.

### 6. Welcome + follow-through

- Draft the welcome (Slack or `hq dm`): outcome-first, plain language, links to
  the packet. **Show outbound drafts to the user for approval before sending**
  — external-facing messages are never fire-and-forget.
- Track acceptance: invite stays `pending` until they claim it. Check
  `hq members list --company {co}`; if still pending after a day, resurface to
  the owner rather than assuming onboarding finished.
- After acceptance, confirm the setup checklist completed (ask them, or check
  the signals their function produces — first commit, first report, first
  message in the team channel).

### 7. Report

```
Hire: {name} <{email}> — {role} @ {co}

Invite:    {sent|pending|already active}
Groups:    {list}
Granted:   {n} secrets (read/write split), {m} file paths
Packet:    companies/{co}/people/{name-slug}/onboarding.md
Welcome:   {drafted → approved → sent | awaiting approval}
Outside HQ: {SaaS seats / org invites needing a human, each with an owner}

Done when: membership active + they confirm the setup checklist.
```

## Rules

- Least privilege, groups before per-person shares, read before write.
- Never paste secret values anywhere; grants and `hq secrets exec` only.
- Claim links are single-use capabilities — markdown inline link render only,
  never bare tokens.
- Outbound welcome messages require user approval before sending.
- Top-up mode (existing member) must diff current access first — never blind
  re-grant, never re-invite an active member.
- Tenant isolation: one company per invocation; cross-company access goes
  through `hq group-grants` with explicit sign-off.
- Onboarding is not done at invite-send. It is done at membership-active +
  confirmed setup checklist.

## See also

- `/new-agent` — fleet-agent equivalent (adds runtime bootstrap + probe gate)
- `hq invite` — the bare invite primitive this skill wraps
- `/designate-team` — make a company cloud-backed first
- `/hq-secrets`, `/hq-files`, `/hq-share` — grant primitives
