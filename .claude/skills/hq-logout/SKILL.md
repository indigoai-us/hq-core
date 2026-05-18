---
name: hq-logout
description: Sign out of HQ Cognito locally — clear cached tokens
allowed-tools: Bash(hq:*), Bash(ls:*), Bash(test:*), Bash(rm:*)
---

# /hq-logout — HQ Cognito sign-out (local)

Removes the cached Cognito session at `~/.hq/cognito-tokens.json` so future
HQ-authenticated operations (deploy, vault, sync) require a fresh sign-in.

**Local only.** Refresh tokens remain valid server-side until they expire
naturally — they just can't be used without `~/.hq/cognito-tokens.json`. If
you need to revoke at the pool, ask for AWS Cognito GlobalSignOut explicitly
(not in scope here).

## Steps

1. **Probe** — `test -f ~/.hq/cognito-tokens.json`. If absent, report
   "already signed out" and exit.

2. **Clear** — `hq auth logout` (delegates to `@indigoai-us/hq-cli`'s
   logout subcommand, which removes the token file).

3. **Confirm** — `test ! -f ~/.hq/cognito-tokens.json` and report success.

## Notes

- Same file consumed by `/deploy` — after this, `/hq-login` (or any deploy)
  will trigger a fresh browser flow.
- Does NOT touch `~/.hq-deploy/config.json` (that's the unrelated
  `hq-deploy` CLI's API-key store, not currently used here).
