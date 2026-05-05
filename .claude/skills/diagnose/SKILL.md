---
name: diagnose
description: |
  Disciplined diagnosis loop for hard bugs, performance regressions, and intermittent failures.
  Build a deterministic feedback loop FIRST, then reproduce → hypothesise (3-5 ranked) → instrument (one variable at a time, tagged probes) → fix at the correct seam → cleanup + post-mortem.
  Use when the dominant problem is "I cannot reliably reproduce or measure this." For bugs that reproduce reliably with unknown root cause, use /investigate instead.
allowed-tools: Read, Grep, Glob, Write, Edit, Bash, Agent, AskUserQuestion
---

# Diagnose

A discipline for hard bugs. Skip phases only when explicitly justified, and only with the user's consent. Pattern adapted from `mattpocock/skills` (`repos/public/skills/skills/engineering/diagnose/SKILL.md`); HQ-specific cross-references and report shape added.

## When `/diagnose` vs `/investigate`

| Trigger | Skill |
|---|---|
| Bug reproduces reliably; root cause unknown | **`/investigate`** (Iron Law: no fix before root cause) |
| Bug is intermittent / flaky / env-specific / "sometimes wrong" | **`/diagnose`** (this) |
| Performance regression with no signal | **`/diagnose`** |
| Tests pass locally, fail in CI | **`/diagnose`** (loop must run in failing env) |
| Code is fine, design is the problem | **`/architect`** |

If `/diagnose` produces a clean repro and the cause is still unknown, hand off to `/investigate`.

## Step 0 — Resolve company context

Same pattern as `/investigate` and `/brainstorm`:

1. Honour explicit `[company]` argument
2. Fall back to `workspace/threads/handoff.json` `.company`
3. Fall back to cwd inference via `companies/manifest.yaml`
4. Last resort: ask via `AskUserQuestion`

Load CONTEXT-style domain glossary if the target repo has one (`<repo>/CONTEXT.md`). Check ADRs in the area being touched (`<repo>/docs/adr/`).

## Phase 1 — Build a feedback loop

**This is the skill.** Everything else is mechanical. With a fast, deterministic, agent-runnable pass/fail signal, bisection / hypothesis-testing / instrumentation all just consume that signal. Without one, no amount of staring at code will save you.

Spend disproportionate effort here. **Be aggressive. Be creative. Refuse to give up.**

### 10 ways to construct one — try in roughly this order

| # | Strategy | When it works |
|---|---|---|
| 1 | **Failing test** at whatever seam reaches the bug — unit, integration, e2e | Bug is in code you control with existing test infra |
| 2 | **Curl / HTTP script** against a running dev server | Bug is in an HTTP path |
| 3 | **CLI invocation** with fixture input, diffing stdout vs known-good snapshot | Bug is in a CLI / script |
| 4 | **Headless browser** (Playwright / Puppeteer) — drives UI, asserts on DOM/console/network | Bug is in browser behavior |
| 5 | **Replay a captured trace** — save a real network req / payload / event log to disk; replay through the code path in isolation | Bug requires production-shaped data |
| 6 | **Throwaway harness** — minimal subset of system (one service, mocked deps) exercising the bug code path with a single function call | Bug requires multiple services to manifest |
| 7 | **Property / fuzz loop** — run 1000 random inputs; look for the failure mode | Bug is "sometimes wrong output" |
| 8 | **Bisection harness** — automate "boot at state X, check, repeat" so `git bisect run` works | Bug appeared between two known states |
| 9 | **Differential loop** — same input through old-version vs new-version (or two configs); diff outputs | Bug is a regression with a known-good state |
| 10 | **HITL bash script** — last resort. If a human must click, drive them with a structured loop script so output still feeds back to you | All else fails |

Build the right loop, the bug is 90% fixed.

### Iterate on the loop itself

Treat the loop as a product. Once you have *a* loop, ask:

- Faster? (Cache setup, skip unrelated init, narrow test scope)
- Sharper signal? (Assert on the specific symptom, not "didn't crash")
- More deterministic? (Pin time, seed RNG, isolate filesystem, freeze network)

A 30-second flaky loop is barely better than no loop. A 2-second deterministic loop is a debugging superpower.

### Non-deterministic bugs

Goal is not a clean repro but a **higher reproduction rate**. Loop the trigger 100×, parallelise, add stress, narrow timing windows, inject sleeps. A 50%-flake bug is debuggable; 1% is not — keep raising the rate until it's debuggable.

### When you genuinely cannot build a loop

Stop and say so explicitly. List what you tried. Ask the user via `AskUserQuestion` for one of:

- Access to whatever environment reproduces it
- A captured artifact (HAR file, log dump, core dump, screen recording with timestamps)
- Permission to add temporary production instrumentation

Do **not** proceed to hypothesise without a loop.

Do not proceed to Phase 2 until you have a loop you believe in.

