---
description: Start a work session — pick company, project, or repo, gather context, and surface worker routes
allowed-tools: Read, Glob, Grep, Bash, AskUserQuestion
argument-hint: [company-or-project-or-repo]
visibility: public
---

# /startwork - Start Work Session

Run the `/startwork` skill to lightweight-load session context — resolves company/project/repo, reads handoff.json + manifest, loads policy frontmatter, builds a worker packet, and presents smart options.

**Argument:** $ARGUMENTS

## Steps

1. Load the startwork skill from `.claude/skills/startwork/SKILL.md`
2. Resolve `$ARGUMENTS` to mode: Resume (no arg) | Company | Project | Repo | Task
3. Execute the 3-step process: resolve argument → gather context + load policy frontmatter (prefers SessionStart `_digest.md`) + Worker Packet → present orientation block + worker-first options via AskUserQuestion

## After Startwork

- If user picks a project story: prefer `/execute-task {project}/{story-id}` so declared workers and story gates run
- If user picks "Run a worker" or a proposed worker phase: ask which worker/skill, then `/run {worker}`
- If user picks "Open repo (no project)": proceed as free-form coding session
- If user picks a free-text task pipeline: run the matching worker-backed path unless they explicitly choose direct execution
- Never read INDEX.md, agents files, or company knowledge dirs during startup
