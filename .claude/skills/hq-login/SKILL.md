---
name: hq-login
description: Sign into HQ Cognito, preferring status, refresh, then browser login.
allowed-tools: Bash(hq:*), Bash(jq:*), Bash(cat:*), Bash(date:*), Bash(test:*), Bash(ls:*)
---

# /hq-login — HQ Cognito sign-in

Ensures `~/.hq/cognito-tokens.json` holds a valid access token. Prefers the
cheapest viable path: status → refresh → browser login. Wraps the `hq auth`
primitives — adds no auth logic.

## Steps

1. **Status check** — `hq auth status`. If a valid session is cached, print
   identity + expiry and exit 0. Done.

2. **Silent refresh** — if status reports expired, run `hq auth refresh`.
   On success, run `hq auth status` again to print the new expiry.

3. **Browser login** — if refresh fails (refresh token revoked / expired),
   run `hq auth login` (opens Cognito Hosted UI in the default browser via
   the loopback callback on port 8765). Wait for completion; the command
   returns once the token is cached.

4. **Final report** — print `hq auth status` so the user sees who they are
   and how long the new session lasts.

## Notes

- All four `hq auth` subcommands write to `~/.hq/cognito-tokens.json` —
  same file consumed by `/deploy` (see `.claude/skills/deploy/SKILL.md`).
- The shared HQ Identity pool is managed by the HQ cloud backend;
  CLI version ≥5.4 is required for `hq-auth-refresh`.
- If the user is already signed in, this command is a no-op.
