---
name: hq-login
description: Sign into HQ Cognito — prefer status, then refresh, then browser login
---

# HQ Cognito sign-in

Ensure `~/.hq/cognito-tokens.json` holds a valid access token, escalating
through the cheapest viable path. Wraps existing `hq auth` primitives.

## Process

### 1. Status

```bash
hq auth status
```

If output shows a valid (non-expired) session, print identity + expiry and stop.

### 2. Silent refresh

If status indicates expired, attempt a refresh-token exchange:

```bash
hq auth refresh
```

- Success → `hq auth status` again to surface the new expiry.
- Failure (`invalid_grant`, network, etc.) → fall through to step 3.

### 3. Browser login

```bash
hq auth login
```

Opens the Cognito Hosted UI (via Google IdP) and listens on a loopback port
(default 8765) for the callback. Returns once the token is written to
`~/.hq/cognito-tokens.json`.

### 4. Final status

```bash
hq auth status
```

Print to confirm identity + new expiry.

## Notes

- The token file is shared with the `/deploy` skill — once signed in, deploys
  work immediately.
- The HQ Identity pool is `us-east-1_IksCYBcBr` (hq-pro-owned, Google-only).
- Requires `@indigoai-us/hq-cli` ≥5.4 for `hq auth refresh`.