## Phase 2 — Reproduce

Run the loop. Watch the bug appear.

Confirm via checklist:

- [ ] Loop produces the failure mode the **user** described — not a different failure that happens to be nearby. Wrong bug = wrong fix.
- [ ] Failure is reproducible across multiple runs (or, for non-deterministic bugs, at a high enough rate to debug against).
- [ ] You have captured the exact symptom (error message, wrong output, timing) so later phases can verify the fix actually addresses it.

Do not proceed until you reproduce the bug.

## Phase 3 — Hypothesise

Generate **3–5 ranked, falsifiable hypotheses** before testing any. Single-hypothesis generation anchors on the first plausible idea.

Each hypothesis must be falsifiable. Required format:

> "If <X> is the cause, then <changing Y> will make the bug disappear / <changing Z> will make it worse."

If you cannot state the prediction, the hypothesis is a vibe — discard or sharpen it.

**Show the ranked list to the user before testing** via `AskUserQuestion` (multiSelect: true to let them flag which they want skipped or pre-empted). Domain knowledge often re-ranks instantly ("we just deployed a change to #3"), or the user has already ruled some out. Cheap checkpoint, big time saver. Don't block on it — proceed with your ranking if the user is AFK.

## Phase 4 — Instrument

Each probe must map to a specific prediction from Phase 3. **Change one variable at a time.**

Tool preference order:

1. **Debugger / REPL inspection** if env supports it. One breakpoint beats ten logs.
2. **Targeted logs** at boundaries that distinguish hypotheses.
3. Never "log everything and grep".

**Tag every debug log** with a unique prefix, e.g. `[DEBUG-a4f2]`. Cleanup at end becomes a single grep. Untagged logs survive past cleanup; tagged logs die.

**Performance branch.** For perf regressions, logs are usually wrong. Establish a baseline measurement (timing harness, `performance.now()`, profiler, query plan), then bisect. Measure first, fix second.

## Phase 5 — Fix + regression test

Write the regression test **before the fix** — but only if there is a **correct seam** for it.

A correct seam exercises the **real bug pattern** as it occurs at the call site. If the only available seam is too shallow (single-caller test when the bug needs multiple callers; unit test that can't replicate the chain that triggered it), a regression test there gives false confidence.

**If no correct seam exists, that itself is the finding.** Note it. The codebase architecture is preventing the bug from being locked down. Flag this for Phase 6 hand-off to `/architect`.

If a correct seam exists:

1. Turn the minimised repro into a failing test at that seam.
2. Watch it fail.
3. Apply the fix.
4. Watch it pass.
5. Re-run the Phase 1 feedback loop against the original (un-minimised) scenario.

This is HQ Core Principle #8 ("Bugfixes require tests") — non-negotiable.

## Phase 6 — Cleanup + post-mortem

Required before declaring done:

- [ ] Original repro no longer reproduces (re-run Phase 1 loop)
- [ ] Regression test passes (or absence of seam is documented + flagged)
- [ ] All `[DEBUG-…]` instrumentation removed (`grep` the prefix; `git diff` clean of tagged probes)
- [ ] Throwaway prototypes deleted (or moved to a clearly-marked debug location)
- [ ] The hypothesis that turned out correct is stated in the commit / PR message — so the next debugger learns

**Then ask: what would have prevented this bug?** If the answer involves architectural change (no good test seam, tangled callers, hidden coupling) hand off to `/architect` with the specifics. Make the recommendation **after** the fix is in, not before — you have more information now than when you started.

## Output: diagnostic report

Save to `workspace/reports/{slug}-diagnose.md`. Sections:

```markdown
# Diagnose: <title>

**Symptom:** <user-described>
**Repro rate before:** <X%> | **after loop:** <Y%>
**Loop strategy used:** <#1–10>
**Loop file path:** <path>
**Time-to-loop:** <minutes>

## Hypotheses (ranked)
1. ✅/❌ <hypothesis> — prediction: <Y>; result: <observed>
2. …

## Winning hypothesis
<one paragraph>

## Fix
<file:line refs>

## Regression test
<file:line> — or "no correct seam; flagged for /architect"

## Post-mortem
- What would have prevented this:
- Architectural smells noted:
- /architect handoff: yes/no
```

## Cross-references

- HQ `/investigate` — root-cause-first companion. Use when bug reproduces reliably.
- HQ `/tdd` — Phase 5 regression test feeds into full red-green-refactor coverage.
- HQ `/architect` — Phase 6 hand-off when the absent test seam or tangled callers is the real story.
- HQ Core Principles 7 (never skip failing tests) and 8 (bugfixes require tests).
- HQ `/learn` — capture failure-mode patterns at end of session for cross-tenant reuse.
- Pattern source: `mattpocock/skills` (`repos/public/skills/skills/engineering/diagnose/SKILL.md`)
