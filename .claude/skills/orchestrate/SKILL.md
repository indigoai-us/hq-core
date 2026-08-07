---
name: orchestrate
description: Take an idea all the way to a finished deliverable in one command — capture it, research and compare approaches, generate the PRD, then execute every story to the actual work product (code, artwork, documents), continuously and without pausing. Recommended answers are taken automatically and recorded in the decision ledger; --gated pauses at human decisions instead; --plan-only stops at the execution-ready PRD. Use when the user says "/orchestrate", "take this idea to done", "make this end to end", or wants idea → brainstorm → plan → execution chained without invoking each step by hand. Formerly /ideate (planning-only).
allowed-tools: Read, Write, Grep, Glob, Bash, Bash(node:*), Bash(bash:*), Bash(nohup:*), Bash(ls:*), Bash(cat:*), Bash(jq:*), Bash(tail:*), Bash(mkdir:*), Bash(file:*), Bash(bash core/scripts/workflow-gate.sh:*), Bash(node core/scripts/workflow-runner.mjs:*), AskUserQuestion, Task
argument-hint: "[company] <idea description> [--board <id>] [--engine codex|grok] [--gated] [--plan-only]"
---

# Orchestrate — Idea → Finished Deliverable, One Command

Runs the whole arc through the core workflow runner
(`core/scripts/workflow-runner.mjs` — Codex by default, Grok via
`--engine grok`), launched detached in the background:

**Capture → Brainstorm → Decide → PRD → Resolve → Execute.**

**Default: continuous, all the way to done.** The run never pauses. Decision
points take the recommended option and record it in the PRD's decision ledger
(`decidedBy: "auto (recommended)"`); open questions with no recommendation
become pre-flight investigation stories; a WEAK premise is logged loudly and
continues (parking is a human call, never automated). After the PRD is
finalized, the Execute phase runs every story in order — one agent each,
sequentially, so later stories can build on earlier artifacts — and a blocked
story stops the line (back-pressure) instead of letting dependents run against
a hole. The run ends with the actual deliverables, and the human reviews the
decision ledger and artifacts at close-out.

**`--gated`:** planning decisions (weak premise, approach, open questions)
pause as durable human gates this session relays. Protocol:
`core/knowledge/public/hq-core/workflow-gates-spec.md`.

**`--plan-only`:** stop at the execution-ready `prd.json` (the classic
planning finish line); execution then happens later via `/run-project` in a
fresh session.

## Step 1: Parse & Resolve

- First word matches a company slug in `companies/manifest.yaml` → anchor
  `{co}`, announce ("Anchored on **{co}**"). Otherwise resolve from cwd, else
  ask (one AskUserQuestion).
- `--board <id>` → expanding an existing board idea.
- `--engine codex|grok` → which agent CLI runs the stages (default codex).
- `--gated` → pause at human gates. `--plan-only` → stop at the PRD.
- Remaining text = the idea description. If empty, ask for it (fold into the
  same single question as company when both are missing).

## Step 2: One-Batch Interview (only if genuinely unclear)

At most one AskUserQuestion batch, and only for what the description leaves
genuinely open — if direction and constraints are already clear or don't
matter for this idea, ask nothing and default direction to `speed`:

1. **Direction** — A. Speed to ship · B. Quality/durability · C. Exploration
   (prove/disprove first) · D. Cost minimization
2. **Hard constraints?** — free text (timeline, must-use tech, budget), or none

This is the last question before the finished deliverable in continuous mode.

## Step 3: Preflight

Run these cheap checks; on any failure use the Fallback (Step 7):

```bash
command -v node
command -v {codex|grok}        # the chosen engine's CLI
test -f core/scripts/workflow-runner.mjs
test -f core/scripts/workflow-gate.sh
```

If the idea names a specific execution surface (an image tool, an external
service), probe it with one minimal end-to-end use BEFORE launching — a
2-minute probe beats discovering a phantom tool three stories deep.

## Step 4: Launch the Pipeline (detached)

Pick the run dir first — it is this run's identity. Then launch the runner
**detached**, so a session restart, compaction, or crash cannot take the run
down with it (agent work is not resumable — only human answers are).
`{skill_dir}` = this skill's directory; include `"gated":true` /
`"planOnly":true` only when the flags were given:

```bash
RUN_DIR=workspace/tmp/workflow-runner/orchestrate-{co}-{ts}
nohup node core/scripts/workflow-runner.mjs {skill_dir}/scripts/orchestrate-pipeline.mjs \
  --args '{"company":"{co}","description":"{description}","engine":"{engine}","direction":"{direction}","constraints":"{constraints}","boardId":"{board id or omit}","gated":{true|omit},"planOnly":{true|omit}}' \
  --run-dir "$RUN_DIR" > "$RUN_DIR.out" 2>&1 < /dev/null &
disown
```

(Create the run dir's parent first if needed. Keep `$RUN_DIR` — Step 5 needs
it.)

## Step 5: Watch the Run

Watching is **run-scoped**: `watch-run` blocks on gates belonging to *this*
run only and ends on its own when the run finishes. Repeat until it reports
done:

