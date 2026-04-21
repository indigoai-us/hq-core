---
type: reference
domain: [engineering, operations]
status: canonical
tags: [auth-profiles, browser-state, credentials, agent-browser, sessions]
relates_to: []
---

# Auth Profiles

## Storage Convention

All browser auth state files: `settings/{company}/browser-state/{service}-auth.json`

| Service | State File | Company |
|---------|-----------|---------|
| X/Twitter | `settings/personal/browser-state/x-auth.json` | personal |
| LinkedIn | `settings/personal/browser-state/linkedin-auth.json` | personal |
| Invoices | `settings/personal/browser-state/invoices-auth.json` | personal |

## Bootstrap (First Time)

```bash
# X
agent-browser --headed open "https://x.com/login"
# Login manually, complete 2FA if prompted
agent-browser state save settings/personal/browser-state/x-auth.json
agent-browser close

# LinkedIn
agent-browser --headed open "https://www.linkedin.com/login"
# Login manually
agent-browser state save settings/personal/browser-state/linkedin-auth.json
agent-browser close

# Invoices (password auth)
agent-browser open "https://invoices.{your-name}.com/admin"
agent-browser snapshot -i
agent-browser fill @e1 "invoice2024"
agent-browser click @e2
agent-browser wait --load networkidle
agent-browser state save settings/personal/browser-state/invoices-auth.json
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

## Security

- State files contain session cookies/tokens — NEVER commit to git
- `**/browser-state/*.json` is in `.gitignore`
- Rotate state files if machine is compromised
