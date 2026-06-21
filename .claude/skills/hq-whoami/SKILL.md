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

2. **Status** — `hq auth status` for cached identity + expiry. If the CLI
   reports expired, hint that `/hq-login` will silently refresh.

3. **Identity** — `hq whoami` for canonical sub/email (Cognito userInfo).

4. **Format** — collapse to one line:
   `signed in as <email> (sub <id-prefix>…) — expires in <Xh Ym>`.
   If expired: `signed in as <email> — token EXPIRED, run /hq-login`.

## Notes

- Reads `~/.hq/cognito-tokens.json` only — same file as `/deploy`,
  `/hq-login`, `/hq-logout`.
- Pool: shared HQ Identity.
- Does not refresh the token; for that, run `/hq-login` (it auto-refreshes
  if expired).

## See also

- `/hq-login` — sign in or refresh
- `/hq-logout` — sign out
