# Grok Build — prefer worker-backed swarms + durable FS memory

Grok-only project rule. Do not mirror into Claude hooks or the shared root charter
unless intentionally promoting to multi-runtime HQ core.

## Default: swarm background work

For **background / parallelizable** work, prefer `spawn_subagent` swarms over
doing everything inline in the parent. Parent stays the orchestrator: user loop,
integration, verification, commits, and durable memory.

| Spawn (background swarm) | Keep inline (parent) |
|--------------------------|----------------------|
| Research / explore / map codebase | Tight Q&A with the user |
| Multi-file investigation | Single-file trivial edit |
| Independent impl tracks | Irreversible shared actions (push, prod, invites) until approved |
| Review, tests, QA sidecars | Final synthesis + decision prompts |
| Worker skill execution | Security / tenant-boundary judgment |

Independent tracks → **spawn multiple subagents in one turn**. Nesting depth is 1
(children cannot spawn children).

### Sidepane hygiene

- Short 3–6 word `description` on spawn
- Final result: ≤ ~280 char summary first + files touched  
  See `.grok/rules/message-canvas.md`

## Durable findings (context stays compact)

Subagents must **write findings to the filesystem**, not only chat. Parent reads
those files and keeps only compact summaries in-session.

Resolve project slug from active session project / PRD when available; else
`session-scratch` or `bash core/scripts/session-project.sh` when a durable home
is needed.

```text
workspace/orchestrator/{project}/
  codex-session-plan.md          # parent plan (ok under Grok too)
  memory/
    session.md                   # human running summary
    agents/
      {NN}-{role-or-worker}.json # machine handoffs
  executions/
    {story-or-task-id}.json      # optional phase state
```

Also write an auto-checkpoint when a swarm unit finishes meaningfully:

`workspace/threads/T-{YYYYMMDD}-{HHMMSS}-auto-{slug}.json`

(schema: `core/knowledge/public/hq-core/thread-schema.md`)

### Required handoff JSON (every subagent)

Write + return:

```json
{
  "status": "passed|failed|blocked|partial",
  "summary": "One or two sentences.",
  "files_read": [],
  "files_changed": [],
  "findings_path": "workspace/orchestrator/{project}/memory/agents/{NN}-{role}.json",
  "decisions": [],
  "risks": [],
  "back_pressure": {
    "tests": "not_run|passed|failed",
    "lint": "not_run|passed|failed",
    "typecheck": "not_run|passed|failed",
    "build": "not_run|passed|failed"
  },
  "context_for_next": "Only what the next worker needs."
}
```

For research-only agents, also drop a short markdown brief when useful:

`workspace/orchestrator/{project}/memory/{NN}-research-brief.md`

Parent must **not** re-paste large transcripts; cite paths.

## Load the worker system

Before spawning a research/dev/ops/review swarm:

1. Scan `core/workers/registry.yaml` (and company workers under
   `companies/{co}/workers/`) for a matching `id` / description / `triggers`.
2. If matched → load that worker into the child:
   - `{worker_path}/worker.yaml` (instructions, tools, knowledge, company)
   - relevant `{worker_path}/skills/{skill}.md`
   - company policies for that tenant
   - minimal prior memory under `workspace/orchestrator/{project}/memory/`
3. Prefer `/run {worker} {skill}` semantics (see skill `run`): isolated child,
   parent owns integration + memory write.
4. Respect tenant isolation — never cross-company credentials or knowledge.
5. Work-mesh when project-scoped: `bash core/scripts/work-mesh.sh check|progress|…`

### Role → typical workers (start here)

| Background work | Prefer these workers when present |
|-----------------|-----------------------------------|
| Architecture / design | `architect`, `product-planner` |
| Backend impl | `backend-dev`, `database-dev` |
| Frontend impl | `frontend-dev`, design workers |
| Review | `code-reviewer`, `codex-reviewer`, `reality-checker` |
| Debug | `codex-debugger` |
| Tests / QA | `qa-tester` |
| Knowledge / docs | `knowledge-curator`, `context-manager` |
| Garden / cleanup | gardener-team workers |

Use `explore` / `plan` / `general-purpose` subagent types when no worker fits,
but still write durable handoffs.

## Missing worker → suggest or scaffold

When background work is **repeatable** and no registry match exists:

1. **Suggest first** (one short advisory) — package as a company/personal worker
   via `/newworker`, with example `triggers:` keywords. Do not block the swarm.
2. **Auto-scaffold** a minimal worker when the role is clear and reusable
   (research/dev/ops/review pattern that will recur), without waiting for a
   full interview:
   - Default scope: `companies/{co}/workers/{worker-id}/` for tenant work,
     `personal/` / company personal path for personal-only work
   - Never put tenant-specific workers under `core/`
   - Create `worker.yaml` + at least one skill stub + output destination under
     `workspace/`
   - Run `bash core/scripts/generate-workers-registry.sh` (or rely on reindex)
   - Load the new worker into the current swarm immediately
3. **Do not share** (`hq workers share`) or promote to release `core/` without
   explicit user go-ahead.
4. Skip scaffold for true one-offs; still use a swarm + FS handoff.

Aligns with soft policy `hq-recommend-worker-on-reusable-skill` (suggest on
reusable capability) — this rule adds Grok swarm + optional auto-scaffold.

## Parent obligations after swarm

- Integrate handoff files; update `memory/session.md`
- Run / record back-pressure for code work
- Surface blockers and human decisions only
- Quiet status: completion, blockers, irreversible actions — not play-by-play

## Full reference

- `personal/knowledge/public/hq-core/grok-build-swarm-workers.md`
- After reindex: `core/knowledge/public/hq-core/grok-build-swarm-workers.md`
- Memory layout: `core/knowledge/public/hq-core/codex-delegation-memory.md`
- Workers: `core/knowledge/public/workers/README.md`, `core/workers/registry.yaml`
