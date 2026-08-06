---
type: reference
domain: [engineering, operations]
status: canonical
tags: [auth-profiles, browser-state, credentials, agent-browser, sessions]
relates_to: []
---

# Auth Profiles

## Storage Convention

All browser auth state files: `core/settings/{company}/browser-state/{service}-auth.json`

| Service | State File | Company |
|---------|-----------|---------|
| X/Twitter | `core/settings/personal/browser-state/x-auth.json` | personal |
| LinkedIn | `core/settings/personal/browser-state/linkedin-auth.json` | personal |
| Invoices | `core/settings/personal/browser-state/invoices-auth.json` | personal |

## Bootstrap (First Time)

```bash
# X
agent-browser --headed open "https://x.com/login"
# Login manually, complete 2FA if prompted
agent-browser state save core/settings/personal/browser-state/x-auth.json
agent-browser close

# LinkedIn
agent-browser --headed open "https://www.linkedin.com/login"
# Login manually
agent-browser state save core/settings/personal/browser-state/linkedin-auth.json
agent-browser close

# Invoices (password auth)
agent-browser open "https://invoices.{your-name}.com/admin"
agent-browser snapshot -i
agent-browser fill @e1 "$INVOICE_PASSWORD"   # source from hq secrets — see Vault-Backed Auth below
agent-browser click @e2
agent-browser wait --load networkidle
agent-browser state save core/settings/personal/browser-state/invoices-auth.json
agent-browser close
```

## Re-Auth Flow (When State Expires)

Commands should detect auth expiry and re-auth automatically:

```bash
agent-browser state load <state-file>
agent-browser open "<target-url>"
agent-browser wait --load networkidle
URL=$(agent-browser get url --json)

# If redirected to login page
if [[ "$URL" == *"login"* ]] || [[ "$URL" == *"signin"* ]]; then
  # Re-auth in headed mode
  agent-browser --headed open "<login-url>"
  # User logs in manually
  agent-browser state save <state-file>
fi
```

## Vault-Backed Auth (hq secrets)

When a company holds the credential as a vault secret, source it from `hq secrets exec` rather than typing it manually or storing a long-lived state file. The secret is injected as an environment variable into the child process only — it never enters model context, never lands in shell history, and is never printed.

`hq secrets exec` keeps the original secret name as the env var name, so a slash-bearing name like `SERVICE/API_KEY` is read with `printenv`, not `$SERVICE/API_KEY`.

### Token / header auth (cleanest — no login flow)

```bash
hq secrets exec --company <co> --only "SERVICE/API_KEY" -- bash -c '
  TOK=$(printenv "SERVICE/API_KEY")
  agent-browser --headers "{\"Authorization\":\"Bearer $TOK\"}" open https://api.example.com/v2/self
  agent-browser get text body        # authenticated response — token never printed
  agent-browser close
'
```

`--headers` is scoped to the URL's origin, so the token does not leak to other domains the session later visits.

### Password / form login

```bash
hq secrets exec --company <co> --only APP_PASSWORD -- bash -c '
  agent-browser open "https://app.example.com/login"
  agent-browser snapshot -i
  agent-browser fill @e1 "$APP_USERNAME"
  agent-browser fill @e2 "$(printenv APP_PASSWORD)"
  agent-browser click @e3
  agent-browser wait --load networkidle
  # Optionally persist the resulting session for reuse:
  agent-browser state save core/settings/<co>/browser-state/<service>-auth.json
  agent-browser close
'
```

Use the vault path for token/password-bearing services. Fall back to the manual headed-login + state-file path (above) only for cookie/SSO/2FA sites where no reusable secret exists.

## Security

- State files contain session cookies/tokens — NEVER commit to git
- `**/browser-state/*.json` is in `.gitignore`
- Rotate state files if machine is compromised
- Vault secrets: never `--reveal` into a command line, never echo. Reference via `printenv` inside the `hq secrets exec` child shell so the value stays out of model context and shell history.
