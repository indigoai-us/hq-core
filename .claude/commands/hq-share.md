---
description: Mint a single-use share-session link for HQ vault paths — opens the picker page in your browser to grant multiple recipients in one batch
allowed-tools: Bash(hq:*), Bash(test:*), Bash(jq:*)
argument-hint: "<path>... [--company <slug>] [--no-open]"
visibility: public
---

# /hq-share — Create vault share link

Thin wrapper around the browser-launch share-session flow for one or more HQ
vault prefixes. The CLI mints an encrypted single-use token, opens the
share-session page in your default browser, and lets you pick recipients
(members, groups, "Share with All") with per-recipient read/write — then
submits every grant in one round-trip.

For single-recipient or scripted grants, use direct grant instead
(`hq files share <prefix> --with <principal> --permission <level>`) — one
CLI call, no browser hop. See `.claude/skills/hq-files/SKILL.md` →
"Choosing between direct grant and the browser flow".

## Usage

```
/hq-share <path>... [--company <slug>] [--no-open]
```

Examples:

```
/hq-share reports/q3/
/hq-share reports/q3/ docs/handbook/ --company {company}
/hq-share announcements/ --no-open               # print URL, don't launch browser
```

## Steps

1. **Probe auth** — `test -f ~/.hq/cognito-tokens.json`. If absent, stop and
   print `Not signed in. Run /hq-login first.`

2. **Parse arguments** — split `$ARGUMENTS` into:
   - one or more `<path>` positionals (required; trailing slash → folder
     prefix per `.claude/skills/hq-files/SKILL.md` → "Prefix Conventions")
   - optional flags: `--company <slug>`, `--no-open`

   If no positionals are supplied, print the usage block above and stop.

3. **Confirm scope before minting** — echo back to the user the resolved
   paths and the company (from `--company` or the active company in
   `~/.hq/config.json`). Granting on the wrong company uid is hard to clean
   up — pause for approval if anything looks off, then proceed.

4. **Mint + open** — run exactly:

   ```bash
   hq files share <paths...> [--company <slug>] [--no-open]
   ```

   The CLI prints `Share-session URL generated:` followed by the URL,
   normalized paths, and `Expires:` timestamp. (Default TTL is 15 min,
   bounded 60s..7d.)

5. **Surface the URL + safe metadata** — default to handing the user back a
   working link. Report:
   - the **full share-session URL** inline as the headline answer (this is
     the minting turn — the one surface where the capability policy permits
     the real token to appear)
   - `Expires:` timestamp from the CLI output
   - resolved paths (normalized form, e.g. `reports/q3/*`)
   - company slug

   Do **not** echo the URL again in any *subsequent* assistant turn,
   summary, journal, thread file, commit message, PR body, learning, or
   other persisted artifact — in those contexts use the redacted form
   `https://hq.{co}.com/share-session/<TOKEN_REDACTED>`. Full constraint
   set: `.claude/policies/hq-share-session-urls-are-capabilities.md`.

## Rules

- **Print the URL once at mint, then never again.** The minting turn (Step
  5) is the only surface where the unredacted share-session URL is
  permitted. Do not paste it into journals, thread files
  (`workspace/threads/`), commit messages, PR descriptions, learnings,
  Slack/email surfaces, worker handoff payloads, or any subsequent
  assistant turn that summarizes or revisits the action. A share-session
  URL is a live, encrypted, single-use, 15-minute capability — any holder
  can redeem it to write ACLs in the issuer's name. The TTL is defense in
  depth, not a license to log it. Full rules:
  `.claude/skills/hq-files/SKILL.md` § "Rules for Agent Workflows" #10
  and `.claude/policies/hq-share-session-urls-are-capabilities.md`.

- **Token re-use is impossible by design.** If the recipient says "the
  link doesn't work," re-run `/hq-share` to mint a fresh URL. Do not
  attempt to extend TTLs server-side or debug an expired / already-claimed
  token (HTTP `403 expired` or `409 nonce_already_claimed`).

- **For company-wide intent,** prefer the direct grant
  `hq files share <prefix> --with @all --permission read` over the legacy
  `open` flag. The browser flow also exposes a "Share with All" toggle
  that writes the same `granteeType: 'company-wide'` entry.

- **Widening to `write`** is a privilege escalation. Confirm with the user
  before submitting `write` grants — true whether picked in the browser or
  via direct grant.

## Requires

- `@indigoai-us/hq-cli` **≥ 5.12.x (post-`f71dbf3`)** — the no-`--with`
  browser flow first ships in those commits. Check `hq --version`; upgrade
  via `npm i -g @indigoai-us/hq-cli@latest`.

## See Also

- `.claude/skills/hq-files/SKILL.md` — full `hq files` reference: share,
  unshare, acl, prefix conventions, permission model, group grantees,
  share-session token internals, error reference
- `/hq-login` · `/hq-whoami` · `/hq-logout` — auth state machinery for
  `~/.hq/cognito-tokens.json`
- `companies/{company}/projects/hq-share/` — PRD, ADRs, and brainstorm that
  built this flow (token-based public page, `granteeType: 'company-wide'`)
