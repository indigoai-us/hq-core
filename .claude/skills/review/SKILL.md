---
name: review
description: "Pre-landing code review of the git diff; critical issues block the PR. Use before a PR or when asked to review changes."
allowed-tools: Read, Grep, Glob, Bash(git:*), Bash(bash:*), Bash(bash "$HQ_ROOT/core/scripts/commit-secret-scan.sh:*), Bash(bash "$HQ_ROOT/core/scripts/review-checkout.sh:*), Bash(gh pr checks:*), AskUserQuestion, Task
---

# Pre-Landing Code Review

Semantic code review that reads the diff and reasons about correctness, security, and edge cases. Complements `/quality-gate` (mechanical checks) — run both before opening the pull request.

## Process

```
VALIDATE BRANCH → LOAD CHECKLIST → GET DIFF → SECRET SCAN → TWO-PASS ANALYSIS → REPORT
```

### Step 1: Branch Validation

Confirm you're not on main and have changes to review.

```bash
git rev-parse --abbrev-ref HEAD   # must not be main/master
git diff origin/main --stat       # must have changes
```

If on main or no changes: stop and tell user.

### Step 1b: Reviewing someone else's PR

When the change is another author's pull request, not your own branch, review
it in the cached checkout for that repo. Do not make a fresh clone per PR or
per PR head, and do not put review checkouts in `/tmp`. Policy:
`hq-pr-review-light-local-footprint`.

```bash
bash "$HQ_ROOT/core/scripts/review-checkout.sh" prepare --repo OWNER/NAME --pr N
bash "$HQ_ROOT/core/scripts/review-checkout.sh" affected --repo OWNER/NAME
gh pr checks N -R OWNER/NAME
```

`prepare` prints `checkout=`, `install=` and `changed=` lines. `affected`
prints `package=` and `test=` lines for the diff. `gh pr checks` is the
full-suite evidence, from CI.

- Run Steps 2 to 5 from the printed `checkout=` directory, diffing against
  `origin/<base>` with three dots.
- Install dependencies only when `prepare` prints `install=needed`, then run
  `review-checkout.sh installed --repo OWNER/NAME`.
- Run only the tests, type checks and linters for the `package=` and `test=`
  lines. Do not run the repo's full suite locally; read the CI checks.
- Wrap every install, build, type check or test command in
  `review-checkout.sh heavy -- <command>` so only one heavy run happens at a
  time.
- After the review is posted, run
  `review-checkout.sh cleanup --repo OWNER/NAME --pr N` and delete any other
  scratch file you made. Keep review notes in `workspace/reports/reviews/`.

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

### Step 3b: Secret Scan

Scan every file the branch changed for secrets. Run it from any folder inside
the repo under review:

```bash
bash "$HQ_ROOT/core/scripts/commit-secret-scan.sh" pr-check origin/main
```

(`$HQ_ROOT` is the HQ folder; use its absolute path if the variable is unset.)
This runs whether or not commit-time scanning is turned on, and catches
anything committed with the check skipped or from another machine. It is
offline (`hq scan secrets`, hq CLI 5.345.86+) and prints rule, file and line,
never the value.

- Exit 1: each finding is a **CRITICAL** issue. The fix is to remove the
  value, rotate the credential if it was ever pushed, and keep it in the HQ
  vault (`hq secrets set`, then `hq run` / `hq secrets exec` at run time). A
  secret in an earlier commit stays in history even after it is deleted, so
  say whether the branch history needs rewriting before the PR.
- Exit 2 (scanner missing or base not found): report it as CRITICAL — the
  scan did not run — and give the fix (update the hq CLI, or pass the right
  base). Do not treat a scan that could not run as clean.
- A line that is a known false positive can carry a `gitleaks:allow` comment.

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
- Suggest opening the pull request (`bash core/scripts/hq-pr-create.sh -R {owner}/{repo} ...`), then
  `/land` to take that one PR through CI and merge, or `/ship` to run the full
  review → land → deploy → smoke → monitor pipeline
