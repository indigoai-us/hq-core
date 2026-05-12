# Project System to Desktop UX Mapping

Maps the PRD lifecycle, orchestrator state machine, Ralph loop execution stages, story states, and quality gates to Desktop representation. Produced for US-010 of hq-desktop-epics.

---

## 1. prd.json Schema (Source of Truth)

Every project is defined by `projects/{name}/plan.json`. Desktop must parse this schema correctly (currently broken -- see rust-commands-audit.md).

### Top-level fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | yes | Project slug (lowercase, hyphens) |
| `description` | string | yes | One-sentence goal |
| `branchName` | string | no | Git branch (e.g. `feature/{name}`) |
| `userStories` | array | yes | Story objects (see below) |
| `metadata` | object | yes | Project metadata (see below) |

### metadata object

| Field | Type | Description |
|-------|------|-------------|
| `createdAt` | ISO8601 | When PRD was generated |
| `goal` | string | Overall project goal (longer than `description`) |
| `successCriteria` | string | Measurable outcome statement |
| `qualityGates` | string[] | Back-pressure commands (e.g. `["bun run test", "bun check"]`) |
| `repoPath` | string | Target repo relative to HQ (e.g. `repos/private/{product}`) |
| `relatedWorkers` | string[] | Worker IDs relevant to this project |
| `knowledge` | string[] | Relevant knowledge paths |
| `linearCredentials` | string | (optional) Path to Linear API key file |
| `linearDoneStateId` | string | (optional) Linear "Done" state ID |
| `linearInProgressStateId` | string | (optional) Linear "In Progress" state ID |

### userStory object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | yes | Story ID (e.g. `US-001`, `CAM-003`) |
| `title` | string | yes | Short title |
| `description` | string | yes | User story format: "As a [user], I want [feature] so that [benefit]" |
| `acceptanceCriteria` | string[] | yes | Verifiable criteria (not `acceptance`) |
| `priority` | number | yes | 1 = highest |
| `passes` | boolean | yes | Whether story is complete |
| `labels` | string[] | no | Categorization tags |
| `dependsOn` | string[] | no | IDs of prerequisite stories |
| `notes` | string | no | Implementation notes |
| `linearIssueId` | string | no | Linked Linear issue |
| `files` | string[] | no | Files this story touches |
| `worker_hints` | string[] | no | Preferred workers (e.g. `["codex-coder"]`) |

### Desktop display requirements from prd.json

- Project name, description, goal
- Story count and completion percentage (`passes: true` count / total)
- Individual story status with acceptance criteria checklist
- Priority ordering
- Dependency graph (which stories block which)
- Quality gates list
- Target repo link
- Related workers
- Branch name

---

## 2. Orchestrator State Machine

### 2.1 Global State: `workspace/orchestrator/state.json`

Central registry of all projects. Read by `get_orchestrator_state` Tauri command.

```json
{
  "version": "1.0",
  "updated_at": "ISO8601",
  "projects": [
    {
      "name": "project-slug",
      "state": "READY|IN_PROGRESS|PAUSED|BLOCKED|COMPLETED|FAILED",
      "prdPath": "projects/{name}/plan.json",
      "updatedAt": "ISO8601",
      "startedAt": "ISO8601 | null",
      "completedAt": "ISO8601 | null",
      "storiesComplete": 0,
      "storiesTotal": 10,
      "checkedOutFiles": [],
      "parentProject": "parent-slug | null",
      "parentStory": "US-XXX | null"
    }
  ]
}
```

### 2.2 Project States

| State | Meaning | Visual | Transitions From | Transitions To |
|-------|---------|--------|------------------|----------------|
| `READY` | PRD exists, not started | Emerald badge, static | `/plan` creates | IN_PROGRESS |
| `IN_PROGRESS` | Actively executing stories | Green badge, pulse animation | READY, PAUSED | PAUSED, BLOCKED, COMPLETED, FAILED |
| `PAUSED` | Manually paused mid-execution | Yellow badge | IN_PROGRESS | IN_PROGRESS (via `--resume`) |
| `BLOCKED` | Dependency or error blocking | Amber badge, pulse | IN_PROGRESS | IN_PROGRESS (when unblocked) |
| `COMPLETED` | All stories pass | Muted badge | IN_PROGRESS | (terminal) |
| `FAILED` | Unrecoverable error | Red badge, pulse | IN_PROGRESS | READY (restart) |
| `PLANNING` | Being designed (pre-PRD) | Muted | (manual) | READY |
| `QUEUED` | Waiting for slot | Blue badge | READY | IN_PROGRESS |

