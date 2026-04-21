# agent-browser — HQ Browser Automation

CLI browser automation tool from Vercel. Headless by default, snapshot+refs pattern for minimal context usage.

## Architecture (v0.20+)

100% native Rust — Node.js and Playwright have been fully removed. 7MB install, 8MB memory, direct CDP connection to Chromium. No configuration needed.

**Limitations:** Chromium + Safari only (no Firefox/WebKit), network interception uses CDP Fetch. None affect current HQ usage.

## When to Use What

| Tool | Use For |
|------|---------|
| **agent-browser** | Social posting, invoice automation, smoke tests, any interactive headless browser task |
| **Playwright test suite** | Structured QA regression tests, axe-core a11y audits, Supabase reporting pipeline |

## Core Workflow

```bash
agent-browser open <url>
agent-browser snapshot -i        # Get @refs for interactive elements
agent-browser fill @e1 "text"    # Interact via refs
agent-browser click @e2
agent-browser close
```

## Auth Persistence

Auth state files live at `settings/{company}/browser-state/*.json`. Never committed (gitignored).

```bash
# First time: login manually in headed mode
agent-browser --headed open "https://x.com/login"
# ... login ...
agent-browser state save settings/personal/browser-state/x-auth.json
agent-browser close

# Later: load saved state
agent-browser state load settings/personal/browser-state/x-auth.json
agent-browser open "https://x.com"
```

## Auth Expiry Detection

After loading state, check if redirected to login:
```bash
agent-browser state load settings/personal/browser-state/x-auth.json
agent-browser open "https://x.com/compose/post"
agent-browser wait --load networkidle
agent-browser get url
# If URL contains "login" or "signin" → auth expired, re-auth in --headed mode
```

## Key References

- Skill: `.claude/skills/agent-browser/SKILL.md`
- Auth patterns: `knowledge/public/agent-browser/auth-profiles.md`
- Social posting: `knowledge/public/agent-browser/social-posting.md`
