# Harness Hook Coverage — Claude vs. Codex vs. Grok

`.claude/settings.json` is the single authoritative hook-dispatch table. The
Codex (`.codex/hooks/hq-codex-hook-adapter.sh`) and Grok
(`.grok/hooks/hq-grok-hook-adapter.sh`) adapters read it live and dispatch the
same hooks Claude runs (`core/scripts/lib/hook-adapter-core.sh`). This document
records what each runtime can and cannot express, and how each gap is handled.
The enforcement twin of this document is
`core/scripts/tests/harness-settings-dispatch.test.sh`, which derives the full
(event × tool) matrix from `settings.json` and fails on any undeclared gap.

## Events

| Event (settings.json) | Claude | Codex | Grok | Handling |
|---|---|---|---|---|
| SessionStart | native | adapter | adapter (+ user bridge) | full parity |
| UserPromptSubmit | native | adapter | adapter (+ bridge) | full parity |
| PreToolUse | native | adapter | adapter (+ bridge) | full parity (blocking) |
| PostToolUse | native | adapter | adapter (+ bridge) | full parity |
| Stop | native | adapter (can block) | adapter (advisory only — Grok can only block PreToolUse) | parity; Grok Stop hooks run side-effects but cannot hold the turn |
| PreCompact | native | adapter | adapter (+ bridge) | full parity |
| SessionEnd | native | adapter (Codex clamps hook budget to 3s) | adapter (+ bridge) | master-hook fan-out runs in all three |
| SubagentStop | native | adapter | adapter (+ bridge) | master-hook fan-out runs in all three |
| Notification | native | **unsupported by Codex hooks** | adapter (+ bridge) | Codex: essential gap, declared in the parity test |

## Tool matchers (PreToolUse / PostToolUse)

| Claude tool | Codex | Grok | Handling |
|---|---|---|---|
| Bash | `Bash` | `run_terminal_command`/`Shell` | aliased, full parity |
| Edit / Write | `Edit`/`Write`/`apply_patch` | `search_replace`/`write` | aliased; `apply_patch` and generic writes map to **Write** (Edit's hook set is a strict subset of Write's) |
| Read / Grep / Glob | native names | `read_file`/`grep`/`list_dir` | aliased, full parity |
| ExitPlanMode | `update_plan` | — (no plan tool) | Codex parity; Grok essential gap |
| WebSearch | `web_search` (best-effort) | `web_search` | dispatched in both; the adapter rewrites the payload `tool_name` to canonical `WebSearch` (and forwards the full toolInput/response) so `journal-autocapture` records real content |
| Agent | `spawn_agent` → Agent-matched **PreToolUse** hooks; PostToolUse keeps native `spawn_agent` launch metadata; SubagentStop is normalized into the completed Agent result hooks and retains its native master fan-out | `spawn_subagent` → Agent-matched hooks (payload canonicalized to `Agent` + full toolInput) | Codex blocking and completion-journaling parity without misreporting the asynchronous launch acknowledgement as a completed Agent result; Grok full alias parity |
| EnterPlanMode | — | — | essential gap in both (no plan-mode entry tool) |
| MultiEdit / NotebookEdit | — | — | tool names never emitted; their hook sets are subsets of Edit/Write, which are dispatched — no guard coverage lost |
| AskUserQuestion / WebFetch | — | — | essential gap in both (no such tool events) |

## The handling policy

1. **Supported ⇒ mirrored.** If a runtime's hook system supports an event, the
   adapter dispatches everything `settings.json` registers for it. "Supported
   but unregistered" is treated as a bug (this is how Codex missed SessionEnd/
   SubagentStop and Grok missed SessionEnd/SubagentStop/Notification until
   2026-08-11).
2. **Unsupported ⇒ declared.** A combination the runtime cannot express lives in
   the parity test's exception list with a one-line reason. An undeclared gap —
   including any NEW matcher added to `settings.json` — fails the build.
3. **Semantics degrade explicitly, not silently.** Grok cannot block non-
   PreToolUse events and cannot inject model context; its adapter runs those
   hooks for side-effects and surfaces their output as bounded stderr
   diagnostics. Codex Stop blocks are translated to Codex's Stop protocol.
4. **Grok's user bridge mirrors every event; the project registration is
   PreToolUse-only.** Project `.grok/hooks` often never load (observed Grok
   0.2.93), so the user bridge installed under `~/.grok/hooks/` by `hq reindex`
   is the reliable path and registers the full event set. To avoid running a
   passive/side-effect hook twice when a build loads BOTH paths,
   `.grok/hooks/hq-grok.json` registers **PreToolUse only** (blocking is
   idempotent, so redundant enforcement is safe); every passive event fires
   exactly once via the bridge. **Re-run `hq reindex` after updating HQ** so the
   installed user bridge picks up new events.
5. **Fail closed.** If `settings.json` is missing or unparseable, adapters fall
   back to a hardcoded critical-guard set rather than running zero guards.
