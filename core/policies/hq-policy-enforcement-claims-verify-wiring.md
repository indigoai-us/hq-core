---
id: hq-policy-enforcement-claims-verify-wiring
title: A policy enforcement claim is worthless unless verified against the actually-wired hook + settings
scope: global
trigger: writing or relying on a "hard enforcement: hook X registered in Y" sentence in any policy
when: enforcement
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
public: true
version: 1
created: 2026-05-18
updated: 2026-05-18
source: user-correction
tags: [infrastructure, safety, knowledge, docs]
---

## Rule

A sentence in a policy asserting mechanical enforcement (e.g. "hard enforcement: `.claude/hooks/foo.sh` is registered in `.claude/settings*.json`") is **not** enforcement. Before writing such a claim, the hook file MUST exist and be wired; before trusting an existing claim, verify it:

```bash
ls -la .claude/hooks/<hook>.sh                       # file exists + executable
grep -n "<hook-id>" .claude/settings.json            # wired in tracked settings
grep -n "<hook-id>" .claude/hooks/hook-gate.sh       # in all gate profiles (see hq-hook-gate-three-profile-lists)
```

If any check fails, the claim is false — fix the wiring or delete the claim. Mechanical cwd/git/safety invariants need a real PreToolUse hook, not policy prose; prose is model-facing guidance the model can and does skip under load.

## Rationale

2026-05-18: `hq-root-never-push-remote.md` v2 stated hard enforcement via `.claude/hooks/block-hq-push.sh` registered in `.claude/settings.local.json`. Neither the hook nor that settings file ever existed. Consequently a bare `git push` from the HQ root (cwd had drifted during a liverecover-gtm-hq session) was caught **only** by the `DISABLED` push-URL git-config backstop — luck, not the claimed hook. An unverified enforcement claim is strictly worse than an honest "advisory only": it suppresses the instinct to add real enforcement.
