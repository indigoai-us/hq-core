---
type: reference
domain: [engineering, product, operations]
status: draft
public: true
tags: [grok, grok-build, swarm, subagents, workers, filesystem-memory, durable]
relates_to:
  - grok-build-message-canvas.md
  - codex-delegation-memory.md
  - thread-schema.md
  - quick-reference.md
---

# Grok Build — Swarm + Worker System (Durable Background Work)

**Audience:** Grok Build agents in HQ.  
**Goal:** Prefer subagent swarms for background work; back them with HQ workers;
persist findings on disk so the parent context stays compact and resume-safe.

Grok-facing doctrine. Claude/Codex already have related patterns (`/run`
delegation, codex-delegation-memory). This doc is the Grok-native always-on
pointer via `.grok/rules/prefer-swarms.md`.

---

## 1. Why

| Problem | Swarm + FS memory fix |
|---------|------------------------|
| Parent context bloat from research/dev loops | Fresh child windows; parent keeps paths + short summaries |
| Lost findings after compaction / handoff | `workspace/orchestrator/.../memory/` is durable |
| Ad-hoc quality variance | Load `worker.yaml` + skills + company policies |
| Reinventing the same role every week | Match registry → else suggest / scaffold worker |

---

## 2. When to swarm

**Always prefer swarm** for background / parallel work:

- Codebase research, mapping, “how does X work”
- Multi-file or multi-module implementation tracks
- Review, test, lint, QA, security-ish read-only passes
- Competitive / market / account research that produces artifacts
- Worker skill runs (`/run` semantics)

**Keep on parent:**

- Interactive clarification with the user
- Single trivial edit
- Cross-tenant / credential / irreversible action judgment
- Final integration of handoffs + user-facing status

Spawn independent children **in parallel** in one parent turn. Max nesting
depth is **1** (Grok subagents cannot spawn subagents).

---

## 3. Autowork / durable home

Before a multi-unit swarm, ensure a durable project home exists:

1. Active session project / PRD path if already bound
2. Else create/reuse via `bash core/scripts/session-project.sh` (lightweight
   project + `prd.json` without full `/plan` interview)
3. Use that slug under `workspace/orchestrator/{project}/`

### Layout (canonical)

```text
workspace/orchestrator/{project}/
  codex-session-plan.md
  state.json                    # optional
  executions/
    {story-or-task-id}.json
  memory/
    session.md
    decisions.md                # optional
    blockers.md                 # optional
    agents/
      01-explore.json
      02-backend-dev.json
      03-review.json
    01-research-brief.md        # optional long-form research
```

Threads for auto-checkpoints:

`workspace/threads/T-{YYYYMMDD}-{HHMMSS}-auto-{slug}.json`

Full thread shapes: `thread-schema.md`.  
Codex-oriented twin: `codex-delegation-memory.md` (same FS contract; names are
historical).

### Parent plan file

Write/update `codex-session-plan.md` (name kept for cross-runtime compatibility)
with:

- Goal and done criteria
- Ordered swarm units (role/worker, ownership paths, isolation)
- Policies / tenant
- Memory paths children must write

---

## 4. Subagent prompt contract

Every spawn prompt should include:

1. **Role** — worker id or generic role (`explore`, implement, review)
2. **Write scope** — dirs/files allowed to change (empty for research)
3. **Must load** — worker.yaml, skill, policies, prior memory paths (not full transcripts)
4. **Must write** — absolute/relative path for handoff JSON
5. **Return shape** — summary-first for swarm sidepane + JSON contract below
6. **Constraints** — tenant isolation, no HQ-root push, secrets never printed

### Handoff JSON

```json
{
  "status": "passed",
  "summary": "One or two sentences.",
  "files_read": ["…"],
  "files_changed": ["…"],
  "findings_path": "workspace/orchestrator/{project}/memory/agents/01-explore.json",
  "decisions": [],
  "risks": [],
  "back_pressure": {
    "tests": "not_run",
    "lint": "not_run",
    "typecheck": "not_run",
    "build": "not_run"
  },
  "context_for_next": "Only what the next unit needs."
}
```

Sidepane presentation: short `description`, summary ≤ ~280 chars, files list —
see `grok-build-message-canvas.md`.

