---
id: model-routing-opus-only
title: All Claude work runs on Opus — no Sonnet, no exceptions
scope: cross-cutting
trigger: Agent tool, sub-agent spawning, worker execution, /run, /execute-task
enforcement: hard
tier: 1
version: 2
created: 2026-03-28
updated: 2026-03-30
source: session-learning
public: true
---

## Rule

**All Claude work runs on Opus 4.6. Never use Sonnet.**

HQ's value comes from orchestration fidelity — policies, manifest routing, company isolation, hook compliance, knowledge management. Every layer of this system benefits from maximum model quality. There is no task category where downgrading Claude's model is acceptable.

### Model Tiers

| Model | Scope | Examples |
|-------|-------|---------|
| **Opus 4.6** | All Claude work — sessions, sub-agents, workers | Architecture, planning, code review, debugging, orchestration, search, execution, drafting, testing |
| **Codex GPT-5.4** | Code gen, review, debug via Codex CLI | `codex exec`, `codex review` — independent second opinion |
| **Gemini** | Gemini CLI workers | Design audit, frontend, CSS, UX — via `gemini` CLI |

### Implementation

- `CLAUDE_CODE_SUBAGENT_MODEL=opus` — never change this
- All worker YAMLs: `execution.model: opus` (default, no need to specify)
- Never pass `model: "sonnet"` on Agent tool calls
- Codex workers use `codex_model: gpt-5.4` with `--reasoning high --fast`
- Gemini workers shell out to `gemini` CLI — separate model entirely

### What About Cost?

Opus costs more than Sonnet. This is intentional. The failure modes of a cheaper model in HQ (skipped policy steps, wrong company credentials, missed orchestration rules) cost more in wasted time and broken state than the token savings. Pay for quality everywhere.

## Rationale

Session 2026-03-28: Initially proposed Sonnet for "scoped executors" (Explore agents, E2E tests, creative drafts, small sub-agents). User correction: HQ orchestration fidelity is the core value — every agent navigates the same policy/manifest system. Downgrading any agent risks skipped steps in complex protocols. The only non-Opus models are external (Codex, Gemini) which run in their own CLIs with their own runtimes.
