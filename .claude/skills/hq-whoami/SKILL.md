---
name: hq-whoami
description: Show HQ Cognito identity, email, and session expiry (read-only)
---

# HQ Cognito identity

Read-only status check on the cached Cognito session at
`~/.hq/cognito-tokens.json`. Does not refresh or mutate anything.

## Process

### 1. Probe

```bash
test -f ~/.hq/cognito-tokens.json
```

If absent, report `Not signed in. Run /hq-login.` and stop.

### 2. Status + identity

```bash
hq auth status
hq whoami
```

### 3. Format

Collapse to one line:

- Active: `signed in as <email> (sub <id-prefix>…) — expires in <Xh Ym>`
- Expired: `signed in as <email> — token EXPIRED, run /hq-login`

## Notes

- Read-only. To refresh, use `/hq-login` (it silently refreshes when the
  refresh token is still valid, falling back to the browser flow).
- Same token file consumed by `/deploy`, `/hq-login`, `/hq-logout`.
- HQ Identity pool: `us-east-1_IksCYBcBr` (Google IdP).
