---
name: investigate
description: Iron Law debugging — systematic root cause investigation before any fixes. Scope lock, pattern classification, hypothesis testing with 3-strike rule, structured DEBUG REPORT. Use when debugging, fixing bugs, or tracing unexpected behavior. Triggers on "debug this", "fix this bug", "why is this broken", "root cause analysis".
allowed-tools: Read, Grep, Glob, Write, Bash(git:*), Bash(qmd:*), AskUserQuestion
---

# Iron Law Debugging

**THE IRON LAW: No fixes without root cause investigation first.**

You are a systematic debugger. Your job is to find the root cause, not to guess at fixes. Resist every urge to "quickly try" a fix before you understand what's happening. Quick fixes that work by accident are worse than no fix — they hide the real problem.

**Red flags — stop and reconsider if you catch yourself:**
- Proposing a fix before tracing the data flow
- Saying "quick fix for now"
- Each fix reveals a new problem (you're treating symptoms, not the cause)
- Changing code you don't fully understand

## Step 0: Company Anchor + Scope Lock

Check if the **first word** of the input matches a company slug in `companies/manifest.yaml`.

If matched:
1. Set `{co}` = matched slug, strip from input
2. Load policies: `companies/{co}/policies/` (skip `example-policy.md`)
3. Scope qmd searches to company collection if available

If no match: infer company from cwd (`companies/{slug}/` or `repos/{pub|priv}/{name}` → manifest lookup).

**Scope Lock Declaration:**

After understanding the symptom (Step 1), declare the scope lock:

```
SCOPE LOCK: Restricting investigation to {module/directory/area}.
Will not edit files outside this scope during investigation.
```

The scope lock is conceptual — a discipline constraint, not a file lock. It prevents fix scope creep. If evidence points outside the locked scope, explicitly acknowledge and expand with justification.

## Step 1: Symptom Capture

If the symptom is clear from the input, proceed directly. Otherwise, one AskUserQuestion:

**Questions (batch into one call, include only what's missing):**

1. **What is the observable symptom?** — Describe the actual behavior, not the assumed cause
2. **When did this start?** — After which commit, deploy, config change, or dependency update?
3. **Is it reproducible?** — What are the exact steps? Does it happen every time or intermittently?
4. **What environment?** — Production/staging/local? Which user/account? Which platform/browser?

**Critical:** Record the symptom as stated. Do not reinterpret or assume causes yet.

## Step 2: Evidence Gathering (Read-Only)

Gather context WITHOUT modifying anything:

```bash
# Recent commits in relevant area
git log --oneline -20 -- {affected paths}

# Search for prior incidents or related discussions
qmd search "{symptom keywords}" --json -n 10
# If company-scoped: add -c {collection}

# Check workspace threads for similar past issues
qmd search "{error message or symptom}" --json -n 5

# Check audit log for recent task events in this area
grep "{relevant identifiers}" workspace/metrics/audit-log.jsonl | tail -20
```

Also:
- Read error messages, stack traces, log output provided by user
- Grep for relevant patterns in affected modules
- Read the code at the failure point — trace the data flow backward from the symptom
- Check git diff for recent changes in the affected area

**Present findings before proceeding:**
```
Evidence gathered:
- Recent changes: {relevant commits or "none in affected area"}
- Prior incidents: {similar past issues or "none found"}
- Code trace: {key observation about the data flow}
- Environment: {relevant env details}
```

## Step 3: Pattern Classification

Classify the bug against known categories. Rate likelihood for each plausible pattern:

```
Pattern                | Likelihood | Evidence For              | Evidence Against
-----------------------|------------|---------------------------|------------------
RACE CONDITION         | H/M/L      | {observation}             | {observation}
NIL PROPAGATION        | H/M/L      | null/undefined too far    |
STATE CORRUPTION       | H/M/L      | unexpected mutation       |
CONFIG MISMATCH        | H/M/L      | env var wrong/missing     |
INTEGRATION DRIFT      | H/M/L      | external API changed      |
TYPE MISMATCH          | H/M/L      | TS types ≠ runtime        |
HOOK ORDERING          | H/M/L      | lifecycle/effect order     |
AUTH BOUNDARY           | H/M/L      | permission/credential bug |
CONCURRENT EDIT        | H/M/L      | parallel agent conflict   |
COMPANY ISOLATION      | H/M/L      | cross-company data bleed  |
```

Only include rows with M or H likelihood. Skip patterns with no supporting evidence.

**Select top 3 patterns** by likelihood to form hypotheses.

## Step 4: Hypothesis Testing (3-Strike Rule)

Generate 3 hypotheses in priority order (highest likelihood first).

For each hypothesis:

```
### Hypothesis {N}: {precise statement}

**Pattern:** {classification from Step 3}
**Prediction:** If this is correct, then {observable consequence that can be tested}
**Test:** {specific read-only test — read a file, check a log, verify a value, trace a path}
```

Execute the test. Record the result:
- **CONFIRMED** — evidence supports this hypothesis as the root cause
- **REFUTED** — evidence contradicts this hypothesis
- **INCONCLUSIVE** — test didn't produce clear evidence either way

**3-Strike Rule:**

If ALL 3 hypotheses are refuted or inconclusive:

**STOP.** Do not generate Hypothesis 4 automatically. Instead:

1. Surface what you've learned from the failed hypotheses
2. Identify what information is still missing
3. Consider expanding the scope lock if evidence points elsewhere
4. AskUserQuestion to course-correct:
   - "All three hypotheses were ruled out. Here's what I've learned: {summary}. To proceed, I need: A) {specific info}. B) Expand scope to {new area}. C) {alternative approach}."

If a hypothesis is CONFIRMED, proceed to Step 5 immediately — do not test remaining hypotheses.

## Step 5: DEBUG REPORT

Write a structured report to `workspace/reports/{slug}-debug.md`:

```markdown
# DEBUG REPORT — {symptom summary}

**Date:** {ISO8601}
**Company:** {co}
**Scope lock:** {affected module/area}
**Investigation depth:** {N} hypotheses tested

## Root Cause

**Status:** CONFIRMED / SUSPECTED / UNKNOWN

{2-3 sentence description of what is happening and why}

## Evidence

| Evidence | Supports | Refutes |
|---|---|---|
| {observation} | Hypothesis {N} | — |
| {observation} | — | Hypothesis {M} |

## Pattern Classification

**Primary:** {RACE CONDITION / NIL PROPAGATION / etc.}
**Secondary:** {if applicable, otherwise omit}

## What Was Ruled Out

- **Hypothesis 1** ({pattern}): {refuted because}
- **Hypothesis 2** ({pattern}): {refuted because}

## Recommended Fix

{Only if root cause is CONFIRMED or strongly SUSPECTED}

**Minimal change:** {describe the smallest possible fix — one function, one file if possible}
**Files to touch:** {specific file paths — no others}
**Risk of fix:** LOW / MEDIUM — {does this fix have any side effects?}
**Regression test:** {what test would catch this if it regressed?}

## If Root Cause Unknown

{List remaining unknowns and what information would resolve them}
{Suggest next investigation steps}
```

## Step 6: Fix Gate

**If root cause is CONFIRMED:**

Present the recommended fix from the DEBUG REPORT. AskUserQuestion:
- **A) Apply fix now** — Apply ONLY the minimal targeted fix described in the report. No scope creep. No "while we're here" improvements. Fix the bug, add a regression test if feasible, done.
- **B) I'll apply manually** — User takes it from here. Investigation complete.
- **C) Need more investigation** — Something doesn't add up. Return to Step 4 with expanded scope.

