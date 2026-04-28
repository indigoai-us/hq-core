---
name: hq-logout
description: Sign out of HQ Cognito locally — clear cached tokens
---

# HQ Cognito sign-out (local)

Remove `~/.hq/cognito-tokens.json` so HQ-authenticated operations require a
fresh sign-in. Local clear only — does not call AWS Cognito GlobalSignOut.

## Process

### 1. Probe

```bash
test -f ~/.hq/cognito-tokens.json && echo "found" || echo "absent"
```

If absent, report "already signed out" and stop.

### 2. Clear

```bash
hq auth logout
```

The CLI deletes `~/.hq/cognito-tokens.json`.

### 3. Confirm

```bash
test ! -f ~/.hq/cognito-tokens.json && echo "cleared"
```

## Notes

- Server-side refresh tokens stay valid until natural TTL — they're just
  unusable without the local token file. If full revocation is required,
  use AWS Cognito `admin-user-global-sign-out` separately.
- The `~/.hq-deploy/config.json` API-key store (a different CLI) is not
  touched — that path isn't in active use here.
