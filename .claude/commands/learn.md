---
description: Auto-capture and classify learnings from task execution
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
argument-hint: [json-event or "rule description"]
visibility: public
---

# /learn - Automated Learning Pipeline

Run the `/learn` skill to capture a learning, classify it as rule or insight, dedupe, and inject into the correct policy or insight file. Runtime-agnostic canonical logic lives in the skill.

**Input:** $ARGUMENTS

## Steps

1. Load the learn skill from `.claude/skills/learn/SKILL.md`
2. Parse `$ARGUMENTS` into one of three modes: hook-triggered (empty/"auto"), structured JSON event, or free-text rule description
3. Execute the 9-step pipeline: load policies (frontmatter-only) → parse input → classify rule vs insight → extract rules → classify scope → dedup → scan existing → create/update policy OR insight file → global promotion → event log → reindex + rebuild policy digest → report

## After Learn

- If a policy file was created/updated, `bash scripts/build-policy-digest.sh` must run (Step 8) so SessionStart hooks pick up the change
- The event log at `workspace/learnings/learn-{timestamp}.json` is always written
- `--hard` / `--enforce` flag: equivalent to the old `/remember` command — creates learnings with `enforcement: hard`
- `/handoff` and `/checkpoint` delegate here for session insights
