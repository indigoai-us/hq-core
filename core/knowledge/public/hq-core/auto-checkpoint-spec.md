# Auto-Checkpoint Spec

Auto-checkpoint has two layers: (1) a PostToolUse trigger that fires after specific tool patterns, and (2) two context-threshold checkpoint directives.

## PostToolUse Trigger

The PostToolUse trigger is **advisory**. `.claude/hooks/auto-checkpoint-trigger.sh` detects checkpoint-worthy events and injects `AUTO-CHECKPOINT SUGGESTED`. When seen, write a lightweight thread file at the next natural pause and continue — do not interrupt in-flight work for it. Only the context-threshold and pre-compaction hooks below emit the mandatory `AUTO-CHECKPOINT REQUIRED`. Do **NOT** rebuild INDEX, update `recent.md`, run `qmd update`, or write legacy checkpoint files on auto-checkpoints. When edits touch knowledge files, commit to the knowledge repo — not HQ git.

| Tool         | Pattern                                                     | Trigger                   | Gate                    |
| ------------ | ----------------------------------------------------------- | ------------------------- | ----------------------- |
| Bash         | `git commit` / `git push`                                   | `git-commit` / `git-push` | none                    |
| Bash         | `gh pr create/merge`                                        | `pr-operation`            | 5 min                   |
| Bash         | `vercel deploy/--prod`                                      | `deployment`              | 5 min                   |
| Bash         | `npm/bun publish`                                           | `package-publish`         | 5 min                   |
| Bash         | `bun run test/npm test/bun test`                            | `test-run`                | 5 min                   |
| Bash         | `curl -X POST/PUT/DELETE`                                   | `api-mutation`            | 5 min                   |
| Edit/MultiEdit | any file (excl. `workspace/threads/`)                     | `sustained-edits`         | 10 edits **and** 5 min  |
| Write        | `workspace/reports/`, `social-drafts/`, `companies/*/data/` | `file-generation`         | 5 min                   |

Rules that keep the trigger quiet and accurate:

- **No per-edit checkpoints.** A single edit is never a milestone. The `sustained-edits` trigger needs both an edit threshold (10 since the last checkpoint) and the elapsed debounce.
- **Failed tool calls are ignored.** Claude Code does not dispatch PostToolUse for a failed call; the Codex adapter does, carrying `tool_response.exit_code`, so the hook checks it.
- **State is session-keyed**, under `workspace/orchestrator/hook-state/checkpoint-{last,edits}-<session>`. It is never keyed by `$PPID` and never stored in `/tmp` — tool and hook processes do not share a parent PID in every host, so a PID-keyed debounce silently never applies and every edit re-fires.
- **Git metadata comes from the repository being worked in**, resolved from the payload's `cwd` (then the edited file's directory, then the hook's cwd) — not from HQ root. Work in an app worktree records that worktree's branch and commit.

Also checkpoint after worker skill completion. Schema: `core/knowledge/public/hq-core/thread-schema.md`.

## Context-Threshold Checkpoints

Context-threshold checkpoints run in two stages. Both are mandatory checkpoint directives, not user-choice prompts. **When either banner appears**, run `/checkpoint` immediately. Do not ask the user first, and do not continue normal task work until the checkpoint is complete.

1. **50% checkpoint (Stop hook).** `.claude/hooks/context-warning-50.sh` fires after an assistant turn when the transcript size crosses ~50% of the context window. Prints once per session (gated via `workspace/.context-warnings/{session_id}`). This leaves enough context to preserve state and, if the remaining task is large, orchestrate subagents after the checkpoint.
2. **PreCompact backup.** `.claude/hooks/auto-checkpoint-precompact.sh` fires immediately before autocompact runs (threshold set by `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`). Autocompact cannot be blocked in Claude Code or Codex, so the banner tells the next assistant turn to run `/checkpoint` before continuing.

**Fallback (instruction-based):** If context feels heavy before either hook fires (many long turns, lots of file reads), proactively run `/checkpoint`. For end-of-session wrap-up, run `/handoff` manually.
