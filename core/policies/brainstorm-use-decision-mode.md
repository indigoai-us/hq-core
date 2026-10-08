---
id: brainstorm-use-decision-mode
title: /brainstorm must use AskUserQuestion + company project path
scope: command
trigger: during /brainstorm execution
when: command
on: [PreToolUse, PostToolUse, UserPromptSubmit, AssistantIntent]
enforcement: hard
public: true
version: 4
created: 2026-04-19
updated: 2026-10-07
tags: [command, knowledge]
---

## Rule

`/brainstorm` MUST: (1) use `AskUserQuestion` for every user choice (no markdown numbered lists — they're not clickable); (2) when a user is attending the session, run the decision interview through the grilling engine with `.claude/skills/_shared/questions/brainstorm.md`, one question per call, rather than applying an autonomous-mode shortcut; (3) write to `companies/{co}/projects/{slug}/brainstorm.md` (or `projects/{slug}/brainstorm.md` for personal/HQ) with `mkdir -p` first; (4) refuse to run inside Plan Mode — print preflight and abort, no silent degrade; (5) end with one `AskUserQuestion` plan gate with exactly three options: `Plan it now`, `Upgrade to deep-plan`, `Stop here`.

Phases A through C never write prd.json; only the plan phase does, after the gate answers `Plan it now`. The plan phase runs the PRD question set through the grilling engine with the brainstorm answers loaded as known facts, then the shared prd-finalize steps. `Stop here` leaves the board status at `brainstormed` and writes no prd.json.

The autonomous shortcut is only for expressly unattended/headless work. In an attended session, do not treat prior context or plausible assumptions as a substitute for the Q&A: ask each unresolved decision sequentially under `decision-queue-one-at-a-time` and record the answers before finalizing the brainstorm.

**Plan-Mode fallback:** during Plan Mode, write brainstorm content into the plan artifact itself (the only writable target); after `ExitPlanMode` is approved, create the canonical `brainstorm.md` and add the entry to `companies/{co}/board.json` so `/prd` and `/strategize` see it.

## Rationale

Two observed failure modes motivated this policy:

- **Text-only questions waste the interactive harness.** The brainstorm skill's frontmatter already allows `AskUserQuestion`, but the SKILL.md body did not prescribe it, so the model fell back to a numbered markdown list. Users had to re-type their choice instead of clicking.
- **Plan Mode hijacks the output path.** When `/brainstorm` runs inside Plan Mode, the only writable target is a plan file under `~/.claude/plans/`. Without an explicit guard, `brainstorm.md` contents landed there instead of in the company project dir, orphaning the brainstorm from the PRD promotion flow.

Version 3 added the attended-session boundary after an owner interview corrected several seemingly safe assumptions that autonomous guidance would have skipped.

Version 4 replaces the end-of-brainstorm next-step menu with the three-option plan gate, so a user can reach prd.json in the same session without re-answering questions.

## Examples

**Correct:**
- Step 3 asks the brainstorm question set one `AskUserQuestion` at a time, each with 2–4 labeled options.
- Step 7 summary followed by one `AskUserQuestion` with options `Plan it now`, `Upgrade to deep-plan`, `Stop here`.
- Output at `companies/{co}/projects/{slug}/brainstorm.md` after `mkdir -p` on the parent dir.

**Incorrect:**
- "How would you like to proceed?" followed by a 1./2./3./4. markdown list.
- Writing prd.json before the gate, or after the gate answers `Stop here`.
- Writing `brainstorm.md` contents into a plan file at `~/.claude/plans/*.md`.
- Skipping `mkdir -p` and letting Write fail silently against a nonexistent project dir.

## Operator Fallback (Plan Mode)

When `/brainstorm` refuses in Plan Mode (rule #4), the operator can still make progress by following this two-phase workflow:

1. **During Plan Mode:** write the brainstorm content (background, options, recommendation, unresolved questions) into the plan artifact itself. Plan Mode's only writable target is the plan file, so treat it as scratch.
2. **After `ExitPlanMode` is approved:** create the canonical `companies/{co}/projects/{slug}/brainstorm.md` from the plan content, run `mkdir -p` first, and add a corresponding entry to `companies/{co}/board.json` so the brainstorm is discoverable by `/prd` and `/strategize`.

This preserves the Plan Mode guard (rule #4 still applies — the skill itself never writes outside the plan) while giving the operator a sanctioned path to land the brainstorm in the right place afterwards.
