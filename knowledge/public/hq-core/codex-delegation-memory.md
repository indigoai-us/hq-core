---
type: reference
domain: [engineering, operations]
status: canonical
tags: [codex, sub-agents, context-management, filesystem-memory]
relates_to:
  - codex-skill-pattern.md
  - thread-schema.md
---

# Codex Delegation and Filesystem Memory

HQ Codex sessions should treat context as a scarce orchestration layer, not as the primary storage layer. The parent Codex agent keeps the user loop, makes integration decisions, and verifies outcomes. Sub-agents do bounded work in fresh contexts. Filesystem memory carries continuity between them.

## Default Shape

1. Parent resolves company, repo, project, policies, and active work.
2. Parent writes a durable plan to `workspace/orchestrator/{project}/codex-session-plan.md`.
3. Parent delegates bounded sidecar tasks whenever they can run independently.
4. Each sub-agent writes or returns a compact JSON handoff.
5. Parent stores handoffs under `workspace/orchestrator/{project}/memory/agents/`.
6. Parent integrates, runs back-pressure checks, commits, and updates `prd.json` or state files.

Sub-agents should never become the hidden source of truth. If a result matters, it belongs in a memory file, a commit, a test, or a PRD/state update.

## Memory Layout

```text
workspace/orchestrator/{project}/
  codex-session-plan.md
  state.json
  executions/
    {story-id}.json
  memory/
    session.md
    decisions.md
    blockers.md
    agents/
      01-explorer.json
      02-backend-dev.json
      03-reviewer.json
```

Use `session.md` for concise human continuity. Use `executions/*.json` and `memory/agents/*.json` for machine-readable handoffs.

## Sub-Agent Return Contract

Every delegated task should return compact JSON:

```json
{
  "status": "passed",
  "summary": "One or two sentences.",
  "files_read": [],
  "files_changed": [],
  "decisions": [],
  "risks": [],
  "back_pressure": {
    "tests": "not_run",
    "lint": "not_run",
    "typecheck": "not_run",
    "build": "not_run"
  },
  "context_for_next": "Only what the next worker needs."
}
```

For read-only agents, `files_changed` must be empty. For worker agents, changed files must be disjoint from other active worker ownership unless the parent explicitly coordinates a merge point.

## Model Defaults

- Use `gpt-5.3-codex-spark` for bounded read-only exploration, summaries, simple review passes, test-output triage, and other low-risk sidecars.
- Use the worker's configured model for implementation.
- Use the parent model for tightly coupled architecture, final integration, and high-stakes decisions.

The goal is not to maximize agent count. The goal is to keep each context small, useful, and recoverable.
