---
name: hq-whoami
description: Show current HQ Cognito identity and session expiry.
allowed-tools: Bash(hq:*), Bash(jq:*), Bash(cat:*), Bash(date:*), Bash(test:*)
---

# /hq-whoami — HQ Cognito identity

One-liner status: who is signed into the local HQ Cognito session, and how
long the cached access token has left. Read-only — touches nothing.

## Steps

1. **Probe** — `test -f ~/.hq/cognito-tokens.json`. If absent, print
   "Not signed in. Run `/hq-login`." and exit 0.

2. **Status** — `hq whoami --json` for cached identity. Inspect `.authenticated`; exit 0 alone does not prove a valid session.
   If false, hint that `/hq-login` can refresh or sign in.

3. **Identity and expiry** — use the identity fields and `.sessionExpiresAt` from
   `hq whoami --json`. Use `.sessionExpiring` as the renewal hint. If expiry is null,
   report that it is unavailable; do not read the token file.

4. **Format** — collapse to one line:
   `signed in as <email> (sub <id-prefix>…) — expires in <Xh Ym>`.
   If expired: `signed in as <email> — token EXPIRED, run /hq-login`.

## Notes

- Reads identity and expiry through `hq whoami --json`; never prints token fields.
- Pool: shared HQ Identity.
- Does not refresh the token; for that, run `/hq-login` (it auto-refreshes
  if expired).

## See also

- `/hq-login` — sign in or refresh
- `/hq-logout` — sign out
