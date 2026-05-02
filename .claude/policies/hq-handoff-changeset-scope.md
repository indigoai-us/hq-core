---
id: hq-handoff-changeset-scope
title: Handoff scope comes from changesets, not noisy HQ root status
scope: command
trigger: /handoff, scripts/handoff-finalize.sh, multi-session work in the HQ root
enforcement: hard
public: false
version: 1
created: 2026-05-01
updated: 2026-05-01
source: user-correction
---

## Rule

When the HQ root has a large untracked baseline, NEVER treat whole-repo `git status` output as the session scope. The durable scope for `/handoff` is the session changeset: `files_touched_json`, the generated `workspace/threads/<thread>.changeset.json`, and the explicit paths staged by `scripts/handoff-finalize.sh`.

Handoff output should summarize drift by category (tracked changes, session-touched untracked files, baseline noise, ignored files), not dump the entire status listing. If a needed file is not in `files_touched_json`, add it there deliberately instead of widening to `git add -A`.

## Rationale

This HQ root was initialized with an almost-empty tracked baseline while hundreds of durable local HQ files remained untracked. Treating that status noise as surprising caused Codex to improvise broad path staging during handoff. Multi-session work needs a stable changeset boundary that survives noisy local baselines.
