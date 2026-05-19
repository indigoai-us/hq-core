---
id: hq-learn-auto-no-confirmation
title: /learn runs automatically and silently — never ask the user for permission to capture a learning
scope: global
trigger: A reusable rule, correction, or insight is identified at end-of-turn, during /checkpoint, /handoff, /retro, /execute-task, /run-project, or any point a learning would normally be captured
enforcement: hard
public: true
version: 1
created: 2026-05-18
updated: 2026-05-18
source: user-correction
tags: [knowledge, workflow]
---

## Rule

When a reusable learning is identified, invoke `/learn` (or the learn pipeline) **directly and silently**. Do NOT surface an `AskUserQuestion`, decision-queue item, or any other confirmation asking the user whether to capture, persist, or promote the learning, and do NOT add a "persist learning?" / "capture this as a policy?" item to end-of-turn suggestions.

Specifically:

- Never emit a "Persist learning" / "Capture this as a hard policy via /learn --hard?" style prompt.
- Run `/learn` automatically as a non-interactive step. The learn pipeline's own dedup (Step 4), scope classification (Step 3), and enforcement mapping (`source: user-correction` -> hard; `severity: critical` -> hard; else soft) are sufficient — no human gate is required.
- Apply the standard quiet-by-default narration: do not narrate the capture. A single terse line in the end-of-turn summary (e.g. "Learning captured: <slug>") is the maximum surface.
- This overrides any emergent inclination to "check before persisting." Capturing a learning is a routine, reversible, auto-deduped operation — it is explicitly NOT in the irreversible/destructive class that warrants confirmation.

The only exception: if a learning would contradict an existing hard-enforcement policy (the merge-conflict branch in learn Step 4.5), flag that single conflict for user review — but still without a generic "do you want to learn this?" prompt.

## Rationale

The learn pipeline is already safe: it deduplicates via qmd, scopes to the most specific policy directory, maps enforcement deterministically, and only ever appends (never overwrites). A confirmation prompt before every capture adds pure friction with no safety benefit — users routinely reject it. HQ's quiet-by-default principle already states that routine, reversible operations should not be narrated or gated; learning capture is exactly that class of operation.
