---
name: hq-login
description: Sign into HQ Cognito, preferring status, refresh, then browser login.
allowed-tools: Bash(hq:*), Bash(jq:*), Bash(cat:*), Bash(date:*), Bash(test:*), Bash(ls:*)
---

# /hq-login — HQ Cognito sign-in

Ensures `~/.hq/cognito-tokens.json` holds a valid access token. Prefers the
cheapest viable path: status → refresh → browser login. Uses the owning identity commands and `hq auth refresh`.

## Steps

1. **Status check** — `hq whoami --json`. Inspect `.authenticated`, not the process exit code (signed-out also exits 0).
   If true, print the identity and finish.

2. **Silent refresh** — if `.authenticated` is false, run `hq auth refresh`.
   On success, run `hq whoami --json` again and require `.authenticated` to be true.

3. **Browser login** — if refresh fails (refresh token revoked / expired),
   run `hq login` (opens Cognito Hosted UI in the default browser via
   the loopback callback on port 8765). Wait for completion; the command
   returns once the token is cached.

4. **Final report** — use `hq whoami --json` to show the identity and read
   `.sessionExpiresAt` for the session expiry and `.sessionExpiring` for the renewal hint.
   If expiry is null, report that it is unavailable.

## Notes

- Login and refresh update `~/.hq/cognito-tokens.json`; whoami is read-only.
- Read identity and expiry through `hq whoami --json`; do not read the token file
  to report session status. Never print tokens.
- The shared HQ Identity pool is managed by the HQ cloud backend;
  CLI version ≥5.4 is required for `hq-auth-refresh`.
- If the user is already signed in, this command is a no-op.

## See also

- `/hq-whoami` — check the active identity
- `/hq-logout` — clear the session