---

## 5. Worker loading

### Match

1. Read `core/workers/registry.yaml`
2. Rank by `triggers` overlap, then `description` / `id` vs task
3. Company scope: prefer `companies/{co}/workers/…` for tenant work

### Load into child

| Asset | Path |
|-------|------|
| Definition | `{worker_path}/worker.yaml` |
| Skill | `{worker_path}/skills/{skill}.md` |
| Knowledge | paths listed on worker + `qmd` when useful |
| Policies | `companies/{co}/policies/` |
| Prior memory | `workspace/orchestrator/{project}/memory/**` (minimal set) |

Prefer `/run {worker} {skill}` skill flow when the user invokes workers
explicitly; for autonomous swarms, replicate the same load + isolate + handoff
behavior via `spawn_subagent`.

### Isolation

| Work | `isolation` / capability |
|------|---------------------------|
| Research / map / review (read-only) | shared workspace, `read-only` or explore type |
| Parallel implementation tracks | `worktree` when edits may collide |
| Single-owner sequential edit | shared workspace OK with clear ownership |

---

## 6. Missing worker: suggest vs auto-scaffold

### Suggest (default advisory)

When work is reusable and no match:

> No worker for “{role}”. Package with `/newworker` (company-scoped for tenant
> work), add `triggers: […]`, optionally `hq workers share …`.

One nudge; respect decline. Aligns with policy
`hq-recommend-worker-on-reusable-skill`.

### Auto-scaffold (when role is clear + reusable)

Do **not** block the swarm on a full interview. Create a minimal worker:

```text
companies/{co}/workers/{worker-id}/
  worker.yaml
  skills/
    {primary-skill}.md
```

`worker.yaml` minimum:

- `worker.id`, `worker.name`, `worker.type`, `worker.description`
- `worker.company` when company-scoped
- `worker.triggers` (4–10 real keywords)
- `instructions` short enough to load every run
- `output.destination` under `workspace/…`
- `verification` stub appropriate to type

Then:

1. `bash core/scripts/generate-workers-registry.sh` (or next reindex)
2. Spawn the swarm unit with the new worker loaded
3. Offer share/promote only after success — never auto-share

**Never** put tenant-specific workers in `core/workers/` (lost on `/update-hq`
and leaks tenants). Shared release-worthy workers only with explicit promote intent.

### Skip scaffold

Throwaway one-offs: still swarm + FS handoff; no worker tree.

---

## 7. Example swarm shapes

### Research

1. Parent: plan path + project slug  
2. Parallel: explore code + explore knowledge/docs  
3. Each writes `memory/agents/0N-*.json` + optional brief  
4. Parent synthesizes into `memory/session.md` + user note with paths

### Dev feature

1. Parent: story criteria + ownership  
2. Optional plan subagent → plan file  
3. Implement worker(s) with write scope  
4. Review + QA sidecars read diff / tests  
5. Parent integrates, runs final back-pressure, commits if in repo under `repos/`

### Worker skill

1. Match registry  
2. Spawn with worker+skill context  
3. Memory at  
   `workspace/orchestrator/{project}/memory/agents/{ts}-{worker}-{skill}.json`  
4. Auto-checkpoint thread on completion

---

## 8. Promote path (optional)

| Role | Path |
|------|------|
| Always-on Grok rule | `.grok/rules/prefer-swarms.md` |
| Authoring knowledge | `personal/knowledge/public/hq-core/grok-build-swarm-workers.md` |
| Runtime symlink after reindex | `core/knowledge/public/hq-core/grok-build-swarm-workers.md` |

Frontmatter `public: true` → promote-scan eligible. Do not inject this into
root `AGENTS.md` / Claude hooks unless multi-runtime charter is intended.

---

## 9. Checklist

- [ ] Background work? → spawn swarm (parallel if independent)
- [ ] Durable project home under `workspace/orchestrator/{project}/`
- [ ] Registry match? → load worker + skill + policies into child
- [ ] No match + reusable? → suggest and/or auto-scaffold worker
- [ ] Child writes handoff JSON (+ optional brief)
- [ ] Parent cites paths; keeps chat compact
- [ ] Sidepane: short description + summary + files
- [ ] Tenant boundaries held; no HQ-root push
