---
name: decision-queue
description: Walk through pending decisions one at a time, updating state between answers.
allowed-tools: Read, Write, Edit, Bash
---

# Decision Queue

Codex adapter for `/decision-queue`.

**Arguments:** `[free-text decision list or path to a queue file]`

## Source Of Truth

Read `.claude/commands/decision-queue.md` first. That command owns the sequencing rule, option shape, and persistence expectations.

## Codex Adaptation

- Present one decision at a time in conversation.
- Use Codex structured user input when available; otherwise ask one concise plain-text question and wait.
- Do not batch unrelated decisions into a single user prompt.
- After each answer, update the relevant working state if a plan, PRD, brainstorm, or queue file exists; otherwise state the resolution in the conversation.
- Recompute the remaining queue when an answer makes later questions irrelevant.

## Completion

End with the resolved decisions and the next concrete action. If there is only one decision, ask it directly instead of invoking a queue.