```bash
bash core/scripts/workflow-gate.sh watch-run "$RUN_DIR" --timeout 900
```

- **exit 3** — the run finished. Go to Step 6.
- **exit 1** — timeout with the run still live. Check `$RUN_DIR.out` for
  progress (`auto-decided` and `story ... passed` lines are normal), then
  watch again. Execute-phase stories can take 15–30 min each on slow engines.
- **exit 0** — it printed a gate id (gated mode; continuous runs open no
  gates). Read `workspace/gates/pending/{id}.json` and ask the user with
  **one AskUserQuestion for that gate**: options from the gate file, the
  `recommended` one first and marked "(Recommended)", plus the gate's own
  defer/park option if present. Then answer:

  ```bash
  bash core/scripts/workflow-gate.sh answer {id} "{choice}" [--notes "..."]
  ```

  If the user's answer is not one of the offered options, record it faithfully
  with `--freeform` and put their wording in `--notes`. The paused run resumes
  on its own; never relaunch it.

Between events, stay quiet — at most one milestone beat per phase (Capture /
Brainstorm / Decide / PRD / Resolve / Execute). If a `TIMEOUT WARNING`
repeats for the same agent with no log growth, inspect its log before
deciding to kill the process group named in the warning — never pattern-kill.

## Step 6: Verify & Close

Parse the run's final JSON and **independently verify** — agent-reported
success is a claim, not a fact:

- `status: "parked"` (gated) → confirm the board shows `exploring` with a
  `brainstorm_path`; report plainly; done.
- `status: "prd_ready"` (`--plan-only`) → verify prd.json parses, story count
  > 0, board `prd_created`, brainstorm `promoted`. Close with the decision
  ledger and: "To execute, start a fresh session and run `/run-project
  {name}`."
- `status: "delivered"` → verify **every path in `deliverables[]` exists**
  (`ls`/`file` — check content type, not just the name: engines sometimes
  write JPEG data behind a .png name), prd.json parses with all stories
  `passes: true`, board `prd_created`, brainstorm `promoted`. Spot-check the
  primary artifact against the PRD's acceptance bar yourself (for visual work
  that means looking at it — keep the parent session under 10 images;
  delegate bulk image checks). Then close out:

```
**{name}** — delivered. {storiesExecuted}/{storiesTotal} stories,
{deliverables.length} artifact(s):
  - {deliverable path} ...

Decisions taken for you ({autoDecided} — review, veto anything):
  - {question} → {answer}
{Premise verdict: {premiseVerdict} — read the brainstorm before building
 further on this. (only when not STRONG)}
```

  Send the primary artifact to the user when it is a viewable deliverable.
- `status: "execution_blocked"` → report which story blocked and why, what
  completed (with artifacts), and offer: fix-forward in this session, re-run
  (completed stories' artifacts and all ledgered decisions survive — the
  brainstorm/PRD stages re-run but human answers are durable), or park.
- Write the auto-checkpoint thread file (type `auto-checkpoint`, trigger
  `orchestrate-complete`) so a fresh session can pick up.
- Leave `workspace/gates/answered/` entries in place (gated runs) — re-run
  memory. Do not clear while the project is live.

## Step 7: Fallback — Guided Mode (missing node / engine CLI / runner)

Run the same arc sequentially **in this session**: execute
`.claude/skills/idea/SKILL.md`, then `.claude/skills/brainstorm/SKILL.md`,
then `.claude/skills/prd/SKILL.md` (or `/plan`), then execute the stories in
order yourself, honoring the same continuous/gated/plan-only semantics.
Announce which mode is in use in one line at launch time.

## Rules

- **Continuous by default — the run never pauses and ends at the
  deliverable.** Every auto-taken decision lands in the PRD's decision ledger
  and is shown at close-out; a silent decision is a defect.
- **Never auto-park.** A WEAK premise continues with a loud log line and a
  close-out flag. Stopping work is the human's call.
- **Execution is sequential with back-pressure.** One agent per story, in
  order; a blocked story stops the line and is reported honestly — no faked
  acceptance criteria, no skipped gates on quality commands.
- **Gated mode: gates are the only mid-run questions**, relayed one at a time
  via AskUserQuestion; answer files are written only via
  `core/scripts/workflow-gate.sh`.
- **Company isolation** — all stage agents read/write only the anchored
  company's scope.
- **Verify independently** — artifacts on disk (content-sniffed), PRD state,
  board state. For visual deliverables, look at the result before calling it
  done.
- **One pipeline per session.** If gates from an unrelated run are pending at
  launch (`workflow-gate.sh list`), surface them first.

## See also

- `/idea`, `/brainstorm` — the planning stages this pipeline chains
- `/prd`, `/deep-plan`, `/plan` — PRD generation
- `/run-project` — story execution for `--plan-only` PRDs (fresh session)
- `core/knowledge/public/hq-core/workflow-gates-spec.md` — the gate protocol
- `core/scripts/workflow-runner.mjs` — the multi-engine workflow runner
