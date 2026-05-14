---
id: ralph-orchestrator-context-discipline
title: Story and phase sub-agents return structured JSON only; orchestrator parses and refuses malformed
scope: global
trigger: orchestrators dispatching story or worker-phase execution sub-agents (`/run-project`, `/run-pipeline`, any future story loop) via `Task` or `spawn_agent`
enforcement: hard
public: true
version: 1
created: 2026-05-13
source: user-correction
---

## Rule

Any orchestrator that dispatches a story sub-agent to run `/execute-task` or dispatches worker-phase sub-agents for a story (Codex inline) MUST:

1. **Inject a `RETURN CONTRACT: json` directive** into the sub-agent prompt. The directive names the schema (story-level: status, story_id, commits, files_changed, back_pressure, workers_run, notes; phase-level: worker, status, commits, files_created, files_modified, handoff_path, back_pressure, issues) and forbids prose, markdown fences, and trailing commentary.
2. **Parse the returned message as JSON** before acting on it. Use `jq -e .` (or equivalent) to validate. Treat any non-JSON return as `INVALID_RETURN_FORMAT`.
3. **Retry exactly once** on parse failure, with a stricter reminder: `Your previous reply was not valid JSON. Emit ONLY the JSON object specified above. No prose, no fences, no trailing newline.`
4. **Mark the story `blocked` with reason `INVALID_RETURN_FORMAT`** if the retry also fails. Surface to user; do not advance to the next story silently.
5. **Narrate one line per story to the user.** Format: `[{story_id}] {status} · {N} files · {commit_sha_short}`. Anything longer than that line goes to `workspace/threads/journal/<date>/<story-id>.md` or `workspace/orchestrator/{project}/executions/{story-id}/`, not to the parent transcript.

The structured-return path is the **default** for story and phase sub-agents. Prose-mode (`RETURN CONTRACT: prose`) is an opt-out for direct CLI use only — never for inline orchestration.

## Rationale

The whole point of fresh-context-per-story (Ralph principle, `core/knowledge/public/Ralph/03-how-ralph-works.md:151-158`) is that the parent orchestrator stays small while sub-agents do the heavy lifting in isolated context. That guarantee breaks the moment a sub-agent returns a prose recap: tool transcripts stay in the sub-agent (good) but a 500-word "here's what I did" reply lands directly in the orchestrator's context (bad). Across 20 stories, that's 10K+ tokens of pure narration the orchestrator never needed.

JSON returns + machine parsing collapse that to ~80 tokens per story. The orchestrator's context budget then stays bounded for the *operational* state it actually needs (next story, retry queue, regression-gate timing) and for the user's interactive turn.

This policy also unblocks a Ralph-mode replacement that doesn't depend on external headless subprocess spawning for context isolation. Inline mode already isolates context per story in Claude and per worker phase in Codex; structured returns plus filesystem handoffs make it equivalent in context-discipline to subprocess Ralph mode without the per-spawn cost.

## Examples

**Correct (orchestrator side):**

```
spawn_agent(message: "Execute story/phase X. RETURN CONTRACT: json. Emit ONLY:\n{...schema...}")
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
- Worker phases *inside* Claude `/execute-task` (handoff contract is separate unless orchestrated directly by Codex inline)

## Hook gating

No hook currently enforces this. A future PostToolUse hook could grep parent-session `Task` invocations for the `RETURN CONTRACT` directive and warn on missing.
