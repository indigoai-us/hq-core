---
id: hq-prefer-agent-browser
title: Use agent-browser for any browser task — and auto-install it without asking
when: browser || browse || website || webpage || scrape || smoke || (google && docs)
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
tier: 1
version: 4
created: 2026-03-24
updated: 2026-09-18
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
- **Canvas apps (Google Docs, Sheets, Slides, Figma, and similar):** use
  snapshot/find refs for real DOM controls (Find-and-replace, link editor,
  dialogs) and keyboard for canvas text (arrows, cmd+Left, shift+Right,
  cmd+f, cmd+k). Do **not** click from screenshot-measured coordinates.
  Browser MCP screenshot frames and the click coordinate space can disagree
  by tens of percent, so a `computer:left_click` aimed at the canvas lands
  elsewhere.
- **Never type until the target is confirmed.** `computer:type` / unscoped
  `type` follows whatever currently has focus. On Google Docs that is often
  the document body, so a find-box type can silently insert into a live
  document (and autosave). Confirm focus with a DOM ref (`fill @eN`,
  `form_input`) or a keyboard-opened control before typing.
- **Google auth is not inherited from Chrome.** agent-browser cannot reuse
  the user's logged-in Google Chrome or Claude-in-Chrome session. Opening a
  Google Workspace doc needs an interactive `--headed` sign-in (then
  `state save`). Missing agent-browser is not a reason to skip the install —
  install it, then sign in headed if the task needs Google.

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
