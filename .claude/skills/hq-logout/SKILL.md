---
name: hq-logout
description: Sign out of HQ Cognito and clear local tokens.
disable-model-invocation: true
allowed-tools: Bash(hq:*), Bash(ls:*), Bash(test:*), Bash(rm:*)
---

# /hq-logout — HQ Cognito sign-out

Ends the HQ session on the server and removes the cached Cognito session at
`~/.hq/cognito-tokens.json`, so future HQ-authenticated operations (deploy,
vault, sync) require a fresh sign-in.

`hq logout` revokes the refresh token on the server first, so a copied token
file stops working, and then deletes the local tokens. If the server cannot be
reached, it still deletes the local tokens and says the session could not be
ended everywhere; the refresh token then stays valid until it expires.

## Steps

1. **Probe** — `test -f ~/.hq/cognito-tokens.json`. If absent, report
   "already signed out" and exit.

2. **Sign out** — `hq logout`. Report its message as printed: either a clean
   sign-out, or a local sign-out whose server-side revoke did not happen.

3. **Confirm** — `test ! -f ~/.hq/cognito-tokens.json` and report success.

## Notes

- Same file consumed by `/deploy` — after this, `/hq-login` (or any deploy)
  will trigger a fresh browser flow.
- Does NOT touch `~/.hq-deploy/config.json` (that's the unrelated
  `hq-deploy` CLI's API-key store, not currently used here).
- Use `hq logout`, not `hq auth logout`. On older hq-cli releases
  `hq auth logout` only deleted the local file and left the refresh token
  valid on the server.
