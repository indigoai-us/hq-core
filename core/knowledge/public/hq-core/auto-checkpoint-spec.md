# Auto-Checkpoint Spec

Auto-checkpoint has two layers: (1) a PostToolUse trigger that fires after specific tool patterns, and (2) a two-stage context-usage advisory.

## PostToolUse Trigger

PostToolUse hooks detect checkpoint-worthy events and inject `AUTO-CHECKPOINT REQUIRED`. When seen, write a lightweight thread file immediately and continue. Do **NOT** rebuild INDEX, update `recent.md`, run `qmd update`, or write legacy checkpoint files on auto-checkpoints. When edits touch knowledge files, commit to the knowledge repo — not HQ git.

| Tool  | Pattern                                                | Trigger                          | Debounce |
| ----- | ------------------------------------------------------ | -------------------------------- | -------- |
| Bash  | `git commit` / `git push`                              | `git-commit` / `git-push`        | NO       |
| Bash  | `gh pr create/merge`                                   | `pr-operation`                   | 5 min    |
| Bash  | `vercel deploy/--prod`                                 | `deployment`                     | 5 min    |
| Bash  | `npm/bun publish`                                      | `package-publish`                | 5 min    |
| Bash  | `bun run test/npm test/bun test`                       | `test-run`                       | 5 min    |
| Bash  | `curl -X POST/PUT/DELETE`                              | `api-mutation`                   | 5 min    |
| Edit  | any file (excl. `workspace/threads/`)                  | `file-edit`                      | 5 min    |
| Write | `workspace/reports/`, `social-drafts/`, `companies/*/data/` | `file-generation`           | 5 min    |

Also checkpoint after worker skill completion. Schema: `core/knowledge/public/hq-core/thread-schema.md`.

## Two-Stage Context-Usage Advisory

Context-usage advisories run in two stages. Both present the same three options (checkpoint, handoff, or continue) — neither forces action. **When either banner appears**, present the 3 options to the user and wait for their decision. Do not auto-run `/checkpoint`; let the user pick.

1. **50% advisory (Stop hook).** `.claude/hooks/context-warning-50.sh` fires after an assistant turn when the transcript size crosses ~50% of the context window. Prints once per session (gated via `workspace/.context-warnings/{session_id}`). Purely informational — runway still exists before autocompact.
2. **60% advisory (PreCompact hook).** `.claude/hooks/auto-checkpoint-precompact.sh` fires immediately before autocompact runs (threshold set by `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=60`). Autocompact cannot be blocked in Claude Code, so the banner surfaces options right before compaction proceeds.

**Fallback (instruction-based):** If context feels heavy (many long turns, lots of file reads), proactively suggest `/checkpoint` or `/handoff`. For end-of-session wrap-up, run `/handoff` manually.