**State transition diagram (simplified):**

```
/plan creates → READY
                  ↓
            /run-project
                  ↓
            IN_PROGRESS ←──── PAUSED (--resume)
              ↓    ↓    ↓
          COMPLETED  BLOCKED  FAILED
```

### 2.3 Per-Project State: `workspace/orchestrator/{project}/state.json`

Created when `/run-project` starts. More detailed than the global entry.

```json
{
  "project": "project-slug",
  "prd_path": "projects/{name}/plan.json",
  "status": "in_progress|paused|completed",
  "started_at": "ISO8601",
  "updated_at": "ISO8601",
  "progress": {
    "total": 10,
    "completed": 3,
    "failed": 0,
    "in_progress": 1
  },
  "current_task": {
    "id": "US-004",
    "started_at": "ISO8601",
    "phase": 2,
    "worker": "backend-dev"
  },
  "completed_tasks": [
    {
      "id": "US-001",
      "completed_at": "ISO8601",
      "workers_used": ["architect", "code-reviewer"]
    }
  ],
  "retries": 0
}
```

### 2.4 Per-Task Execution: `workspace/orchestrator/{project}/executions/{task-id}.json`

Created when `/execute-task` starts a story. Tracks worker pipeline progress.

```json
{
  "task_id": "US-004",
  "project": "project-slug",
  "started_at": "ISO8601",
  "completed_at": "ISO8601 | null",
  "status": "in_progress|completed|paused",
  "current_phase": 2,
  "phases": [
    { "worker": "backend-dev", "status": "completed", "completed_at": "ISO8601" },
    { "worker": "code-reviewer", "status": "in_progress" },
    { "worker": "dev-qa-tester", "status": "pending" }
  ],
  "handoffs": [
    {
      "from_worker": "backend-dev",
      "to_worker": "code-reviewer",
      "timestamp": "ISO8601",
      "summary": "Implemented API endpoints",
      "files_created": ["src/routes/foo.ts"],
      "files_modified": ["src/index.ts"],
      "key_decisions": ["Used strategy pattern"],
      "context_for_next": "Focus on cache invalidation",
      "back_pressure": { "tests": "pass", "lint": "pass", "typecheck": "pass" }
    }
  ],
  "output": {
    "summary": "What was accomplished",
    "files_created": [],
    "files_modified": [],
    "key_decisions": []
  },
  "codex_debug_attempts": []
}
```

### 2.5 Progress Log: `workspace/orchestrator/{project}/progress.txt`

Append-only human-readable log. One line per completed story.

```
[2026-02-11T20:30:00Z] US-001: Created structure detection doc (1/24)
[2026-02-11T21:15:00Z] US-002: Created child PRD with 10 stories (2/24)
```

---

## 3. Story States

Stories have a simple boolean state (`passes: true|false`) but the execution system adds richer state tracking.

### 3.1 Logical Story States (derived, not stored as enum)

| State | Source | How to Determine | Visual |
|-------|--------|------------------|--------|
| **Pending** | `passes: false` + no execution file | Default for unstarted stories | Empty circle |
| **Blocked** | `passes: false` + `dependsOn` contains incomplete stories | Check dependency chain | Amber lock icon |
| **In Progress** | Execution file exists with `status: "in_progress"` | Read execution JSON | Spinning/pulse indicator |
| **Phase N of M** | Execution file `current_phase` / `phases.length` | Read execution JSON | Progress steps |
| **Paused** | Execution file with `status: "paused"` | Read execution JSON | Yellow pause icon |
| **Complete** | `passes: true` in prd.json | Direct field check | Green checkmark |
| **Failed** | Execution file with failed phases | Read execution JSON | Red X |

### 3.2 Dependency Resolution

Stories declare dependencies via `dependsOn: ["US-001", "US-002"]`. A story is **blocked** when any dependency has `passes: false`.

Desktop should:
1. Build a dependency graph from all stories' `dependsOn` arrays
2. Highlight blocked stories with the blocking story name
3. Show which stories are "next eligible" (all deps satisfied, passes: false)
4. Optionally render dependency graph visually (DAG)

### 3.3 Priority Ordering

Within eligible stories, `/run-project` selects the lowest `priority` number first. Desktop should sort stories by:
1. State (in-progress first, then eligible, then blocked, then complete)
2. Priority (ascending) within each state group
3. ID (ascending) as tiebreaker

