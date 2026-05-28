---
name: hq-share
description: Mint a single-use share-session link for HQ vault paths — opens the picker page in your browser to grant multiple recipients in one batch
allowed-tools: Bash(hq:*), Bash(test:*), Bash(jq:*)
---

# HQ Share — Create vault share link

Thin wrapper around the browser-launch share-session flow for one or more HQ
vault prefixes. The CLI mints an encrypted single-use token, opens the
share-session page in your default browser, and lets the issuer pick
recipients (members, groups, "Share with All") with per-recipient read/write —
then submits every grant in one round-trip.

For single-recipient or scripted grants, prefer the direct grant form
(`hq files share <prefix> --with <principal> --permission <level>`) instead.
See the [`hq-files`](../hq-files/SKILL.md) skill → "Choosing between direct
grant and the browser flow".

## Usage

```
/hq-share <path>... [--company <slug>] [--no-open] [--no-draft]
```

Examples:

```
/hq-share reports/q3/
/hq-share reports/q3/ docs/handbook/ --company {company}
/hq-share announcements/ --no-open               # print URL, headless contexts
/hq-share reports/q3/ --no-draft                 # skip the LLM-drafted note step
```

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
  per [`hq-files`](../hq-files/SKILL.md) "Prefix Conventions")
- optional flags: `--company <slug>`, `--no-open`

If no positionals are supplied, print the usage block above and stop.

### 3. Confirm scope before minting

Echo back to the user the resolved paths and the company (from `--company`
or the active company in `~/.hq/config.json`). Granting on the wrong company
uid is hard to clean up — pause for approval if anything looks off, then
proceed.

### 3.5. Draft the note (sender-side LLM pre-fill)

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

### 4. Mint + open

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

### 5. Surface the URL + safe metadata

Default to handing the user a working link back in chat — that's the whole
point of running `/hq-share`. Report:

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

1. **Render as a Markdown link at mint, once, then never again.** The minting
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

6. **Who can mint.** Owners and admins resolve to `admin` on any prefix via
   role bypass — they can always mint share-session URLs, even on prefixes
   they have no explicit ACL grant on. Members and guests need an explicit
   grant on every requested path; without one the server returns
   `403 Forbidden: caller has no permission on path '<prefix>'`. If a mint
   fails for an admin user, suspect a stale auth session (re-run
   `/hq-login`) before assuming a permission gap. See
   [`hq-files`](../hq-files/SKILL.md) → "Permission Model" for the full
   mutation matrix (grant vs revoke vs create/delete).

7. **The agent-drafted note is a starting point, never an assertion.** The
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
