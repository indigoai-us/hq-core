---
id: ralph-orchestrator-context-discipline
title: Story sub-agents return structured JSON only; orchestrator parses and refuses malformed
scope: global
trigger: orchestrators dispatching story execution sub-agents (`/run-project`, `/run-pipeline`, any future story loop) via `Task` or `spawn_agent`
enforcement: hard
public: true
version: 1
created: 2026-05-13
source: user-correction
---

## Rule

Any orchestrator that dispatches a story sub-agent to run `/execute-task` (or any equivalent per-story worker) MUST:

1. **Inject a `RETURN CONTRACT: json` directive** into the sub-agent prompt. The directive names the schema (status, story_id, commits, files_changed, back_pressure, workers_run, notes) and forbids prose, markdown fences, and trailing commentary.
2. **Parse the returned message as JSON** before acting on it. Use `jq -e .` (or equivalent) to validate. Treat any non-JSON return as `INVALID_RETURN_FORMAT`.
3. **Retry exactly once** on parse failure, with a stricter reminder: `Your previous reply was not valid JSON. Emit ONLY the JSON object specified above. No prose, no fences, no trailing newline.`
4. **Mark the story `blocked` with reason `INVALID_RETURN_FORMAT`** if the retry also fails. Surface to user; do not advance to the next story silently.
5. **Narrate one line per story to the user.** Format: `[{story_id}] {status} · {N} files · {commit_sha_short}`. Anything longer than that line goes to `workspace/threads/journal/<date>/<story-id>.md`, not to the parent transcript.
6. **Keep Codex inline in budget mode by default.** Use one preflight explorer, one story worker per story, and one regression-gate worker at gate cadence; set Codex `reasoning_effort` to `low` unless a hard policy or explicit user request requires more.
7. **Never simulate `/execute-task` phases in the parent.** If a story worker cannot run `/execute-task` internally, pause and switch execution mode instead of spawning architect/dev/review/QA agents from the parent orchestrator.
8. **Do not swarm from Codex inline by default.** `--swarm` is a Ralph/headless mode. Extra inline review or QA agents require a high-risk trigger or an explicit user opt-in after stating the token/runtime cost.
9. **Keep parent log reads bounded.** The parent must not read raw test output, full `*.output.json`, or long logs into the transcript. Detailed logs belong on disk; parent inspection must use compact JSON, omit `stdout_tail` / `stderr_tail`, or cap with a small byte tail.
10. **Run budget-aware regression gates.** Every-three-story gates default to repos touched since the last gate. Run the full `metadata.qualityGates` matrix at final completion, before deploy, after high-risk cross-repo contract changes, or when the user explicitly asks for full gates.

The structured-return path is the **default** for story sub-agents. Prose-mode (`RETURN CONTRACT: prose`) is an opt-out for direct CLI use only — never for inline orchestration.

## Rationale

The whole point of fresh-context-per-story (Ralph principle, `core/knowledge/public/Ralph/03-how-ralph-works.md:151-158`) is that the parent orchestrator stays small while sub-agents do the heavy lifting in isolated context. That guarantee breaks the moment a sub-agent returns a prose recap: tool transcripts stay in the sub-agent (good) but a 500-word "here's what I did" reply lands directly in the orchestrator's context (bad). Across 20 stories, that's 10K+ tokens of pure narration the orchestrator never needed.

JSON returns + machine parsing collapse that to ~80 tokens per story. The orchestrator's context budget then stays bounded for the *operational* state it actually needs (next story, retry queue, regression-gate timing) and for the user's interactive turn.

This policy also unblocks a Ralph-mode replacement that doesn't depend on `claude -p` subprocess spawning for context isolation. Inline mode (Task / spawn_agent sub-agents) already isolates context per story; structured returns make it equivalent in context-discipline to subprocess Ralph mode without the per-spawn cost.

Codex adds one more failure mode: it is easy for the parent to keep spawning helpful side agents or to inspect raw outputs while debugging. That defeats the story-boundary savings even when the sub-agent return is JSON. Budget mode makes the parent a coordinator again: one delegated story, one compact result, bounded gates.

## Examples

**Correct (orchestrator side):**

```
spawn_agent(message: "Execute story X. RETURN CONTRACT: json. Emit ONLY:\n{...schema...}")
-> raw_reply = wait_agent(...)
-> if ! echo "$raw_reply" | jq -e . > /dev/null; then retry once; fi
-> if still invalid: mark blocked, surface to user
-> on success: parse fields, narrate `[X] passed · 3 files · a1b2c3d`
```

**Incorrect:**

```
spawn_agent(message: "Execute story X. Tell me what happened.")
-> reply is 400 words of prose
-> orchestrator decides "looks like it passed" by string-matching
```

## Scope

Applies to:

- `.claude/skills/run-project/SKILL.md` (inline mode, Step 3b)
- `.claude/skills/execute-task/SKILL.md` (return contract definition)
- `.claude/scripts/run-project.sh` (Ralph-mode story spawning — already JSON-parsed at line 2807; bring `RETURN CONTRACT` injection into parity)
- Any future orchestrator that spawns per-story workers

Does NOT apply to:

- One-shot human-readable `/execute-task` invocations from the CLI (no orchestrator parent)
- Diagnostic / investigation sub-agents that need prose for the human reader
- Worker phases *inside* `/execute-task` (handoff contract is separate)

## Hook gating

No hook currently enforces this. A future PostToolUse hook could grep parent-session `Task` invocations for the `RETURN CONTRACT` directive and warn on missing.