---

## 4. Ralph Loop Execution Stages

The Ralph loop is the core execution engine. Understanding its stages is critical for Desktop to show real-time progress.

### 4.1 /plan (Project Creation)

**Input:** Description of what to build
**Process:** Discovery interview → PRD generation → orchestrator registration
**Output:** `projects/{name}/plan.json` + entry in `state.json`

**Desktop interaction:** Trigger via command palette or "New Project" button. Desktop cannot run `/plan` directly (it's a Claude Code command), but it can:
- Detect new prd.json files via file watcher
- Display newly registered projects immediately
- Show project in READY state

### 4.2 /run-project (Orchestrator Loop)

**Input:** Project name
**Process:** Ultra-lean state machine. Picks stories, spawns sub-agents, logs results.

**Stages within a single /run-project session:**

```
1. LOAD    → Read prd.json, validate, count stories
2. DISPLAY → Show progress, remaining stories
3. SELECT  → Pick next eligible story (deps met, passes: false, lowest priority)
4. EXECUTE → Spawn sub-agent with /execute-task {project}/{story-id}
5. POST    → Parse result, update state.json, log to progress.txt
6. CHECK   → Context boundary? If >10 tasks, stop. Otherwise loop to SELECT
```

**What Desktop should display during /run-project:**
- Current story being executed (from `current_task` in per-project state.json)
- Progress bar updating in real-time (stories completed / total)
- Progress log entries as they're appended
- Which sub-agent is running (terminal session)
- Estimated remaining (stories left * average time)

### 4.3 /execute-task (Single Story Execution)

**Input:** `{project}/{story-id}`
**Process:** Classify → Select workers → Execute worker pipeline → Update PRD

**Stages within a single /execute-task:**

```
1. CLASSIFY    → Determine task type (schema_change, api_dev, ui_component, etc.)
2. SELECT      → Choose worker sequence based on type
3. INITIALIZE  → Create execution state file
4. PIPELINE    → For each worker:
   4a. LOAD    → Read worker.yaml config
   4b. BUILD   → Construct worker prompt
   4c. SPAWN   → Launch sub-agent (Task tool)
   4d. VERIFY  → Check back-pressure (tests/lint/typecheck)
   4e. HANDOFF → Pass context to next worker
5. COMPLETE    → Update prd.json (passes: true), capture learnings
```

**What Desktop should display during /execute-task:**
- Task type classification
- Worker pipeline visualization (sequence of workers with status)
- Current worker phase (e.g. "Phase 2/4: code-reviewer")
- Back-pressure results per phase
- Handoff context summaries between phases
- Issues or retries (if back-pressure fails)

### 4.4 Worker Pipeline Types

| Task Type | Worker Sequence | Typical Duration |
|-----------|----------------|------------------|
| `schema_change` | database-dev → backend-dev → code-reviewer → dev-qa-tester | Medium |
| `api_development` | backend-dev → [codex-coder] → code-reviewer → [codex-reviewer] → dev-qa-tester | Medium |
| `ui_component` | frontend-dev → [codex-coder] → motion-designer → code-reviewer → dev-qa-tester | Medium |
| `full_stack` | product-planner → architect → database-dev → backend-dev → frontend-dev → code-reviewer → dev-qa-tester | Long |
| `codex_fullstack` | architect → database-dev → codex-coder → codex-reviewer → dev-qa-tester | Medium |
| `content` | content-brand → content-product → content-sales → content-legal | Short |
| `enhancement` | (relevant dev) → code-reviewer → [codex-debugger] | Short |

`[brackets]` = optional workers, included when worker_hints or task indicators match.

---

## 5. Quality Gates

Quality gates are back-pressure checks that run after each worker phase. They are the safety mechanism that prevents broken code from proceeding through the pipeline.

### 5.1 Gate Types

| Gate | Command | When |
|------|---------|------|
| Tests | `bun run test`, `npm test`, etc. | After code changes |
| Lint | `bun lint`, `eslint`, etc. | After code changes |
| Typecheck | `bun check`, `tsc --noEmit`, etc. | After code changes |
| Build | `bun run build`, `npm run build` | After significant changes |

### 5.2 Gate Results in Execution State

Each worker phase records gate results:

```json
{
  "back_pressure": {
    "tests": "pass|fail|skipped",
    "lint": "pass|fail|skipped",
    "typecheck": "pass|fail|skipped",
    "build": "pass|fail|skipped",
    "e2e_manifest": "pass|fail|skipped"
  }
}
```

### 5.3 Gate Failure Recovery

When a gate fails:
1. **codex-debugger** auto-attempts fix (max 1 attempt per phase)
2. If fix succeeds, pipeline continues
3. If fix fails, retry with error context
4. If retry fails, pipeline pauses

### 5.4 Desktop display for quality gates

- Per-phase pass/fail badges (green check, red X, gray skip)
- Aggregate project health: "All gates passing" or "2 gate failures in last run"
- Gate failure details: which check, error output, whether codex-debugger intervened
- Historical gate results across all executions for a project

---

## 6. Project Data Points Desktop Needs

### 6.1 Project List View

| Data Point | Source | Update Frequency |
|------------|--------|-----------------|
| Project name | state.json `.projects[].name` | Static |
| State badge | state.json `.projects[].state` | On change |
| Stories progress | state.json `.storiesComplete/.storiesTotal` | On story completion |
| Progress bar | Computed from progress ratio | On story completion |
| Current story | Per-project state.json `.current_task.id` | Real-time (during execution) |
| Blocked indicator | state.json `.projects[].blockedBy` | On change |
| Last updated | state.json `.projects[].updatedAt` | On change |
| Parent project | state.json `.projects[].parentProject` | Static |

### 6.2 Project Detail View

| Data Point | Source | Notes |
|------------|--------|-------|
| PRD title & description | prd.json `.name`, `.description` | Static per project |
| Goal | prd.json `.metadata.goal` | Static |
| Success criteria | prd.json `.metadata.successCriteria` | Static |
| Quality gates | prd.json `.metadata.qualityGates` | Static |
| Target repo | prd.json `.metadata.repoPath` | Static |
| Branch name | prd.json `.branchName` | Static |
| Related workers | prd.json `.metadata.relatedWorkers` | Static |
| Story list with AC | prd.json `.userStories[]` | Updated when passes changes |
| Dependency graph | Computed from `.userStories[].dependsOn` | Computed |
| Labels | prd.json `.userStories[].labels` | Static |

### 6.3 Story Detail View

| Data Point | Source | Notes |
|------------|--------|-------|
| Story title & description | prd.json story object | Static |
| Acceptance criteria | prd.json `.acceptanceCriteria[]` | Static (checked via passes) |
| Priority | prd.json `.priority` | Static |
| Dependencies | prd.json `.dependsOn[]` | Static |
| Labels | prd.json `.labels[]` | Static |
| Execution status | executions/{task-id}.json `.status` | Real-time during execution |
| Worker pipeline | executions/{task-id}.json `.phases[]` | Real-time during execution |
| Current phase | executions/{task-id}.json `.current_phase` | Real-time during execution |
| Handoff context | executions/{task-id}.json `.handoffs[]` | After each phase |
| Back-pressure results | executions/{task-id}.json `.phases[].back_pressure` | After each phase |
| Output summary | executions/{task-id}.json `.output` | On completion |
| Files touched | executions/{task-id}.json `.output.files_*` | On completion |
| Key decisions | executions/{task-id}.json `.output.key_decisions` | On completion |

### 6.4 Execution Monitor View (Real-time)

| Data Point | Source | Notes |
|------------|--------|-------|
| Active execution indicator | Per-project state.json `.current_task` != null | Poll or file watch |
| Worker pipeline visualization | execution JSON `.phases[]` | Array of {worker, status} |
| Phase progress steps | execution JSON `.current_phase` / `.phases.length` | e.g. "Phase 2/4" |
| Back-pressure live results | execution JSON phase back_pressure | After each phase completes |
| Handoff summaries | execution JSON `.handoffs[]` | Between phases |
| Codex debug attempts | execution JSON `.codex_debug_attempts[]` | On gate failure recovery |
| Progress log entries | progress.txt | Append-only, watch for new lines |
| Terminal output | PTY session (if Desktop spawned it) | Live stream |

---

## 7. How Desktop Should Interact with /run-project and /execute-task

### 7.1 Current Limitation

`/run-project` and `/execute-task` are Claude Code slash commands. They run inside a Claude Code session (terminal), not via Desktop API. Desktop cannot invoke them directly.

### 7.2 Interaction Model: Observer + Trigger

**Observer role (passive):**
- Watch `workspace/orchestrator/state.json` for project state changes
- Watch `workspace/orchestrator/{project}/state.json` for progress updates
- Watch `workspace/orchestrator/{project}/executions/*.json` for story execution progress
- Watch `projects/{name}/plan.json` for story completion (`passes` flips)
- Watch `workspace/orchestrator/{project}/progress.txt` for log entries
- Auto-refresh interval: 2s when IN_PROGRESS project exists (already implemented in `useOrchestrator`)

**Trigger role (active):**
- Spawn a PTY terminal with `claude "/run-project {name}"` or `claude "/execute-task {project}/{story-id}"`
- The PTY runs in Desktop's embedded terminal (terminal.rs `spawn_pty`)
- Desktop watches file system for state changes while PTY runs
- Desktop can show terminal output alongside project/story visualizations in split pane

**Pause/Resume:**
- Pause: Send Ctrl+C to PTY or use `update_project_state` command to set PAUSED
- Resume: Spawn new PTY with `claude "/run-project --resume {name}"`

### 7.3 Desired Future Architecture

```
Desktop (React)
  ├── ProjectsDashboard     ← reads state.json (file watcher)
  ├── ProjectDetail         ← reads prd.json (file watcher)
  ├── StoryBoard            ← reads prd.json stories + execution JSONs
  ├── ExecutionMonitor      ← reads execution/{task}.json (file watcher)
  └── Terminal (PTY)        ← spawns claude /run-project or /execute-task
        ├── writes state.json     ← watcher picks up
        ├── writes execution JSONs ← watcher picks up
        └── writes progress.txt   ← watcher picks up
```

### 7.4 New Rust Commands Needed for Projects

| Command | Purpose | Priority |
|---------|---------|----------|
| `get_project_prd(name)` | Parse and return full prd.json with correct schema | P0 |
| `get_execution_state(project, task_id)` | Read per-task execution JSON | P1 |
| `list_executions(project)` | List all execution files for a project | P1 |
| `get_project_progress(project)` | Read per-project state.json + progress.txt | P1 |
| `start_orchestrator_watcher` | Watch orchestrator dir for state changes | P1 |
| `start_execution_watcher(project)` | Watch executions/ dir for task progress | P2 |
| `trigger_run_project(name)` | Spawn PTY with `/run-project {name}` | P1 |
| `trigger_execute_task(project, story_id)` | Spawn PTY with `/execute-task {project}/{id}` | P1 |

---

## 8. Gap Analysis: Current Desktop vs Required

### 8.1 What Works Today

- `useOrchestrator` hook reads `state.json` and groups projects by state
- `ProjectsDashboard` displays project list with state badges, progress bars
- `ProjectDetail` (dashboard version) shows story list with expandable acceptance criteria
- Auto-refresh every 2s when IN_PROGRESS projects exist
- `update_project_state` Tauri command can change project state

### 8.2 What Is Broken

| Issue | Impact | Fix Priority |
|-------|--------|-------------|
| `Prd` Rust struct uses wrong field names | `list_prds` returns empty; `PrdEntry` objects never populate | P0 |
| `PrdFeature` uses `acceptance` not `acceptanceCriteria` | Acceptance criteria never display from real data | P0 |
| `ProjectDetail` parses README markdown, not prd.json | Detail view shows nothing useful from real projects | P0 |
| `get_project_detail` reads README.md not prd.json | API returns wrong content | P0 |
| `ProjectEntry` checks `has_readme` not `has_prd` | Project cards show wrong status | P1 |

### 8.3 What Is Missing

| Feature | Needed For | Priority |
|---------|-----------|----------|
| Per-task execution state display | Showing worker pipeline progress during execution | P1 |
| Story dependency visualization | Understanding which stories are blocked and why | P1 |
| Quality gate results display | Showing back-pressure pass/fail per phase | P1 |
| Execution trigger buttons | Starting /run-project or /execute-task from Desktop | P1 |
| Progress log viewer | Seeing completed story summaries in real-time | P2 |
| Handoff context viewer | Understanding what each worker did and passed forward | P2 |
| Worker pipeline visualization | Stepper showing which worker is active | P2 |
| Story kanban board | Columns: pending, blocked, in-progress, complete | P2 |
| Parent/child project linking | Navigating from epic to child PRDs | P2 |
| Codex debug attempt display | Showing auto-fix interventions during gate failures | P3 |
| Historical execution browser | Reviewing past executions for completed stories | P3 |

### 8.4 File Watchers Needed

Currently watching:
- `projects/` (prd_watcher) -- for prd.json changes
- `workspace/threads/` (threads_watcher) -- for thread changes

Need to add:
- `workspace/orchestrator/state.json` -- project state changes
- `workspace/orchestrator/{project}/state.json` -- per-project progress
- `workspace/orchestrator/{project}/executions/` -- task execution progress
- `workspace/orchestrator/{project}/progress.txt` -- log entries

---

## 9. Project Execution Flow Diagram

```
User: /plan campaign-migration
  │
  ▼
┌──────────────────────────────────────────────────────────────────┐
│ /plan                                                              │
│  1. Discovery interview                                           │
│  2. Generate projects/campaign-migration/plan.json                 │
│  3. Register in workspace/orchestrator/state.json (state: READY)  │
│  4. Desktop detects new project via prd_watcher                   │
└──────────────────────────────────────────────────────────────────┘
  │
  ▼
User: /run-project campaign-migration  (or Desktop: "Run" button → PTY)
  │
  ▼
┌──────────────────────────────────────────────────────────────────┐
│ /run-project                                                      │
│  1. Load prd.json, validate                                       │
│  2. Set state → IN_PROGRESS in state.json                         │
│  3. Desktop: project row shows green pulse, auto-refresh starts   │
│  4. Create workspace/orchestrator/campaign-migration/state.json   │
│                                                                    │
│  ┌────── LOOP ──────────────────────────────────────────────┐     │
│  │                                                            │     │
│  │  SELECT next eligible story (deps met, !passes, min prio)  │     │
│  │    Desktop: "Current story: CAM-003" badge appears         │     │
│  │                                                            │     │
│  │  SPAWN sub-agent: /execute-task campaign-migration/CAM-003 │     │
│  │    ├── CLASSIFY: api_development                           │     │
│  │    ├── SELECT workers: backend-dev → code-reviewer → QA    │     │
│  │    ├── EXECUTE pipeline:                                   │     │
│  │    │     Phase 1: backend-dev (writes code)                │     │
│  │    │       → back-pressure: tests=pass, lint=pass          │     │
│  │    │       → handoff to code-reviewer                      │     │
│  │    │     Phase 2: code-reviewer (reviews code)             │     │
│  │    │       → back-pressure: skipped                        │     │
│  │    │       → handoff to dev-qa-tester                      │     │
│  │    │     Phase 3: dev-qa-tester (verifies)                 │     │
│  │    │       → back-pressure: tests=pass                     │     │
│  │    ├── COMPLETE: prd.json passes=true, capture learnings   │     │
│  │    └── RETURN structured JSON to orchestrator              │     │
│  │                                                            │     │
│  │  POST-TASK:                                                │     │
│  │    - Update state.json (completed_tasks++, progress++)     │     │
│  │    - Append to progress.txt                                │     │
│  │    - Desktop: progress bar advances, story goes green      │     │
│  │                                                            │     │
│  │  CONTEXT CHECK: >10 tasks? Stop. Otherwise loop.           │     │
│  └────────────────────────────────────────────────────────────┘     │
│                                                                    │
│  ALL STORIES PASS:                                                 │
│    - Set state → COMPLETED                                         │
│    - Generate retrospective report                                 │
│    - Desktop: project shows "Done" badge, muted styling            │
└──────────────────────────────────────────────────────────────────┘
```

---

## 10. Summary of Deliverables for hq-desktop-projects PRD

Based on this analysis, the child PRD (US-012) should contain stories for:

1. **Fix PRD Rust structs** (P0): Align `Prd`/`PrdFeature` with actual prd.json schema
2. **Fix `get_project_detail`** (P0): Parse prd.json not README.md
3. **Fix `list_projects`** (P0): Check prd.json existence, return story counts
4. **Add execution state reader** (P1): New commands for execution JSON parsing
5. **Add orchestrator watcher** (P1): File watcher for state.json and execution files
6. **Build execution trigger UI** (P1): Run/pause/resume buttons that spawn PTY sessions
7. **Build story kanban board** (P2): Columns by story state, drag-to-reorder
8. **Build execution monitor** (P2): Worker pipeline stepper with back-pressure results
9. **Build progress log viewer** (P2): Real-time progress.txt display
10. **Build dependency graph** (P2): Visual DAG of story dependencies
11. **Parent/child project navigation** (P2): Link epics to child PRDs
12. **Historical execution browser** (P3): Past execution review for completed stories
