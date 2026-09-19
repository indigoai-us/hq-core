# agent-browser — HQ Browser Automation

CLI browser automation tool from Vercel. Headless by default, snapshot+refs pattern for minimal context usage.

## Architecture (v0.27+)

100% native Rust — Node.js and Playwright have been fully removed. ~10MB install, low memory, direct CDP connection to Chromium. No configuration needed.

**Limitations:** Chromium + Safari only (no Firefox/WebKit), network interception uses CDP Fetch. None affect current HQ usage.

## Installation

Install the CLI globally (the upstream-recommended method), then fetch the
Chrome-for-Testing binary on first use:

```bash
npm install -g agent-browser
agent-browser install   # one-time: downloads Chrome for Testing
```

Same native binary via other channels: `brew install agent-browser` (macOS) or
`cargo install agent-browser` (needs Rust). HQ has standing authorization to run
this install without a separate approval prompt — see the policy in
[The canonical browser tool — governed by policy](#the-canonical-browser-tool--governed-by-policy).

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

Auth state files live at `core/settings/{company}/browser-state/*.json`. Never committed (gitignored).

```bash
# First time: login manually in headed mode
agent-browser --headed open "https://x.com/login"
# ... login ...
agent-browser state save core/settings/personal/browser-state/x-auth.json
agent-browser close

# Later: load saved state
agent-browser state load core/settings/personal/browser-state/x-auth.json
agent-browser open "https://x.com"
```

## Auth Expiry Detection

After loading state, check if redirected to login:
```bash
agent-browser state load core/settings/personal/browser-state/x-auth.json
agent-browser open "https://x.com/compose/post"
agent-browser wait --load networkidle
agent-browser get url
# If URL contains "login" or "signin" → auth expired, re-auth in --headed mode
```

## Canvas-rendered apps (Google Docs and similar)

Google Docs, Sheets, Slides, Figma, and other canvas editors do not expose
the document body as ordinary DOM controls. Screenshot-measured coordinate
clicks from a browser MCP (`computer:left_click` against a reported
coordinate frame) miss the canvas — observed ~30% low/right on Google Docs
at 1277x952. Do not aim clicks from the screenshot.

Use:

1. **DOM refs** from `snapshot -i` / `find` for real controls (Find-and-replace
   dialog, link editor, menus). Then `fill @eN` / `form_input`, not a global
   `type`.
2. **Keyboard** for canvas text: arrows, cmd+Left, shift+Right, cmd+f, cmd+k.

`computer:type` / unscoped `type` follows current focus. On Google Docs that
is often the document body, so text meant for the find box can land in a live
heading and autosave. Confirm the target with a ref or a keyboard-opened
control before typing.

## Google Workspace auth

agent-browser starts its own Chrome-for-Testing browser. It **cannot reuse**
the user's already-logged-in Google Chrome or Claude-in-Chrome session.
Google Workspace docs need an interactive `--headed` sign-in the first time,
then `state save` for later `state load`. There is no silent pickup of the
host Chrome Google login.

If agent-browser is missing, install it (`npm install -g agent-browser &&
agent-browser install`) rather than falling back to coordinate clicks in
Claude-in-Chrome.

## The canonical browser tool — governed by policy

`agent-browser` is the **canonical, sanctioned** browser tool for HQ. Use it for
any browser task — navigating, reading a page, clicking, typing, screenshots,
scraping, web-app testing — instead of a third-party "browser MCP" or
Claude-in-Chrome. A browser MCP prompts for approval on *every* tool call (every
click/type), which is the per-action friction users hit; agent-browser is a
normal CLI driven by the standard tool-permission flow.

This preference is enforced by the policy
[`hq-prefer-agent-browser`](../../policies/hq-prefer-agent-browser.md), which
surfaces whenever a browser task is mentioned. That policy also grants HQ
**standing approval to install agent-browser without a separate prompt** when it
is missing — so the first browser task on a fresh machine doesn't stall on an
install confirmation. See the policy for the exact rule.

> Auth and downloads stay deliberate: `agent-browser state save|load …` (writes/
> loads a logged-in session) and the `--headed` interactive sign-in flow are how
> you authenticate, and any file **download** verb writes to disk — treat these
> as intentional steps rather than blanket-automating them.

## Key References

- Skill: `.claude/skills/agent-browser/SKILL.md`
- Auth patterns: `core/knowledge/public/agent-browser/auth-profiles.md`
- Social posting: `core/knowledge/public/agent-browser/social-posting.md`