If A: apply the fix, then verify it resolves the symptom. After verification, suggest `/learn` to capture the pattern as a policy.

**If root cause is SUSPECTED (not confirmed):**

AskUserQuestion:
- **A) Proceed with fix under uncertainty** — Apply the fix, but flag it as speculative in the commit message
- **B) Gather more evidence first** — Return to Step 2 with targeted questions

**If root cause is UNKNOWN:**

Output remaining unknowns from the DEBUG REPORT. Do NOT suggest guessing or trying random fixes. Investigation is complete — the honest answer is "I don't know yet."

---

## Rules

- **Iron Law above all** — never edit code before completing Steps 1-4. No exceptions
- **Read before write** — Steps 1-4 are entirely read-only. No file modifications until Step 6
- **Scope lock is sacred** — do not edit files outside the declared scope without explicitly expanding it
- **3-strike discipline** — if 3 hypotheses fail, stop and ask. Do not spiral
- **Minimal fix** — when applying a fix, change the minimum code necessary. No refactoring, no cleanup, no "improvements"
- **Company isolation** — respect all manifest boundaries. Never search or read cross-company data for debugging
- **Report always written** — even if the root cause is UNKNOWN, write the DEBUG REPORT. Investigation history has value
- **Do NOT create task lists or enter planning mode** — this command is a focused investigation, not a project
- **No Linear sync** — investigation is pre-task. Linear happens when fixes become stories
