---
name: review
description: Paranoid pre-landing code review. Reads git diff, runs two-pass analysis (CRITICAL blocks PR, INFORMATIONAL goes in body), surfaces issues with file:line references. Use when reviewing code before creating a PR, after finishing implementation, or when asked to review changes.
allowed-tools: Read, Grep, Glob, Bash(git:*), AskUserQuestion
---

# Pre-Landing Code Review

Semantic code review that reads the diff and reasons about correctness, security, and edge cases. Complements `/quality-gate` (mechanical checks) — run both before `/pr`.

## Process

```
VALIDATE BRANCH → LOAD CHECKLIST → GET DIFF → TWO-PASS ANALYSIS → REPORT
```

### Step 1: Branch Validation

Confirm you're not on main and have changes to review.

```bash
git rev-parse --abbrev-ref HEAD   # must not be main/master
git diff origin/main --stat       # must have changes
```

If on main or no changes: stop and tell user.

### Step 2: Load Checklist

Check for repo-local override first, fall back to shared default:

1. Detect repo root: `git rev-parse --show-toplevel`
2. Check: `{repo}/.claude/review-checklist.md` — if exists, use it
3. Fallback: `.claude/skills/review/checklist.md` (this skill's default)

If no checklist found: stop — review requires a checklist to operate.

### Step 3: Retrieve Diff

```bash
git fetch origin main 2>/dev/null
git diff origin/main
```

Read the FULL diff before flagging anything. Issues already addressed within the diff are not issues.

### Step 4: Two-Pass Analysis

Run the checklist categories against the diff:

- **Pass 1 (CRITICAL)** — blocking issues. These must be resolved before PR creation.
- **Pass 2 (INFORMATIONAL)** — non-blocking issues. Included in PR body for reviewer awareness.

For each finding:
- Cite `file:line` precisely
- One line describing the problem
- One line with the fix
- No preamble, no "looks good overall," no filler

### Step 5: Report & Interact

**Output format:**

```
Pre-Landing Review: N issues (X critical, Y informational)

CRITICAL (blocking):
- [file:line] Problem description
  Fix: suggested fix

INFORMATIONAL (non-blocking):
- [file:line] Problem description
  Fix: suggested fix
```

If no issues: `Pre-Landing Review: No issues found.`

**For each CRITICAL finding:** present one at a time via AskUserQuestion with three options:
- A) Fix now — apply the suggested fix
- B) Acknowledge — proceed despite the issue (user accepts risk)
- C) False positive — suppress in future reviews

One issue per question. Never batch. Recommend which option and why.

**After all critical issues resolved:** list informational findings in a single block. Suggest including them in the PR description.

## Rules

- **Read-only default.** No file modifications unless user explicitly approves a fix.
- **Exhaustive reporting.** Surface all findings — do not quietly skip issues.
- **No premature action.** Never commit, push, or create PRs.
- **Context-aware.** Read the FULL diff before commenting. Don't flag issues already fixed within the diff.
- **Terse.** One-line problems, one-line fixes. No summaries, no preamble.
- **Checklist-driven.** Only flag categories defined in the loaded checklist.

## Integration

After review completes with no unresolved critical issues:
- Suggest running `/quality-gate` for mechanical checks (types, lint, tests)
- Suggest running `/pr` to create the pull request
