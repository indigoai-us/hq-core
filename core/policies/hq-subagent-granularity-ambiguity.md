---
id: hq-subagent-granularity-ambiguity
title: "Already uses sub-agents" is ambiguous — verify granularity when evaluating context preservation
scope: global
trigger: When analyzing whether an orchestrator preserves parent context, or when a user asks "does this already use sub-agents?" before redesigning an agent pipeline
when: subagent || subagents || sub-agent || sub-agents
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
public: true
version: 1
created: 2026-04-16
updated: 2026-04-16
source: session-learning
---

## Rule

ALWAYS: Treat "already uses sub-agents" as ambiguous when evaluating context-preservation. Before concluding that an orchestrator preserves parent context, verify the delegation granularity (per-worker vs per-story vs per-phase vs per-project) AND identify what orchestrator work still runs in the parent. Context burn lives in the loop that surveys results and decides what's next — task classification, worker selection, quality-gate output parsing, commit verification, inter-unit summaries — not just in worker execution. An orchestrator can spawn a dozen sub-agents per story and still blow out parent context if the loop that coordinates them stays in the parent session.

## Rationale

`/run-project --inline` was described as "already uses sub-agents per worker" — technically true, but misleading for the question being asked (how to preserve parent context across multi-story runs). The per-worker sub-agents were isolating worker execution, but the parent session was still running the outer loop: reading PRD, classifying task type, selecting worker sequence, printing per-worker progress, interpreting back-pressure results, verifying commits, rendering summaries for the user-gate. Each of those steps adds tokens; across 5–8 stories it reliably crosses the 60% context advisory.

The diagnostic question is not "are there sub-agents?" but "what orchestrator work survives the sub-agent boundary?" If the answer includes task selection, result interpretation, or cross-unit coordination, the parent is still context-bound by those activities. Raising the sub-agent boundary one level — so the sub-agent itself does the coordination for its unit of work — pushes that loop into the fresh context window. For Ralph-style orchestrators, the right boundary is typically the user-review unit (story, task, PR) rather than the phase-within-unit (worker, step, gate).
