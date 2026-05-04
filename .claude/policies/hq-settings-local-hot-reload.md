---
id: hq-settings-local-hot-reload
title: Claude Code hot-reloads settings.local.json hook edits — no session restart needed
scope: global
trigger: When iterating on hook chains, kill switches, or permission entries in `.claude/settings.local.json` mid-session
enforcement: soft
public: true
version: 1
created: 2026-04-18
updated: 2026-04-18
source: session-learning
---

## Rule

ALWAYS assume Claude Code picks up `.claude/settings.local.json` hook edits WITHOUT a session restart — the next Bash (or other relevant tool) call uses the new hook chain.

Practical consequences:

- **In-session iteration is supported.** Edit the hook, save, and invoke the tool — the updated chain runs. No `/exit` + relaunch loop required.
- **Kill-switch edits take effect immediately.** Flipping `HQ_RTK_DISABLED=1` (or equivalent) in the hook's matcher guard, or removing the hook entry, lands on the very next tool call — there's no lingering "old config cached from session start" state.
- **Always re-exercise the tool you just changed.** Don't assume your edit landed by inspection alone — run a tool that passes through the hook chain to confirm.

This applies to `.claude/settings.local.json` specifically (the user-local merge partner). `.claude/settings.json` is core.yaml-locked and should not be edited mid-session for trials; use `settings.local.json` instead (see `hq-trial-hooks-stage-in-settings-local`).

## Rationale

Observed during the rtk trial (2026-04-18 session). Added a PreToolUse hook to `.claude/settings.local.json`, then flipped the kill switch and expected to have to restart — the next Bash call already reflected the new state. Confirmed by adding a distinctive marker to the hook and watching it appear/disappear between adjacent tool calls with no session restart. Reading Claude Code's settings loader confirms: `settings.local.json` is re-read on each hook dispatch, not cached at session start. This enables rapid hook iteration and makes the kill-switch pattern genuinely instant.
