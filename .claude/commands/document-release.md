---
description: Post-ship documentation sync — auto-update README, CLAUDE.md, architecture docs, and INDEX files to match what shipped
allowed-tools: Read, Edit, Write, Grep, Glob, Bash(git:*), Bash(qmd:*), AskUserQuestion
argument-hint: [company] [project-slug]
visibility: public
pack: dev
---

# /document-release - Post-Ship Doc Sync

After a project ships (PR merged, deploy complete), update all project docs to match reality.

**Input:** $ARGUMENTS

**Pipeline:** `/run-project` → `/pr` → merge → **`/document-release`**

## Steps

1. Load the document-release skill from `.claude/skills/document-release/SKILL.md`
2. Resolve company + project context
3. Execute: diff analysis → doc audit → apply updates → consistency check → cleanup
4. Reindex: `qmd update 2>/dev/null || true`
