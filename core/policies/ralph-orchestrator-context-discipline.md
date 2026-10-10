---
id: ralph-orchestrator-context-discipline
title: Story sub-agents return structured JSON only; orchestrator parses and refuses malformed
when: /run-project || /run-pipeline || /conduct || /execute-task
on: [UserPromptSubmit]
enforcement: hard
public: true
version: 2
created: 2026-05-13
updated: 2026-09-11
source: user-correction
---

## Rule

**Which rules bind which caller.** Rules 6, 8, 9 and 10 — lane discipline and
transcript budget — bind every orchestrator in the trigger, including `/conduct`,
which is why it is listed there. Rules 1–5 and 7 are the story-return contract
and bind only an orchestrator that dispatches a per-story sub-agent it then waits
on and parses. `/conduct` launches one detached task and hands the run directory
back, so it has no return to parse and rules 1–5 do not apply to it; if `/conduct`
ever grows an inline story loop, it inherits them.

Any orchestrator that dispatches a story sub-agent to run `/execute-task` (or any equivalent per-story worker) MUST:

1. **Inject a `RETURN CONTRACT: json` directive** into the sub-agent prompt. The directive names the schema (status, story_id, commits, files_changed, back_pressure, workers_run, notes) and forbids prose, markdown fences, and trailing commentary.
2. **Parse the returned message as JSON** before acting on it. Use `jq -e .` (or equivalent) to validate. Treat any non-JSON return as `INVALID_RETURN_FORMAT`.
3. **Retry exactly once** on parse failure, with a stricter reminder: `Your previous reply was not valid JSON. Emit ONLY the JSON object specified above. No prose, no fences, no trailing newline.`
4. **Mark the story `blocked` with reason `INVALID_RETURN_FORMAT`** if the retry also fails. Surface to user; do not advance to the next story silently.
5. **Narrate one line per story to the user.** Format: `[{story_id}] {status} · {N} files · {commit_sha_short}`. Anything longer than that line goes to `workspace/threads/journal/<date>/<story-id>.md`, not to the parent transcript.
6. **Keep the orchestrator in budget mode by default.** Create HQ worker lanes with `hq lanes create`, using the invoking session as senior and the story id as `--story`. Continue a worker lane across phases; send follow-ups with `hq lanes message` while it is live. Read results from lane envelopes and honor HQ lanes admission or capacity refusals. Set Codex `reasoning_effort` to `low` unless a hard policy or explicit user request requires more.
7. **Never simulate `/execute-task` phases in the parent.** If a story worker cannot run `/execute-task` internally, pause and switch execution mode instead of spawning architect/dev/review/QA agents from the parent orchestrator.
8. **Do not open extra slots by default.** Two stories that classify to the same worker id **serialize on that worker lane**. Do not create a competing lane while it is live. Extra inline review or QA workers require a high-risk trigger or an explicit user opt-in after stating the token/runtime cost. Dependency-independent stories may run concurrently only when lane admission accepts them.
9. **Keep parent log reads bounded.** The parent must not read raw test output, full `*.output.json`, or long logs into the transcript. Detailed logs belong on disk; parent inspection must use compact JSON, omit `stdout_tail` / `stderr_tail`, or cap with a small byte tail.
10. **Run budget-aware regression gates.** Every-three-story gates default to repos touched since the last gate. Run the full `metadata.qualityGates` matrix at final completion, before deploy, after high-risk cross-repo contract changes, or when the user explicitly asks for full gates.

The structured-return path is the **default** for story sub-agents. Prose-mode (`RETURN CONTRACT: prose`) is an opt-out for direct CLI use only — never for inline orchestration.

## Rationale

The parent orchestrator stays small while workers do the heavy lifting in isolated context. That guarantee breaks the moment a worker returns a prose recap: tool transcripts stay in the worker (good) but a 500-word "here's what I did" reply lands directly in the orchestrator's context (bad). Across 20 stories, that's 10K+ tokens of pure narration the orchestrator never needed.

The orchestrator keeps its context bounded by staying focused on coordination, requiring JSON returns, and using HQ lanes for admission and capacity. A continuing lane keeps its worker identity and phase context, while a cold start pays those setup costs again for each story. Bounded phase briefs and handoffs keep context useful across phases.

JSON returns + machine parsing collapse that to ~80 tokens per story. The orchestrator's context budget then stays bounded for the *operational* state it actually needs (next story, retry queue, regression-gate timing) and for the user's interactive turn.

This is also why the in-session loop **is** Ralph mode now (re-engined 2026-05). Inline mode (Task / spawn_agent sub-agents) isolates context per story without depending on `claude -p` subprocess spawning; structured returns make it equivalent in context-discipline to the old subprocess Ralph mode without the per-spawn cost — so `--ralph-mode` was redefined as this inline loop run unattended rather than a detached `claude -p` orchestrator.

Codex adds one more failure mode: it is easy for the parent to keep spawning helpful side agents or to inspect raw outputs while debugging. That defeats the savings even when the worker's return is JSON. Budget mode keeps the parent focused on coordination. It reads one compact result at a time, runs bounded gates, and reuses each worker lane across related phases.

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
- `.claude/skills/execute-task/SKILL.md` (return contract definition, phase loop)
- `.claude/skills/conduct/SKILL.md` (HQ worker lanes orchestration)
- `hq lanes create`, `hq lanes list --json`, and lane envelopes (lane creation and result records)
- `.claude/scripts/run-project.sh` (frozen/deprecated headless story-spawning path — JSON-parsed at line 2807; retained for legacy direct-CLI/CI use only, not invoked by `/run-project --ralph-mode`)
- Any future orchestrator that spawns per-story workers

Does NOT apply to:

- One-shot human-readable `/execute-task` invocations from the CLI (no orchestrator parent)
- Diagnostic / investigation sub-agents that need prose for the human reader
- Worker phases *inside* `/execute-task` (handoff contract is separate)

## Hook gating

No hook currently enforces this. A future PostToolUse hook could grep parent-session `Task` invocations for the `RETURN CONTRACT` directive and warn on missing.
