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
/hq-share <path>... [--company <slug>] [--no-open]
```

Examples:

```
/hq-share reports/q3/
/hq-share reports/q3/ docs/handbook/ --company {company}
/hq-share announcements/ --no-open               # print URL, headless contexts
```

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

### 4. Mint + open

```bash
hq files share <paths...> [--company <slug>] [--no-open]
```

The CLI prints `Share-session URL generated:` followed by the URL,
normalized paths, and `Expires:` timestamp. Default TTL is 15 minutes,
bounded `60s..7d`.

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
