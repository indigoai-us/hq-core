---
id: ralph-orchestrator-context-discipline
title: Story sub-agents return structured JSON only; orchestrator parses and refuses malformed
when: /run-project || /run-pipeline || /conduct || /execute-task
on: [UserPromptSubmit]
enforcement: hard
public: true
version: 3
created: 2026-05-13
updated: 2026-11-09
source: user-correction
---

## Rule

**Which rules bind which caller.** Rules 6, 8, 9 and 10 (worker discipline and
transcript budget) bind every orchestrator in the trigger, including `/conduct`.
Rules 6 and 8 have a default form and an advanced form. The default form binds
default `/conduct`, `/run-project` and `/execute-task`, which run work through
named subagents. The advanced form binds only advanced mode (`/conduct-runners`,
or `conduct.runner: runner`), which runs work through HQ worker lanes. Rules 1–5
and 7 are the story-return contract and bind only an orchestrator that dispatches
a per-story sub-agent it then waits on and parses. Default `/conduct` hands each
task to a named subagent and keeps coordinating instead of waiting on a story
return, so rules 1–5 do not apply to it; if `/conduct` ever grows an inline story
loop, it inherits them.

Any orchestrator that dispatches a story sub-agent to run `/execute-task` (or any equivalent per-story worker) MUST:

1. **Inject a `RETURN CONTRACT: json` directive** into the sub-agent prompt. The directive names the schema (status, story_id, commits, files_changed, back_pressure, workers_run, notes) and forbids prose, markdown fences, and trailing commentary.
2. **Parse the returned message as JSON** before acting on it. Use `jq -e .` (or equivalent) to validate. Treat any non-JSON return as `INVALID_RETURN_FORMAT`.
3. **Retry exactly once** on parse failure, with a stricter reminder: `Your previous reply was not valid JSON. Emit ONLY the JSON object specified above. No prose, no fences, no trailing newline.`
4. **Mark the story `blocked` with reason `INVALID_RETURN_FORMAT`** if the retry also fails. Surface to user; do not advance to the next story silently.
5. **Narrate one line per story to the user.** Format: `[{story_id}] {status} · {N} files · {commit_sha_short}`. Anything longer than that line goes to `workspace/threads/journal/<date>/<story-id>.md`, not to the parent transcript.
6. **Keep the orchestrator in budget mode by default.** Run each worker as one named subagent per worker id and keep it across phases. In Claude Code, start it with `Agent` and resume it with `SendMessage`. Codex has no `SendMessage`: run each later phase with `spawn_agent`, passing the worker's earlier handoff file, and collect it with `wait_agent`. The parent never runs a phase itself. Set Codex `reasoning_effort` to `low` unless a hard policy or explicit user request requires more.
   <!-- advanced-mode:start -->
   - Advanced mode (`conduct.runner: runner`, `/conduct-runners`): create HQ worker lanes with `hq runners create`, using the invoking session as senior and the story id as `--story`. Continue a worker lane across phases with `hq runners message` while it is live. Read results from lane envelopes and honor HQ lanes admission or capacity refusals.
   <!-- advanced-mode:end -->
7. **Never simulate `/execute-task` phases in the parent.** If a story worker cannot run `/execute-task` internally, pause and switch execution mode instead of spawning architect/dev/review/QA agents from the parent orchestrator. One carve-out: when the host forbids nested subagents, the `/run-project` parent runs `/execute-task` itself, one story at a time. `/execute-task` still runs each phase on its worker subagents, so this is not simulation.
8. **Do not open extra slots by default.** Two stories that classify to the same worker id **serialize on that worker's named subagent**. Do not start a competing subagent for that worker while it is busy. Extra inline review or QA workers require a high-risk trigger or an explicit user opt-in after stating the token/runtime cost.
   <!-- advanced-mode:start -->
   - Advanced mode (`conduct.runner: runner`, `/conduct-runners`): the same stories serialize on that worker lane. Do not create a competing lane while it is live. Dependency-independent stories may run concurrently only when lane admission accepts them.
   <!-- advanced-mode:end -->
9. **Keep parent log reads bounded.** The parent must not read raw test output, full `*.output.json`, or long logs into the transcript. Detailed logs belong on disk; parent inspection must use compact JSON, omit `stdout_tail` / `stderr_tail`, or cap with a small byte tail.
10. **Run budget-aware regression gates.** Every-three-story gates default to repos touched since the last gate. Run the full `metadata.qualityGates` matrix at final completion, before deploy, after high-risk cross-repo contract changes, or when the user explicitly asks for full gates.

The structured-return path is the **default** for story sub-agents. Prose-mode (`RETURN CONTRACT: prose`) is an opt-out for direct CLI use only — never for inline orchestration.

## Scope

Applies to:

- `.claude/skills/run-project/SKILL.md` (inline mode, Step 3b)
- `.claude/skills/execute-task/SKILL.md` (return contract definition, phase loop)
- `.claude/skills/conduct/SKILL.md` (named-subagent orchestration)
- `.claude/skills/conduct-runners/SKILL.md` (advanced mode only: HQ worker lanes)
<!-- advanced-mode:start -->
- Advanced mode only: `hq runners create`, `hq runners list --json`, and lane envelopes (lane creation and result records)
<!-- advanced-mode:end -->
- `.claude/scripts/run-project.sh` (frozen/deprecated headless story-spawning path; retained for legacy direct-CLI/CI use only, not invoked by `/run-project --ralph-mode`)
- Any future orchestrator that spawns per-story workers

Does NOT apply to:

- One-shot human-readable `/execute-task` invocations from the CLI (no orchestrator parent)
- Diagnostic / investigation sub-agents that need prose for the human reader
- Worker phases *inside* `/execute-task` (handoff contract is separate)

## Rationale

Prose returns and raw logs fill the parent's context, and one reused worker per id keeps phase context without paying a cold start each story.

## Hook gating

No hook currently enforces this. A future PostToolUse hook could grep parent-session `Task` invocations for the `RETURN CONTRACT` directive and warn on missing.
