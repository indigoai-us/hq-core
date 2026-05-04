---
id: hq-skill-plugin-pattern
title: External skill package integration via bridge script
scope: global
trigger: integrating a third-party Claude Code skill package into HQ
enforcement: soft
version: 1
created: 2026-03-23
updated: 2026-03-23
source: success-pattern
public: true
---

## Rule

Integrate external Claude Code skill packages as namespaced plugins using the bridge
script pattern:

1. Clone repo to `repos/public/{package}/`
2. Create `scripts/{package}-bridge.sh` — iterate dirs with SKILL.md, symlink each to
   `.claude/skills/{prefix}-{name}/`. Use SKILL.md presence for dynamic discovery (no
   static skill list). Subcommands: install, remove, status, update.
3. Create `.claude/policies/{package}-prefix-mapping.md` — soft-enforcement policy
   remapping internal cross-skill references to prefixed equivalents.
4. Register in `modules/modules.yaml` under Add-On Kits.
5. Optionally create a worker that chains the package's skills.

NEVER copy or fork skill files — symlink for zero-copy upstream updates.
ALWAYS use a short prefix (e.g. `g-`) to avoid collisions with HQ skills.
ALWAYS skip infrastructure dirs (bin/, scripts/, test/) via a skip list.

## Rationale

First implemented for gstack (Garry Tan's sprint system, 26 skills). The pattern avoids
name collisions (4 skills overlap with HQ), preserves upstream updateability via
`git pull` + re-link, and uses filesystem-based discovery matching Claude Code's native
`.claude/skills/*/SKILL.md` scan.
