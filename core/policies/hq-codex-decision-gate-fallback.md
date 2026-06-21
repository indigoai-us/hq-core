---
id: hq-codex-decision-gate-fallback
title: Codex planning skills must preserve decision gates with a text fallback
scope: global
trigger: Codex skill adaptation; brainstorm/prd/review-plan/run-project user question or decision gate; AskUserQuestion unavailable; request_user_input available
when: /brainstorm || /prd || /review-plan || /run-project
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
version: 2
created: 2026-05-01
updated: 2026-05-12
source: user-correction
public: false
skip-promotion: true
---

## Rule

When a Claude-origin HQ command or skill requires a user question or decision through `AskUserQuestion`, the Codex adaptation must preserve the gate even if Codex cannot call that exact primitive.

Codex adaptation order:

1. Use Codex `request_user_input` when it is actually callable in the current runtime and the question can be expressed as 2-3 selectable choices. Present exactly one question per call.
2. If Codex `request_user_input` is not callable, use any other structured interactive question tool that is actually callable in the current runtime, still exactly one question per call.
3. If no structured question tool is callable, ask a concise plain-text question with the same options and wait for the user's answer.
4. Never replace a required gate with a passive summary like "Next: promote to PRD, edit, or park" and then end the turn.

This preference applies to all user-facing HQ questions with enumerated choices, not only formal lifecycle gates. Free-form discovery questions may remain plain text when forcing them into choices would lose useful information.

This especially applies to artifact lifecycle gates:

- After `/brainstorm`: ask whether to promote to PRD, refine, park, or end.
- During `/prd` open-question resolution: ask, defer as a pre-flight story, or explicitly record the user chose to leave it unresolved.
- During `/review-plan`: ask for the selected response to each blocking issue.
- During `/run-project`: ask before changing execution semantics between interactive/session/headless modes.

## Rationale

Claude HQ workflows rely on `AskUserQuestion` as a real queue of decisions. Codex sessions do not always expose that same primitive, and some Codex-facing skills were forked by deleting the interactive gate instead of adapting it. That silently drops important workflow state: brainstorms do not get promoted, PRDs keep unresolved questions, and run-project mode choices become implicit.

The invariant is not "always use AskUserQuestion"; the invariant is "required decisions must be surfaced and answered." A plain-text fallback is less ergonomic, but it preserves the lifecycle.
