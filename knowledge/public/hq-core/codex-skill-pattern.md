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
| `Task` tool (sub-agents) | Inline execution phases — describe sequentially, no spawning |
| `EnterPlanMode` / `ExitPlanMode` | Plan inline in conversation, no mode switching |
| `TodoWrite` / `TodoRead` | Track state in context; write checkpoint JSON if needed |
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

## Orchestration Skills (inline model)

`run`, `execute-task`, and `run-project` use an **inline execution model** — no sub-agent isolation. The Codex agent runs all phases sequentially in a single session. Tradeoff: no context isolation between phases; context budget matters for large projects.

Context budget guidance for `run-project`:

| Stories | Risk | Recommendation |
|---------|------|---------------|
| 1–3 | Low | Safe inline |
| 4–5 | Medium | Checkpoint between stories |
| 6–8 | High | Mandatory handoff between stories |
| 9+ | Critical | Use Claude Code instead |

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
