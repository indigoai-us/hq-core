---
name: to-tickets
description: |
  Break a plan, spec, or conversation into tracer-bullet vertical-slice tickets, each declaring its blocking edges (dependency order).
  Use when you have a plan/spec/PRD and need it decomposed into independently-executable tickets. Triggers on "break into tickets", "slice this into tasks", "vertical slices", "tracer bullets".
allowed-tools: Read, Write, Edit, Grep, Glob, Bash(gh:*), AskUserQuestion
---

# To Tickets

Break a plan, spec, or conversation into a set of **tickets** — tracer-bullet vertical slices, each declaring the tickets that **block** it (the dependency order to execute them in).

This is distinct from `/prd`. `/prd` emits a single `prd.json` PRD artifact (source of truth consumed by `/run-project` and `/execute-task`). `/to-tickets` emits a set of **dependency-ordered tickets** — each an independently-executable, demoable vertical slice with explicit blocking edges — written as one markdown file per ticket under `workspace/`, or as GitHub issues when the company works on GitHub. Reach for `/to-tickets` when you already have a plan (from a conversation, a spec, or an existing `prd.json`) and want it sliced into a graph of grab-and-go tickets rather than a formal PRD document.

Pattern adapted from [mattpocock/skills](https://github.com/mattpocock/skills) (skills/engineering/to-tickets), upstream commit 391a270; tracker-agnostic (workspace/ markdown default), HQ company-context and cross-references added.

## Step 0 — Resolve company context

Same pattern as `/diagnose`, `/investigate`, and `/brainstorm`:

1. Honour explicit `[company]` argument
2. Fall back to `workspace/threads/handoff.json` `.company`
3. Fall back to cwd inference via `companies/manifest.yaml`
4. Last resort: ask via `AskUserQuestion`

Load the CONTEXT-style domain glossary if the target repo has one (`<repo>/CONTEXT.md`). Check ADRs in the area being touched (`<repo>/docs/adr/`). Ticket titles and descriptions should use the project's domain glossary vocabulary and respect those ADRs.

## Process

### 1. Gather context

Work from whatever is already in the conversation context. If the user passes a reference (a spec path, a `prd.json`, an issue number or URL) as an argument, fetch it and read its full body and comments. If the source is a `prd.json`, treat its user stories as raw material to re-slice into tracer bullets — do not just copy them over one-to-one.

### 2. Explore the codebase (optional)

If you have not already explored the codebase, do so to understand the current state of the code. Ticket titles and descriptions should use the project's domain glossary vocabulary, and respect ADRs in the area you're touching.

Look for opportunities to prefactor the code to make the implementation easier. "Make the change easy, then make the easy change."

### 3. Draft vertical slices

Break the work into **tracer bullet** tickets.

<vertical-slice-rules>

- Each slice cuts a narrow but COMPLETE path through every layer (schema, API, UI, tests) — vertical, NOT a horizontal slice of one layer
- A completed slice is demoable or verifiable on its own
- Each slice is sized to fit in a single fresh context window
- Any prefactoring should be done first

</vertical-slice-rules>

Give each ticket its **blocking edges** — the other tickets that must complete before it can start. A ticket with no blockers can start immediately.

**Wide refactors are the exception to vertical slicing.** A **wide refactor** is one mechanical change — rename a column, retype a shared symbol — whose **blast radius** fans across the whole codebase, so a single edit breaks thousands of call sites at once and no vertical slice can land green. Don't force it into a tracer bullet; sequence it as **expand–contract**. First expand: add the new form beside the old so nothing breaks. Then migrate the call sites over in batches sized by blast radius (per package, per directory), each batch its own ticket blocked by the expand, keeping CI green batch to batch because the old form still exists. Finally contract: delete the old form once no caller remains, in a ticket blocked by every migrate batch. When even the batches can't stay green alone, keep the sequence but let them share an integration branch that all block a final integrate-and-verify ticket — green is promised only there.

### 4. Quiz the user

Present the proposed breakdown as a numbered list. For each ticket, show:

- **Title**: short descriptive name
- **Blocked by**: which other tickets (if any) must complete first
- **What it delivers**: the end-to-end behaviour this ticket makes work

Ask the user:

- Does the granularity feel right? (too coarse / too fine)
- Are the blocking edges correct — does each ticket only depend on tickets that genuinely gate it?
- Should any tickets be merged or split further?

Iterate until the user approves the breakdown.

### 5. Publish the tickets

Publish the approved tickets. The tickets are the same either way — only the shape of the blocking edges changes.

- **Default: workspace markdown** → write one file per ticket under `workspace/reports/tickets-<slug>/<NN>-<slug>.md`, numbered from `01` in dependency order (blockers first), where `<slug>` is the feature slug. Each file's "Blocked by" lists the numbers/titles it depends on. Use the per-ticket file template below — one ticket per file, never a single combined file.
- **Optional: GitHub issues** (when the company works on GitHub — check `companies/{co}/manifest.yaml` `repos[]`, or the user asks for issues) → publish one issue per ticket via `gh issue create -R <owner>/<repo>` in dependency order (blockers first) so each ticket's blocking edges can reference real issue numbers. Use the platform's native blocking / sub-issue relationship where it has one; otherwise set each ticket's "Blocked by" to the blocking issue references. Always anchor `gh` to an explicit `-R owner/repo`.

Work the **frontier**: any ticket whose blockers are all done. For a purely linear chain that means top to bottom.

Do NOT close or modify any parent issue.

<workspace-ticket-template>

# <NN> — <Ticket title>

**What to build:** the end-to-end behaviour this ticket makes work, from the user's perspective — not a layer-by-layer implementation list.

**Blocked by:** the numbers/titles of the tickets that gate this one, or "None — can start immediately".

- [ ] Acceptance criterion 1
- [ ] Acceptance criterion 2

</workspace-ticket-template>

<issue-template>

## Parent

A reference to the parent issue on the tracker (if the source was an existing issue, otherwise omit this section).

## What to build

The end-to-end behaviour this ticket makes work, from the user's perspective — not layer-by-layer implementation.

## Acceptance criteria

- [ ] Criterion 1
- [ ] Criterion 2

## Blocked by

- A reference to each blocking ticket, or "None — can start immediately".

</issue-template>

In either form, avoid specific file paths or code snippets — they go stale fast. Exception: if a prototype produced a snippet that encodes a decision more precisely than prose can (state machine, reducer, schema, type shape), inline it and note briefly that it came from a prototype. Trim to the decision-rich parts — not a working demo, just the important bits.

Work the frontier one ticket at a time with `/execute-task` (single story) or `/run-project` (multi-ticket orchestration), clearing context between tickets.

## Cross-references

- HQ `/prd` — when you need the formal `prd.json` PRD artifact instead of a dependency-ordered ticket set. `/to-tickets` can consume a `prd.json` as source and re-slice it into tracer bullets.
- HQ `/execute-task` — execute one approved ticket end-to-end in a fresh context. This is the frontier-clearing companion to `/to-tickets`.
- HQ `/run-project` — orchestrate execution across a multi-ticket set, respecting the blocking edges.
- HQ `/wayfinder` — orient on where in a plan/graph a piece of work sits before or after slicing.
- Pattern source: [mattpocock/skills](https://github.com/mattpocock/skills) (skills/engineering/to-tickets), upstream commit 391a270.
