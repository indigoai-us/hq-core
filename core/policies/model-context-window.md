---
name: model-context-window
when: always
on: [SessionStart]
description: The default model is the plain opus alias, which follows new Opus releases; the opus[1m] (1M context) variant is opt-in per command, not the global default
enforcement: soft
vendor_public_ok: true
public: true
created: 2026-05-12
---

## Rule

The global default model in `.claude/settings.json` is the plain `opus` alias, and `CLAUDE_CODE_SUBAGENT_MODEL` is `opus` too. Claude Code resolves the alias to its newest Opus model, so new Opus releases apply without an edit. Do not pin a dated model ID such as `claude-opus-4-8` in the shipped settings: a dated pin freezes every install and every subagent on that model. The `opus[1m]` variant (1M context) is **opt-in per command**, not the default.

Commands that opt into `[1m]`:

- `/discover` — codebase ingestion fans out parallel exploration; long context is load-bearing
- `/deep-plan` — multi-tier interview + research subagents accumulate spec material
- `/run-project` — long Ralph loops accumulate per-story summaries; opt-in only for long projects (>10 stories)
- `/diagnose` — instrumentation + repro cycles accumulate logs

How a command opts in (mechanism resolved by US-015):

1. Per-command frontmatter `model: opus[1m]` if the runtime honors it, or
2. Slash-command runtime flag (e.g. `/run-project foo --model opus[1m]`), or
3. Soft fallback: command's first step prompts the user to restart the session with `--model opus[1m]` if long context is needed; otherwise proceeds with the default context window.

## Rationale

A 1M-context default delays autocompact: at the 60% threshold, the prefix is ~600K tokens, dominated by raw tool-results and stale system reminders. On long sessions this produced `cache_read` totals as high as 468M tokens (session 75aa571a, May 2026), which contributed to blowing the Max weekly token limit in ~48h on May 10–11, 2026.

The 200K default compacts earlier and keeps the prefix size bounded. Commands that genuinely need long context can still request it; routine sessions no longer pay the 1M penalty.

## See also

- `projects/hq-token-economy/prd.json` — US-001, US-015
- `.claude/CLAUDE.md` § Token Optimization
