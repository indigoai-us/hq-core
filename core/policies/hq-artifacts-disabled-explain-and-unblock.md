---
id: hq-artifacts-disabled-explain-and-unblock
title: When artifacts or canvases will not open, explain the HQ setting and offer an update-proof override
when: disableArtifact || ((artifact || artifacts || canvas || canvases) && (claude || open || enable || turn || create || make || failed || unavailable || blocked || cannot || why)) || (claude && design && (canvas || artifact))
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
tier: 1
version: 3
created: 2026-11-03
public: true
---

## Rule

HQ ships `"disableArtifact": true` in `.claude/settings.json`, so Claude's artifact tool, and the Claude Design canvases built on it, are off in an HQ folder. When a user asks to make an artifact or canvas, or asks why one failed, say so first:

1. Tell them plainly: artifacts are off in HQ by default because an artifact shared from Claude skips HQ's sharing permissions. HQ shares finished work through `/deploy` (links) and `/hq-share` (vault files).
2. Offer both paths and let them choose: keep the default and deliver through `/deploy` or `/hq-share`, or turn artifacts on for their own drafts and design work.
3. Never turn it on by editing the shipped `.claude/settings.json`: `/update-hq` replaces that file, so the change is lost on the next update. If the user already edited it, tell them it will be overwritten.
4. To turn it on, ask whether they want an override that survives HQ updates. With their yes, use the `settings-override` skill to write `"disableArtifact": false` to `.claude/settings.local.json`. Claude does not apply that key from local.json, so `/update-hq` runs `restore-hook-settings.sh`, which copies a boolean `disableArtifact` from local.json into `.claude/settings.json`. Tell them to restart the session. Do not hand-edit `.claude/settings.json`.
5. Delivery still follows `hq-prefer-native-capabilities`: an artifact is a draft or preview; the finished result goes through `/deploy` or `/hq-share`.
6. Do not report "the artifact tool is unavailable" or "I can't do that" without naming this setting.
