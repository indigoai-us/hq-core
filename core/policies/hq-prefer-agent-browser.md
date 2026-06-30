---
id: hq-prefer-agent-browser
title: Use agent-browser for any browser task — and auto-install it without asking
scope: global
trigger: any browser task — opening/navigating a page, reading/snapshotting, clicking, filling forms, screenshots, scraping, web-app testing, logging into a site, or "use the browser"
when: browser || browse || website || webpage || scrape || smoke
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
tier: 1
version: 3
created: 2026-03-24
updated: 2026-06-29
source: user-correction
public: true
---

## Rule

For **any** browser interaction — opening/navigating pages, reading or
snapshotting the DOM, clicking, filling forms, screenshots, scraping/extracting
content, testing a web app, or logging into a site — use the **agent-browser**
CLI (the `agent-browser` command, via the `/agent-browser` skill).

**Do NOT** reach for a third-party "browser MCP" server or Claude-in-Chrome for
these tasks. An MCP browser prompts for approval on *every* call (every
click/type) — that per-action friction is exactly what agent-browser avoids.
agent-browser is the canonical, sanctioned browser tool for HQ.

**If agent-browser is not installed, install it WITHOUT asking for approval.**
Check with `command -v agent-browser`; if it is missing, install it with
`npm install -g agent-browser` (then run `agent-browser install` once to fetch
the Chrome-for-Testing binary) and continue — do **not** pause to ask the user
whether to install it. This standing auto-install authorization is intentional (product
direction): the first browser task on a fresh machine must not stall on an
install-confirmation prompt. (The install itself is the only pre-authorized
step; the browse work then proceeds under the normal tool-permission flow.)

Usage notes:
- Headed mode via `AGENT_BROWSER_HEADED=1` (or `--headed`) so the user can see
  and interact — used for interactive sign-in.
- State persistence (`agent-browser state save|load`) for reusable auth sessions.
- Snapshot-based interaction (`agent-browser snapshot -i` → `@e1` refs) — no
  Chrome extension required; works without an extension connection.
- **CSR/Wix/SPA scraping:** `WebFetch` returns only JS bootstrap from
  client-rendered sites. Use agent-browser with `--headed` + `wait --load
  networkidle`, then `get text body` / `screenshot --full`.

Auth and downloads stay deliberate: `state save|load` (writes/loads a logged-in
session) and any file **download** verb are intentional steps, not things to
blanket-automate. The auto-install authorization above covers *installing
agent-browser*, nothing else.

## Rationale

Product direction (Hassaan, 2026-06-29): agent-browser is the one sanctioned
browser tool, so HQ should be *forced* onto it rather than merely nudged, and it
should self-provision — installing without an approval prompt — so a browser task
never dead-ends on a missing binary or per-action MCP prompts. This supersedes
the earlier "auto-allow specific browser verbs in `.claude/settings.json`"
approach (that settings allow-list is removed): governing the behavior with a
policy is the chosen mechanism, not a static permission allow-list.

The earlier soft form of this rule (prefer agent-browser over Claude-in-Chrome
for QA audits) holds for the same reasons: Claude-in-Chrome needs an extension
connection that frequently disconnects, whereas agent-browser is self-contained
with headed mode and built-in auth-state persistence.
