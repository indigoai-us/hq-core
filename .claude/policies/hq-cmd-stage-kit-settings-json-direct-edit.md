---
id: hq-cmd-stage-kit-settings-json-direct-edit
title: stage-kit cannot stage .claude/settings.json — edit hq-core-staging directly
scope: command
trigger: When a user asks `/stage-kit` to ship changes to `.claude/settings.json` or `.claude/settings.local.json`
enforcement: soft
public: true
version: 1
created: 2026-04-17
updated: 2026-04-17
source: user-correction
---

## Rule

`/stage-kit`'s Path Remapping table has no row for `.claude/settings.json` or `.claude/settings.local.json`. Attempting `/stage-kit --item .claude/settings.json` will reject at step S1 (path validation) because there is no source→destination mapping.

When the target change is settings-related:

1. Edit `repos/private/hq-core-staging/.claude/settings.json` **directly** with Edit/Write — it is the private contributor repo for the shipped HQ kernel.
2. Run the scrub-verification checks from stage-kit S3/S4/S6 manually against the edited destination file:
   - Denylist pattern grep
   - `{your-name}` literal grep
   - `ggshield secret scan path` (if installed)
3. Commit inside `repos/private/hq-core-staging/` (the contributor repo is a nested git repo — HQ root `git status` will not see the change).

The public `indigoai-us/hq-core` scaffold receives the change through the staging-to-public promotion path.

## Rationale

The stage-kit pipeline is designed for content items (commands, skills, policies, workers, knowledge) where the source lives in HQ and the destination is a mirrored scaffold repo path. Settings files don't follow that pattern — the HQ-root `settings.json` is locked and personal, so there is no HQ-side source to pipe through the scrub. The canonical workflow is to edit the private contributor repo copy directly, then lean on the same scrub checks stage-kit would have run.
