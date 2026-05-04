---
description: Paranoid pre-landing code review — four-severity analysis (critical/high/medium/info) with file:line references; optional --architect-pass adds deep-module structural critique
allowed-tools: Task, Read, Grep, Glob, Bash(git:*), AskUserQuestion
pack: dev
visibility: public
argument-hint: "[--architect-pass]"
---

# Pre-Landing Code Review

Run the `/review` skill to perform a semantic code review of the current branch diff.

**Input:** $ARGUMENTS

## Severity Gradations

| Level | Gate behavior | Typical content |
|---|---|---|
| `critical` | Blocks PR (per-issue AskUserQuestion: Fix / Acknowledge / False positive) | Security, data loss, race conditions, injection, broken contracts |
| `high` | Strongly recommend fix; per-issue AskUserQuestion (Fix / Acknowledge / Defer) | Likely bugs, type-safety gaps that mask real errors, dead code paths the diff touches |
| `medium` | Single batched AskUserQuestion (Fix all / Skip all / Pick) — non-blocking | Magic numbers, optional cleanup, nice-to-have refactors |
| `info` | PR body only; never asked | Style nudges, doc/comment drift, FYI |

**Backwards compat:** `INFORMATIONAL` from prior reviews maps to `medium` if the issue describes a likely fix-worthy item, else `info`. The skill chooses based on the category.

## Flags

| Flag | Default | Description |
|---|---|---|
| `--architect-pass` | off | Adds a structural critique pass (deletion test, leverage, locality, two-adapter rule) to the run. Findings emit at `medium` severity by default — promote to `high` only when the diff makes the seam tangibly worse (e.g. doubled callers, hardcoded coupling that must be unwound to extend later). Source: `.claude/skills/architect/SKILL.md` (Pocock-style deep-module analysis). |

## Steps

1. Load the review skill from `.claude/skills/review/SKILL.md`
2. Load the checklist — check for repo-local override at `{repo}/.claude/review-checklist.md`, fall back to `.claude/skills/review/checklist.md`
3. Detect `--architect-pass` flag in `$ARGUMENTS`. When present, after the standard four-pass analysis, spawn ONE Task sub-agent (`subagent_type: "general-purpose"`) running `.claude/skills/architect/SKILL.md` against the diff's changed files; merge its findings into the review report with severity capped at `high` (architectural issues never block PRs by default — promote to critical only on explicit user request).
4. Execute the 6-step review process: branch validation → checklist load → diff retrieval → four-pass severity analysis → optional architect pass → report

## After Review

- If critical issues remain unresolved: do NOT proceed to PR creation
- If high issues remain unresolved: warn but do not block; user choice via AskUserQuestion
- If all critical+high issues resolved: suggest `/quality-gate` then `/pr`
