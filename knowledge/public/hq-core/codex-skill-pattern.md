# Codex Skill Pattern

How to promote an HQ command to Codex so it appears in Codex sessions.

## Overview

HQ uses a **dual-format approach**: `command.md` is the Claude Code source of truth; `SKILL.md` is the Codex-adapted derivative. Both live in `.claude/skills/{name}/`. The filesystem bridge (`scripts/codex-skill-bridge.sh install`) symlinks `.claude/skills/` into `~/.codex/skills/hq`, so all skills are auto-discovered by Codex without duplication.

## Codex-Ready Skill Structure

```
.claude/skills/{name}/
  SKILL.md              # Codex-adapted instructions
  agents/
    openai.yaml         # Required for Codex UI discovery
```

### SKILL.md frontmatter (required fields)

```yaml
---
name: skill-name
description: One-line description shown in Codex UI
---
```

### agents/openai.yaml (required fields)

```yaml
display_name: Human-readable Name
short_description: One sentence description for Codex UI
```

## Adaptation Rules

When writing a new SKILL.md from a Claude Code command:

| Claude Code pattern | Codex adaptation |
|--------------------|------------------|
| `Task` tool (sub-agents) | Use Codex sub-agents when available; otherwise fall back to explicit inline phases |
| `EnterPlanMode` / `ExitPlanMode` | Plan inline in conversation, no mode switching |
| `TodoWrite` / `TodoRead` | Track state in context and persist durable state to project/session memory files |
| `qmd` via MCP | `qmd` CLI via shell (`qmd search/vsearch/query "..." --json`) |
| Hook-triggered side effects | Document as manual step; hooks don't run in Codex |

**Anti-instruction rule:** Avoid "Do NOT use X" phrasing — in Codex these read as instructions to DO X. Rephrase to describe what to do instead.

## 12 Promoted Skills (as of 2026-04-03)

| Skill | Category |
|-------|----------|
| `review` | Code review |
| `investigate` | Debugging |
| `retro` | Retrospective |
| `startwork` | Session bookend |
| `handoff` | Session bookend |
| `brainstorm` | Planning |
| `prd` | Planning |
| `search` | Knowledge |
| `learn` | Knowledge |
| `run` | Worker execution |
| `execute-task` | Task execution |
| `run-project` | Project orchestration |

## Orchestration Skills (delegated model)

`run`, `execute-task`, and `run-project` use a **delegated execution model** in Codex when the runtime exposes sub-agents. The parent session owns orchestration, state, user communication, final integration, and verification. Sub-agents own bounded research, implementation, review, QA, or recovery tasks.

Why this is the default:

- Fresh context per bounded unit keeps the parent session small.
- Worker-specific instructions and knowledge stay isolated from unrelated work.
- Parallel read-only exploration can happen while the parent handles the critical path.
- Filesystem memory becomes the source of continuity instead of chat history.

Fallback rule: if sub-agents are unavailable in a specific Codex runtime, run the same phases inline and write memory files after each phase.

## Filesystem Memory Contract

Every delegated Codex workflow should create or update durable memory under `workspace/orchestrator/{project}/` or `workspace/threads/`:

| File | Purpose |
|------|---------|
| `codex-session-plan.md` | Parent-owned plan, story order, quality gates, applicable policies |
| `memory/session.md` | Human-readable running summary of decisions, constraints, and current status |
| `memory/agents/{phase}-{worker}.json` | Sub-agent return payload, changed files, back-pressure result, context for next phase |
| `executions/{story-id}.json` | Machine-readable phase state and handoffs |
| `handoff.json` / thread file | Cross-session resume state |

Parent sessions should read these memory files before asking the user to repeat context. Sub-agents should receive only the memory files and source files needed for their bounded task.

## Model Routing

Use the cheapest capable model for each bounded subtask:

| Work type | Preferred Codex model |
|-----------|-----------------------|
| Read-only exploration, file mapping, summarization, simple QA notes | `gpt-5.3-codex-spark` |
| Focused code edits in a known module | Inherit parent model unless a real Codex model id is specified |
| Cross-module design, risky migrations, security-sensitive changes | Inherit parent model or use an explicit high-reasoning Codex override |
| Codex CLI worker commands | `worker.execution.codex_model`, with story `codex_model_hint` override |

Spark 5.3 is especially useful for sidecar explorers because the output should be compact and written to filesystem memory, not kept in the parent conversation.

Context budget guidance for `run-project`:

| Stories | Risk | Recommendation |
|---------|------|---------------|
| 1–3 | Low | Parent orchestrates, delegate specialized phases |
| 4–5 | Medium | Delegate per story and write memory after each phase |
| 6–8 | High | Mandatory story-level handoff/checkpoint memory |
| 9+ | Critical | Use Ralph/headless mode with Codex engine and filesystem state |

## Coverage Tool

```bash
bash scripts/codex-skill-bridge.sh status
```

Shows:
- Total skills / skills with `agents/openai.yaml`
- Commands without corresponding skills (coverage gaps)
- Bridge symlink health for all targets

Run after adding new skills or commands to identify gaps.

## Adding a New Promoted Skill

1. Create `.claude/skills/{name}/SKILL.md` with adapted instructions
2. Create `.claude/skills/{name}/agents/openai.yaml` with `display_name` + `short_description`
3. Run `bash scripts/codex-skill-bridge.sh status` to verify Codex-ready count increases
4. Update the "12 promoted skills" list in CLAUDE.md

## Related Files

- `.claude/skills/` — all skills
- `scripts/codex-skill-bridge.sh` — bridge install + status + coverage report
- `.claude/CLAUDE.md` → `## Skills` — integration rules
- `projects/codex-command-discovery/prd.json` — origin project
