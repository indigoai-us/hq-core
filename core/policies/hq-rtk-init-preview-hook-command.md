---
id: hq-rtk-init-preview-hook-command
title: Preview rtk's hook command before letting rtk init write project files
scope: global
trigger: When installing or trialing `rtk` (token-compression hook) in an HQ-scoped project or company subtree
enforcement: soft
public: true
version: 1
created: 2026-04-18
updated: 2026-04-18
source: session-learning
---

## Rule

ALWAYS preview rtk's hook command via `rtk init --no-patch --hook-only -g` before letting `rtk init` write to project files.

Default `rtk init` (project-local, without flags) writes a 138-line root `CLAUDE.md` into the target directory. Claude Code auto-loads root `CLAUDE.md` as context on every session, so the rtk-generated content becomes permanent context pollution (~138 lines × every session) even though only the hook string is functionally required.

Correct trial flow:

1. `rtk init --no-patch --hook-only -g` — prints the hook command string (typically `rtk hook claude`) without writing any files.
2. Hand-write the hook block into the target settings file (`.claude/settings.local.json` for trials — see the `hq-trial-hooks-stage-in-settings-local` policy).
3. Never run bare `rtk init` in an HQ project or company subtree.

## Rationale

Caught while trialing rtk in HQ (commit `191e7cb2b` — "trial(rtk): add HQ-scoped token-compression hook behind HQ_RTK_DISABLED kill switch"). The first attempt used `rtk init` and landed a full 138-line `CLAUDE.md` that would have been auto-loaded on every HQ session — a large, silent context cost for a tool whose only runtime contribution is a single hook invocation. The `--hook-only -g` dry-run surfaces the actual command (`rtk hook claude`) so it can be staged deliberately into `settings.local.json` instead.
