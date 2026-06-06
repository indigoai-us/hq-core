---
name: model-context-window
when: always
on: [SessionStart]
description: Default Opus model uses 200K context; the [1m] (1M context) variant is opt-in per command, not the global default
enforcement: soft
applies_to: [hq, run-project, deep-plan, discover, diagnose]
vendor_public_ok: true
public: true
created: 2026-05-12
---

## Rule

The global default model in `.claude/settings.json` is `claude-opus-4-8` (200K context). The `[1m]` variant (`claude-opus-4-8[1m]`, 1M context) is **opt-in per command**, not the default.

Commands that opt into `[1m]`:

- `/discover` — codebase ingestion fans out parallel exploration; long context is load-bearing
- `/deep-plan` — multi-tier interview + research subagents accumulate spec material
- `/run-project` — long Ralph loops accumulate per-story summaries; opt-in only for long projects (>10 stories)
- `/diagnose` — instrumentation + repro cycles accumulate logs

How a command opts in (mechanism resolved by US-015):

1. Per-command frontmatter `model: claude-opus-4-8[1m]` if the runtime honors it, or
2. Slash-command runtime flag (e.g. `/run-project foo --model claude-opus-4-8[1m]`), or
3. Soft fallback: command's first step prompts the user to restart the session with `--model claude-opus-4-8[1m]` if long context is needed; otherwise proceeds with 200K.

## Rationale

A 1M-context default delays autocompact: at the 60% threshold, the prefix is ~600K tokens, dominated by raw tool-results and stale system reminders. On long sessions this produced `cache_read` totals as high as 468M tokens (session 75aa571a, May 2026), which contributed to blowing the Max weekly token limit in ~48h on May 10–11, 2026.

The 200K default compacts earlier and keeps the prefix size bounded. Commands that genuinely need long context can still request it; routine sessions no longer pay the 1M penalty.

## See also

- `projects/hq-token-economy/prd.json` — US-001, US-015
- `.claude/CLAUDE.md` § Token Optimization
