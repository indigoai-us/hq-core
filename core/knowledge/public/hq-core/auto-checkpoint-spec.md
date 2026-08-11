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

## CLI checkpoint & Stop gate

`hq core checkpoint` is the synchronous, lightweight checkpoint path. It writes a checkpoint thread from the supplied `--session-id`, `--summary`, and optional repeatable learning, decision, next-step, file, and tag fields, then starts a background sibling agent to maintain the user's HQ. Use `--trigger` to label the cause of the checkpoint. For a turn with no substantive change, `--idle` records the fast path without inventing work.

The sibling runs with `HQ_CHECKPOINT_SIBLING=1`. This is an explicit recursion guard: the sibling is a Claude or Codex session in the same HQ root, but must not be required to checkpoint and create another sibling before it can finish its maintenance work. The backend auto-selects Codex first, pinned to `gpt-5.6-terra` with high reasoning effort, then falls back to Claude, pinned to `claude-opus-5` with medium effort, and finally to none.

The canonical Stop-gate implementation is CLI-hosted as `hq core checkpoint-stop-gate` (a bundled scaffold script) and dispatched through the entrypoint fast path so it does not pay the CLI's command-graph startup. The in-tree hook `.claude/hooks/checkpoint-stop-gate.sh` is a thin, behavior-identical fallback: it prefers the CLI when the installed version provides the command (probing `hq core --help` once per CLI version) and otherwise runs its own copy. It also carries an opt-in company-scope requirement: when `HQ_CHECKPOINT_SCOPE_GATE_DOMAINS` lists one or more operator email domains, a session whose caller matches (exact domain-suffix; the delegated-email claim preferred over the service email) must declare a scope — a real tenant, or the reserved `personal` — before a turn can end; a binding to an unknown slug does not satisfy it. It is off by default so release-shipped scaffold stays company-agnostic, callers outside the configured domains are unaffected, and `HQ_CHECKPOINT_GATE=0` disables the whole gate. The gate applies runtime-specific eligibility. Claude Code enforces checkpoints for every account. Codex enforces only for the exact HQ operator account configured CLI-side; direct and delegated identities are treated equivalently. Other Codex accounts and other runtimes are unaffected. Codex eligibility is cached at `workspace/orchestrator/hook-state/checkpoint-gate-eligible-codex`. `HQ_CHECKPOINT_RUNTIME=codex hq core checkpoint --gate-probe` refreshes that cache, prints `eligible` or `ineligible`, and stores `1` or `0`. A cached `0` leaves every turn alone. A missing verdict allows the current turn and launches a background probe for the next one. A positive verdict older than 24 hours still enforces for this turn and refreshes asynchronously, so a stale cache cannot silently open a bypass.

For an eligible session, the final tool call after the last real user message must be a successful Bash invocation of `hq core checkpoint`; a checkpoint followed by another tool call does not satisfy the gate. This includes pure Q&A turns: use `hq core checkpoint --session-id <id> --idle` as the final action when nothing changed. The hook reads only the last 400 transcript lines, treats tool-result user records separately from real user messages, and considers a missing tool result successful because hosts do not always persist it before Stop runs.

The gate is deliberately fail-open. Missing `hq`, an unreadable transcript, an absent session id, malformed state, unavailable parsing tools, or any unexpected hook failure allows the turn rather than trapping a user in a broken session. It caps repeated blocks at two for the same user-turn marker, then allows the third Stop evaluation; `stop_hook_active` supplies one prior block only when no persisted count exists. This preserves the requirement without an endless Stop-hook loop.

Operators can control the behavior without editing hook code:

- `HQ_CHECKPOINT_GATE=0` disables enforcement for the process.
- `HQ_CHECKPOINT_GATE=1` force-enforces and bypasses the eligibility cache, useful for local trials and tests.
- `HQ_CHECKPOINT_SIBLING=1` allows the maintenance sibling to finish without recursive checkpoints.
- `HQ_DISABLED_HOOKS=checkpoint-stop-gate` disables the hook through the normal hook-profile gate.
