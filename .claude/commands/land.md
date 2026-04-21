---
description: Land a PR — monitor CI, resolve review issues, merge, monitor production
allowed-tools: Bash, Read, Grep, Glob, Write, Edit, Agent, AskUserQuestion
argument-hint: [PR-number-or-URL]
visibility: public
---

# /land - Land a PR

Land a PR from "open" to "merged and verified in production." Run the `land` skill for the full landing sequence.

**Input:** $ARGUMENTS

## Steps

1. Load the land skill from `.claude/skills/land/SKILL.md`
2. Parse `$ARGUMENTS` — accepts PR number, PR URL, or no argument (finds PR for current branch)
3. Execute the 4-step pipeline: Monitor CI → Resolve reviews → Merge (squash by default) → Monitor production
