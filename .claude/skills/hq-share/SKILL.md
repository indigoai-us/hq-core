---
name: hq-share
description: Share HQ vault paths through single-use links or direct ACL grants.
allowed-tools: Bash(hq:*), Bash(test:*), Bash(jq:*)
---

# HQ Share — Share vault paths (link or direct grant)

Share one or more HQ vault prefixes in either of two modes — the skill picks
the right one (Step 2.5) using the same decision table that lives in
[`hq-files`](../hq-files/SKILL.md) → "Choosing between direct grant and the
browser flow":

- **Share-session link (browser flow)** — when no recipient is named, or there
  are multiple recipients/paths, or you want to see who already has access. The
  CLI mints an encrypted single-use token, opens the share-session page in your
  default browser, and lets the issuer pick recipients (members, groups, "Share
  with All") with per-recipient read/write, then submits every grant in one
  round-trip. This is the default and the historical behavior.
- **Direct ACL grant** — when a single known principal (a real email, a
  `grp_<id>`, or `@all`) needs durable access. The skill writes the grant
  itself with `hq files share <prefix> --with <principal> --permission <level>`,
  then verifies it landed. No browser, no link.

Both modes call the same underlying `hq files share` command — the presence of
`--with` (or a clearly-named single recipient) is what selects the direct-grant
path. For revoking grants or inspecting an ACL, use
[`hq-files`](../hq-files/SKILL.md) — that skill remains the full ACL manager.

## Usage

```
/hq-share <path>... [--with <principal>] [--permission read|write] [--company <slug>] [--no-open] [--no-draft]
```

Examples:

```
# Share-session link (browser flow) — no recipient named
/hq-share reports/q3/
/hq-share reports/q3/ docs/handbook/ --company {company}
/hq-share announcements/ --no-open               # print URL, headless contexts
/hq-share reports/q3/ --no-draft                 # skip the LLM-drafted note step

# Direct ACL grant — a single principal named with --with
/hq-share reports/q3/ --with [EMAIL] --permission read
/hq-share invoices/ --with grp_finance --permission read --company {company}
/hq-share announcements/ --with @all --permission read   # company-wide
```

`--with <principal>` selects the **direct-grant** path. `<principal>` must be a
real email, a group id (`grp_<id>`), or the literal `@all` — never a shorthand
name or placeholder (policy `hq-files-share-with-requires-real-principal`).
`--with` requires `--permission`; if omitted, the skill defaults to `read` and
says so — it never silently grants `write`.

`--no-draft` skips the Step 3.5 "draft the note" pre-fill — useful when
the sender wants to type their own context from scratch without an
agent-generated starting point. Sender always gets the textarea in the
browser regardless.

## Process

### 1. Probe auth

```bash
test -f ~/.hq/cognito-tokens.json
```

If absent, stop and report `Not signed in. Run /hq-login first.`

### 2. Parse arguments

Split `$ARGUMENTS` into:

- one or more `<path>` positionals (required; trailing slash → folder prefix
  per [`hq-files`](../hq-files/SKILL.md) "Prefix Conventions"). Never prepend
  `companies/<slug>/` — prefixes are bucket-relative (policy
  `hq-files-share-prefix-company-relative`).
- optional flags: `--with <principal>`, `--permission <read|write>`,
  `--company <slug>`, `--no-open`, `--no-draft`

If no positionals are supplied, print the usage block above and stop.

When `--with` is present, validate `<principal>` is a real email, `grp_<id>`,
or `@all` (policy `hq-files-share-with-requires-real-principal`). If the user
named a recipient only by first name or a placeholder you cannot resolve to a
real email, ask once for the address — do not guess, and do not fall through to
a grant on a made-up principal. If `--with` is present but `--permission` is
not, default to `read` and state that explicitly in your confirmation.

### 2.5. Choose the mode

Pick the path using the same decision table as
[`hq-files`](../hq-files/SKILL.md) → "Choosing between direct grant and the
browser flow":

| Situation | Mode |
|-----------|------|
| `--with <principal>` is set, **or** the user named a single known recipient ("share X with alice@…") | **Direct grant** (Step 4b) |
| No recipient named, OR 2+ recipients, OR 2+ paths, OR the user wants to see who already has access | **Share-session link** (Steps 3.5–4) |
| Scripted / headless (`--no-open`) with a single known recipient | **Direct grant** (Step 4b) |
| Granting to the entire company | **Direct grant** with `--with @all --permission read`, or the browser flow's "Share with All" toggle |

If a single request mixes both intents (e.g. 2+ paths *and* `--with`), the
`hq files share` CLI applies the one `--with` grant to every listed prefix —
fine for a deliberate batch grant; if that's not what the user meant, fall back
to the browser flow.

### 3. Confirm scope before sharing

Echo back to the user the resolved paths and the company (from `--company`
or the active company in `~/.hq/config.json`). For a **direct grant**, also
echo the principal and the permission level. Granting on the wrong company
uid is hard to clean up — pause for approval if anything looks off, then
proceed. **`write` is a privilege escalation** in either mode: confirm with
the user before submitting any `write` grant (Rule #4).

### 3.5. Draft the note (sender-side LLM pre-fill)

**Share-session mode only.** A direct grant (Step 4b) has no note or
notification surface — skip this entire step when the mode is direct grant and
go straight to Step 4b.

The share-session form has an optional **Note** textarea — the recipient
sees the note as the body of their macOS notification ("their note: …")
and again at the top of the ShareDetail window. Empty note → recipient
notification falls back to a comma-joined list of basenames, which is
much less useful.

When the local paths are readable (skill is running in the user's session,
not headless), draft a short note BEFORE minting so the user just reviews
and approves rather than typing from scratch.

**Inventory step (cheap):**

- For each `<path>` positional:
  - Folder (trailing slash) → `ls` the top level + recurse one level (cap
    ~30 entries total); collect basenames + a brief sense of contents
    (presence of `README.md`, `package.json`, `prd.json`, leading docs).
  - File → just the basename and (if small text) a 1-line skim.
- Skip binaries / files > 100 KB / known noise (`node_modules/`, `.git/`,
  build output). Read text files only when their basename suggests
  context (`README.md`, `prd.json`, top-level `.md` in folder).

**Draft step (≤2 sentences, factual):**

- Lead with what + why ("Sharing the Q3 retro notes for your review
  before the all-hands.").
- Name 1–2 specific things if obvious from the inventory ("Brief +
  three open-question docs.").
- Do NOT invent context not present in the files / recent conversation.
- Cap ~280 chars — the recipient sees it as a notification body which
  truncates at ~100 chars, and the textarea soft-warns above 1800.

**Confirm step (one structured question, single picker):**

Show the user the draft note and offer:

- **Use this draft (Recommended)** — proceed with the note as written.
- **Edit before sending** — print the draft so the user can quote/edit
  in chat; their reply becomes the note.
- **Skip — no note** — proceed without pre-fill.

If the user types their own note inline ("note: …"), treat that as the
chosen text without re-asking.

**Skip the whole step when:**

- `--no-open` is set (headless / scripted — the URL goes to a side
  channel, the human writes the note in the browser).
- The path is not locally readable (vault-only prefix the user is sharing
  without a local mirror).
- The user explicitly passed `--no-draft` (flag added below).
- The user has set `personal/agents-profile.md` to opt out of LLM-drafted
  notes (free-form heuristic — if uncertain, ask once and remember the
  answer for the session).

The drafted text rides on the URL as `?note=<urlencoded>` (Step 4); the
hq-console form reads it on mount and seeds the textarea, showing a
"drafted by Claude — edit freely" hint until the user touches it.

### 4. Mint + open (share-session mode)

```bash
# Always mint with --no-open so the skill can append ?note= before
# launching the browser. (Skipping the draft step → no `?note=` param,
# behavior matches today's flow.)
URL=$(hq files share <paths...> [--company <slug>] --no-open 2>&1 \
  | grep -oE 'https://hq\.[^[:space:]]+')

# If a draft was accepted, append ?note=<urlencoded>. Use jq's @uri
# filter so newlines / quotes / unicode are encoded safely.
if [ -n "$DRAFT_NOTE" ]; then
  ENCODED=$(printf '%s' "$DRAFT_NOTE" | jq -sRr @uri)
  URL="${URL}?note=${ENCODED}"
fi

# Open in browser unless the user passed --no-open.
if [ -z "$USER_NO_OPEN" ]; then
  open "$URL" 2>/dev/null || xdg-open "$URL" 2>/dev/null
fi
```

The CLI prints `Share-session URL generated:` followed by the URL,
normalized paths, and `Expires:` timestamp. Default TTL is 15 minutes,
bounded `60s..7d`. The skill always reads the URL from `--no-open` output
and handles browser launch itself so the `?note=` param can be appended
without a CLI release.

### 4b. Write the grant + verify (direct-grant mode)

```bash
hq files share <prefix> --with <principal> --permission <level> [--company <slug>]
# → Granted read on reports/q3/* to [EMAIL]
#   (or "Created ACL and granted ..." if no ACL row existed yet)

# Verify the grant landed — the displayed pattern should end in /* for a folder
hq files acl <prefix> --company <slug>
```

Confirm the `hq files acl` output shows the grantee with the expected
permission and the pattern you intended (folder grants normalize to `/*` — a
bare prefix with no `/*` covers only a literal key and almost certainly does
nothing; if so, `unshare` and re-grant with the trailing slash). Then surface
a plain, one-line confirmation in chat:

> Granted **read** on `reports/q3/*` to **[EMAIL]**.

This path produces **no URL** — the share-session capability / Markdown-render
/ redaction rules (Step 5, Rules #1–2) do **not** apply here. `hq files share`
only writes the ACL; it does not upload files. If the prefix maps to a local
`companies/{company}/` path that hasn't been pushed, run
`hq sync push <local-path> --company <slug> --on-conflict keep` first
(hq-files "Rules for Agent Workflows" #3). **Stop here — skip Step 5.**

### 5. Surface the URL + safe metadata (share-session mode)

Default to handing the user a working link back in chat — that's the whole
point of running `/hq-share` in share-session mode. Report:

- the share-session URL **rendered only as a Markdown inline link**, as the
  headline answer — label = purpose + expiry, href = the full URL with the
  token intact, e.g.
  `[Open share-session link — expires 03:47Z ›](https://hq.{co}.com/share-session/<token>)`.
  NEVER print the bare URL or token as visible text this turn (no code-fenced
  URL, no "here's the link: https://…", no plaintext alongside); the label
  MUST NOT contain any part of the token. This is the minting turn — the one
  surface where the real token is permitted, and only inside the Markdown
  href. Full rule:
  [`hq-secure-link-render-as-markdown`](../../policies/hq-secure-link-render-as-markdown.md).
- `Expires:` timestamp from the CLI output (fold it into the link label)
- resolved paths (normalized form, e.g. `reports/q3/*`)
- company slug

Do **not** echo the URL again in any *subsequent* assistant turn, summary,
journal, thread file, commit message, PR body, learning, or other persisted
artifact — in those contexts use the redacted form
`https://hq.{co}.com/share-session/<TOKEN_REDACTED>`. Full constraint set:
[`hq-share-session-urls-are-capabilities`](../../policies/hq-share-session-urls-are-capabilities.md).

## Rules

1. **Render as a Markdown link at mint, once, then never again.** *(Share-session
   mode only — a direct grant (Step 4b) produces no URL and this rule does not
   apply to its `Granted …` output.)* The minting
   turn (Step 5) is the one surface where the unredacted share-session URL is
   permitted, and it must appear **only inside a Markdown inline link**
   (`[label](url)`) — never as bare visible text. The label carries purpose +
   expiry; the href carries the token. See
   [`hq-secure-link-render-as-markdown`](../../policies/hq-secure-link-render-as-markdown.md).
   After that, keep the URL out of every persisted surface:
   journals, thread files (`workspace/threads/`), commit messages, PR
   descriptions, learnings, Slack/email surfaces, worker handoff payloads,
   and any subsequent assistant turn that summarizes the action. A
   share-session URL is a live, encrypted, single-use, 15-minute capability
   — any holder can redeem it to write ACLs in the issuer's name. The TTL
   is defense in depth, not a license to log it. Full rules:
   [`hq-files`](../hq-files/SKILL.md) → "Rules for Agent Workflows" #10 and
   [`hq-share-session-urls-are-capabilities`](../../policies/hq-share-session-urls-are-capabilities.md).

2. **Mint a fresh URL when an old one fails.** Tokens are single-use by
   design. If the recipient reports an `expired` (403) or
   `nonce_already_claimed` (409) error, re-run `/hq-share` to mint a new
   URL rather than extending TTLs server-side or debugging the failed token.

3. **For company-wide intent,** prefer the direct grant
   `hq files share <prefix> --with @all --permission read` over the legacy
   `open` flag. The browser flow also exposes a "Share with All" toggle that
   writes the same `granteeType: 'company-wide'` entry.

4. **Widening to `write`** is a privilege escalation. Confirm with the user
   before submitting `write` grants — true whether picked in the browser or
   via direct grant.

5. **Use `--no-open` in headless contexts.** Background orchestrators,
   scheduled tasks, and sub-agents have no browser to launch into. The flag
   tells the CLI to print the URL and exit, leaving the human handoff for the
   parent session to coordinate over a side channel.

6. **Who can share.** Applies to both modes. Owners and admins resolve to
   `admin` on any prefix via role bypass — they can always mint share-session
   URLs and write grants, even on prefixes they have no explicit ACL grant on.
   Members and guests need an explicit grant on every requested path, and a
   direct grant additionally requires their effective permission be ≥ the level
   being granted; **non-bypass roles cannot grant `admin`**. Without sufficient
   permission the server returns `403 Forbidden: caller has no permission on
   path '<prefix>'` (or `lacks '<perm>'`). If a share fails for an admin user,
   suspect a stale auth session (re-run `/hq-login`) before assuming a
   permission gap. See [`hq-files`](../hq-files/SKILL.md) → "Permission Model"
   for the full mutation matrix (grant vs revoke vs create/delete).

7. **A direct grant is dormant until the recipient signs in.** Granting `read`
   to an email that has no HQ identity does not notify or deliver anything — the
   ACL entry simply activates when that person signs into HQ with that address.
   A vault grant is an access rule, not a delivery channel (policy
   `hq-vault-grant-dormant-until-external-signs-in`). If the user's intent is to
   *send* something to someone right now, a share-session link (which they can
   open immediately) or a `/dm` is the better tool.

8. **Not the path for company-wide infra distribution.** Company team members
   already get company-vault content by membership/role via sync — not per-path
   grants. To distribute company infrastructure, use `hq sync push --company
   <slug>`, not `/hq-share` (policy
   `hq-company-infra-distributes-by-membership-sync-push`). Reserve `/hq-share`
   grants for specific paths to specific principals (external / cross-company,
   or a deliberate `@all` read share of one prefix).

9. **The agent-drafted note is a starting point, never an assertion.**
   *(Share-session mode only.)* The
   draft from Step 3.5 lands in the recipient's macOS notification body
   verbatim — keep it factual ("Sharing the Q3 retro for review"), avoid
   speculation about the recipient's response or the contents' importance
   ("urgent", "you'll love this", "make sure to read carefully"), and never
   include anything the sender hasn't seen. The sender ALWAYS gets the
   textarea pre-filled in the browser and is the final approver — but a
   misleading or pushy draft they have to delete is worse than no draft at
   all. If the inventory step produced nothing usable (binary blob, single
   opaque file, no README), skip the draft and let the sender type their
   own note rather than padding the textarea with filler.

## Requires

- `@indigoai-us/hq-cli` **≥ 5.12.x (post-`f71dbf3`)** — the no-`--with`
  browser flow first ships in those commits. Check `hq --version`; upgrade
  via `npm i -g @indigoai-us/hq-cli@latest`.

## See Also

- [`hq-files`](../hq-files/SKILL.md) — full `hq files` reference: share,
  unshare, acl, prefix conventions, permission model, group grantees,
  share-session token internals, error reference
- [`hq-login`](../hq-login/SKILL.md) · [`hq-whoami`](../hq-whoami/SKILL.md) ·
  [`hq-logout`](../hq-logout/SKILL.md) — auth state machinery for
  `~/.hq/cognito-tokens.json`
- `companies/{company}/projects/hq-share/` — PRD, ADRs, and brainstorm behind
  the flow (token-based public page, `granteeType: 'company-wide'`)
