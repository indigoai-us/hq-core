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
| Stop | native | adapter (can block) | adapter (can block) | full parity; all three translate a Stop hook's `decision: block` into their own stop protocol |
| PreCompact | native | adapter | adapter (+ bridge) | full parity |
| SessionEnd | native | adapter (Codex clamps hook budget to 3s) | adapter (+ bridge) | master-hook fan-out runs in all three |
| SubagentStart | native | not mapped | not mapped | Claude: binds an Agent-tool subagent's company scope from the parent session |
| SubagentStop | native | adapter | adapter (+ bridge, can block) | master-hook fan-out runs in all three; Grok gates it like Stop |
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

### Repo merge holds

The `lanes-repo-merge-hold` Bash `PreToolUse` hook sends possible merge commands
to `hq runners hold check --command … --json`, including shell-quoted token
concatenations such as `gh pr m"erge"`. hq-cli owns command parsing and the
`lanes.repo-merge-hold` hq-flags gate. The shim bounds each check to five
seconds and denies only a valid exit-3 response with `ok:false` and a non-empty
`error`. A non-empty `message` supplies the deny reason; otherwise the hook
formats the hold details or the returned error. Invalid payloads and malformed
exit-3 responses allow with one diagnostic. This check fails open by design
because hq-cli treats every check error as allow; missing or older hq-cli
versions produce one stderr diagnostic and do not spam. Claude and Codex route
through the same registry entry, and both honor the structured PreToolUse
deny.

1. **Supported ⇒ mirrored.** If a runtime's hook system supports an event, the
   adapter dispatches everything `settings.json` registers for it. "Supported
   but unregistered" is treated as a bug (this is how Codex missed SessionEnd/
   SubagentStop and Grok missed SessionEnd/SubagentStop/Notification until
   2026-08-11).
2. **Unsupported ⇒ declared.** A combination the runtime cannot express lives in
   the parity test's exception list with a one-line reason. An undeclared gap —
   including any NEW matcher added to `settings.json` — fails the build.
3. **Semantics degrade explicitly, not silently.** Grok's remaining gaps are
   `SessionStart` (stdout ignored) and `UserPromptSubmit` (can reject a prompt,
   but nothing it writes reaches the model). The adapter runs those two for
   side-effects and surfaces their output as bounded stderr diagnostics.
   Everything else is translated, not degraded: `PreToolUse`/`PostToolUse`
   `additionalContext` reaches the model, and Codex and Grok Stop blocks are
   both translated to their own stop protocols.
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

## Native hook engine (`hq-hook`)

When the `core.next` flag is enabled and the compiled `hq-hook` binary is
installed under `~/.hq/bin/hq-hook/stable/`, `hq reindex` can switch supported
hook events per host from shell wrappers to direct engine calls:

```text
~/.hq/bin/hq-hook/stable/hq-hook run --host <claude|codex|grok> <Event> --hq-root <root>
```

- **Per-event switching.** `hq reindex` queries `hq-hook capabilities --json`
  and switches an event only when every required evaluator—including
  `master-hook:<Event>` and any host adapter work—is claimed for that host and
  the workspace's hook files match the engine's pinned revisions. Unclaimed
  events or customized roots stay on the shell dispatcher automatically.
- **Custom folder hooks.** Personal, pack, and company hooks under
  `personal/hooks/`, `core/packages/*/hooks/`, and `companies/*/hooks/`
  continue to run as external commands after the native evaluators, keeping the
  same order, stdin bytes, and timeout limits.
- **Kill switches and switching back.** To bypass the native engine immediately
  without reindexing, set `HQ_CORE_NEXT=off` (or create
  `~/.hq/state/core-next.off`) for direct registrations, or set
  `HQ_HOOK_ENGINE=off` (or create `~/.hq/hook-engine.off`) to disable the
  engine across both direct registrations and per-hook bridging. In either case
  `hq-hook` hands the event back to `master-hook.sh` or the host adapter. To
  rewrite host configuration files back to the shell dispatcher, turn
  `core.next` off and run `hq reindex`. Run `hq doctor` to inspect which core
  each host and event currently calls.

## Google Antigravity

Antigravity has its own hooks API (`SessionStart`, `PreToolUse`,
`PostToolUse`, `PreInvocation`, `PostInvocation`, `Stop`; registered in
`.agents/hooks.json` or `~/.gemini/config/hooks.json`; see
https://antigravity.google/docs/hooks). HQ does not register an adapter for it
yet, so none of the hooks in `.claude/settings.json` run in an Antigravity
session: no policy reminders, no scope or secret guards, and no automatic Work
Mesh presence. Until the adapter ships, `.agents/rules/hq.md` (always on) tells
the agent to read the charter's imported files and the company policies itself
and to report Work Mesh state by hand. `check-hq-hooks.sh --require-ledger`
reports `NOT OBSERVED` for an Antigravity session, which is accurate.
