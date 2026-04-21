# Rust Commands vs HQ Structures Audit

Comprehensive audit of every Tauri command in the HQ Desktop Rust backend against actual HQ file structures. Identifies type mismatches, missing data accessors, stale mock data, and new commands needed.

## 1. Command Inventory

### files.rs (26 commands)

| Command | Purpose | Status |
|---------|---------|--------|
| `list_prds` | Scan projects/apps/repos for prd.json files | BROKEN - schema mismatch |
| `start_prd_watcher` | Watch prd.json changes, emit events | BROKEN - same schema issue |
| `stop_prd_watcher` | Stop file watcher | OK |
| `read_dir_tree` | Build file tree from path | OK |
| `read_file_content` | Read file as string (1MB limit) | OK |
| `list_workers` | Parse workers/registry.yaml | PARTIAL - missing fields |
| `read_yaml` | Generic YAML-to-JSON reader | OK |
| `list_threads` | Scan workspace/threads/*.json | PARTIAL - fragile field access |
| `list_checkpoints` | Scan workspace/checkpoints/*.json | OK |
| `read_json` | Generic JSON reader | OK |
| `list_companies` | Scan companies/ directories | PARTIAL - misses manifest data |
| `list_projects` | Scan projects/ directories | STALE - checks README.md not prd.json |
| `list_claude_sessions` | Read .claude session .jsonl files | OK but hardcoded path |
| `get_empire_data` | Combined: workers+threads+companies+projects+sessions | PARTIAL - aggregates broken commands |
| `start_threads_watcher` | Watch workspace/threads/ changes | OK |
| `stop_threads_watcher` | Stop threads watcher | OK |
| `get_worker_detail` | Read worker.yaml for detail view | BROKEN - wrong path + wrong YAML structure |
| `get_company_detail` | List files in company subdirectories | PARTIAL - shallow listing |
| `get_project_detail` | Read project README.md | STALE - should read prd.json |
| `get_hq_stats` | Count workers/projects/threads/checkpoints | PARTIAL - stats incomplete |
| `spawn_worker_skill` | Open Terminal.app with claude /run command | STALE - uses AppleScript |
| `open_terminal_in_hq` | Open Terminal.app in HQ dir | STALE - uses AppleScript |
| `read_dir_tree` | Build recursive file tree | OK |
| `read_file_content` | Read file content | OK |
| `read_yaml` | Read YAML as JSON | OK |
| `read_json` | Read JSON | OK |

### orchestrator.rs (3 commands)

| Command | Purpose | Status |
|---------|---------|--------|
| `get_orchestrator_state` | Read workspace/orchestrator/state.json | OK |
| `get_checkouts_state` | Read workspace/orchestrator/checkouts.json | OK |
| `update_project_state` | Modify project state in state.json | OK |

### terminal.rs (5 commands)

| Command | Purpose | Status |
|---------|---------|--------|
| `spawn_pty` | Create PTY session | OK |
| `write_pty` | Write to PTY | OK |
| `resize_pty` | Resize PTY | OK |
| `kill_pty` | Kill PTY session | OK |
| `list_pty_sessions` | List active PTY sessions | OK |

---

## 2. Type Mismatches: Rust Structs vs Actual HQ Schemas

### 2.1 PRD (CRITICAL)

**Rust struct `Prd`:**
```rust
struct Prd {
    project: String,        // expects "project"
    description: Option<String>,
    stack: Option<String>,
    repo: Option<String>,
    features: Vec<PrdFeature>,  // expects "features"
}
```

**Actual prd.json schema (all 36 projects):**
```json
{
    "name": "...",          // NOT "project"
    "description": "...",
    "branchName": "...",    // NOT "stack"
    "userStories": [...],   // NOT "features"
    "metadata": {...}       // NOT parsed at all
}
```

**Mismatches:**
- `project` field does not exist -- actual field is `name`
- `features` field does not exist -- actual field is `userStories`
- `stack` field does not exist -- actual field is `branchName`
- `repo` field does not exist -- actual field is `metadata.repoPath`
- Entire `metadata` object is ignored (createdAt, goal, successCriteria, qualityGates, repoPath, relatedWorkers, knowledge)

**Rust struct `PrdFeature`:**
```rust
struct PrdFeature {
    id: String,
    title: String,
    description: Option<String>,
    acceptance: Option<Vec<String>>,  // expects "acceptance"
    files: Option<Vec<String>>,
    passes: bool,
}
```

**Actual userStory schema:**
```json
{
    "id": "US-001",
    "title": "...",
    "description": "...",
    "acceptanceCriteria": [...],  // NOT "acceptance"
    "priority": 1,               // NOT parsed
    "passes": false,
    "labels": [...],             // NOT parsed
    "dependsOn": [...],          // NOT parsed
    "notes": "..."               // NOT parsed
}
```

**Mismatches:**
- `acceptance` should be `acceptanceCriteria`
- Missing fields: `priority`, `labels`, `dependsOn`, `notes`
- Some PRDs also have `deferredStories` and `status` at top level

**Impact:** `list_prds` silently returns empty (serde deserialization fails on wrong field names). The entire PRD dashboard is non-functional for real HQ data.

### 2.2 Worker Registry

**Rust struct `WorkerEntry`:**
```rust
struct WorkerEntry {
    id: String,
    path: String,
    r#type: Option<String>,
    status: Option<String>,
    description: Option<String>,
    team: Option<String>,
}
```

**Actual registry.yaml worker entry:**
```yaml
- id: {company}-analyst
  path: workers/private/{company}-analyst/
  type: ResearchWorker
  visibility: private        # NOT parsed
  company: {company}        # NOT parsed
  status: active
  description: "..."
```

**Missing fields:**
- `visibility` (public/private) -- needed for filtering in Desktop
- `company` (company scope) -- critical for company isolation in Desktop

**Impact:** Workers display without company affiliation or visibility scope. Cannot filter workers by company in the UI.

### 2.3 Worker Detail (get_worker_detail)

**Path resolution bug:**
```rust
let worker_path = home.join("Documents").join("HQ").join("workers").join(&worker_id);
```
This looks for `workers/{worker_id}/` but the actual structure is:
- `workers/public/{worker_id}/` (standalone public workers)
- `workers/public/dev-team/{worker_id}/` (dev-team workers)
- `workers/private/{worker_id}/` (private workers)

The command will fail to find any worker.yaml because it doesn't account for the public/private/team hierarchy.

**YAML structure mismatch:**
```rust
// Rust expects flat top-level fields:
detail.name = yaml.get("name")...
detail.r#type = yaml.get("type")...
detail.skills = yaml.get("skills")...  // expects array of {id, name, description}
```

Actual worker.yaml has nested structure:
```yaml
worker:
  id: social-x-user
  name: "{your-name}'s X Worker"
  type: SocialWorker

skills:
  - name: contentidea      # no "id" field
    command: /contentidea   # not parsed
    description: "..."
```

**Mismatches:**
- `name` is at `worker.name`, not root `name`
- `type` is at `worker.type`, not root `type`
- Skills have `name` + `command` + `description` but Rust expects `id` + `name` + `description`
- Worker instructions (long markdown block) not parsed
- Worker execution config not parsed (mode, schedule, max_runtime)
- Worker context paths not parsed
- Worker MCP server config not parsed

### 2.4 ProjectEntry

**Rust struct:**
```rust
struct ProjectEntry {
    name: String,
    path: String,
    has_readme: bool,  // checks README.md existence
}
```

**Reality:** Projects are defined by `prd.json`, not `README.md`. Should check:
- `has_prd: bool` (prd.json existence)
- Story count, completion percentage
- Project state from orchestrator (READY/IN_PROGRESS/COMPLETE)

### 2.5 CompanyEntry

**Rust struct:**
```rust
struct CompanyEntry {
    id: String,
    path: String,
    has_settings: bool,
    has_data: bool,
    has_knowledge: bool,
}
```

**Actual company structure (from manifest.yaml):**
```yaml
{company}:
  repos: [...]
  settings: [stripe, gusto, deel, quickbooks, shopify-partner, linear-voyage]
  workers: [cfo-{company}, {company}-analyst, {product}-deploy]
  knowledge: companies/{company}/knowledge/
  deploy: [...]
  vercel_projects: [...]
  qmd_collections: [{company}, {product}]
```

**Missing data:**
- `repos` list (which repos belong to this company)
- `workers` list (which workers serve this company)
- `settings` list (named settings, not just boolean)
- `deploy` targets
- `vercel_projects`
- `qmd_collections`

---

## 3. Missing Data Accessors

### 3.1 manifest.yaml Parser (HIGH PRIORITY)

No command reads `companies/manifest.yaml`. This is the central source of truth for company-to-resource mapping. Desktop needs:
- Company-scoped repo lists
- Company-scoped worker lists
- Company-scoped settings
- Company-scoped deploy targets
- Company-scoped qmd collections

**Needed command:** `get_manifest` or `get_company_manifest`

### 3.2 Full registry.yaml Parse (HIGH PRIORITY)

`list_workers` parses basic fields but misses `visibility` and `company`. Need either:
- Extend `WorkerEntry` struct with `visibility` and `company` fields
- Add `get_worker_registry_full` command returning complete data

### 3.3 Learnings Reader (MEDIUM)

No command reads `workspace/learnings/*.json`. Desktop should display:
- Learning event log
- Rules injected into workers
- Learning timeline per worker

**Needed command:** `list_learnings`

### 3.4 qmd Search Integration (HIGH PRIORITY)

No Rust command wraps `qmd` CLI. Desktop needs:
- `qmd_search(query, collection, mode)` -- keyword/semantic/hybrid search
- `qmd_collections()` -- list available collections
- `qmd_status()` -- index health

**Needed commands:** `qmd_search`, `list_qmd_collections`

### 3.5 Knowledge Directory Browser (MEDIUM)

No command understands symlink resolution for knowledge directories. Knowledge paths like `knowledge/public/Ralph/` are symlinks to `repos/public/knowledge-ralph/`. Desktop needs:
- Symlink resolution for display
- Knowledge repo git status (clean/dirty)
- INDEX.md hierarchy traversal

**Needed commands:** `resolve_symlink`, `get_knowledge_tree`

### 3.6 Commands/Skills Discovery (LOW)

`useSkills` hook reads `.claude/commands/*.md` via Tauri FS plugin directly (not a Rust command). This works but:
- No caching
- No categorization beyond hardcoded map
- Doesn't discover repo-level commands

### 3.7 Execution State Reader (MEDIUM)

No command reads `workspace/orchestrator/{project}/executions/{task-id}.json`. Desktop should show:
- Current execution progress per story
- Worker phase status
- Handoff context between phases

**Needed command:** `get_execution_state`

### 3.8 HQ Config Reader (HIGH -- per US-002)

No command reads Desktop-specific configuration (HQ path, multi-instance settings). This is covered by the hq-desktop-config child PRD but the Rust layer needs:
- `get_hq_config()` -- read Desktop settings
- `set_hq_config(config)` -- persist settings
- `validate_hq_path(path)` -- check if path is valid HQ

### 3.9 Thread Schema Parser (MEDIUM)

`list_threads` does loose JSON field access. The thread schema (per `thread-schema.md`) has structured fields:
- `git.branch`, `git.current_commit`, `git.dirty`
- `worker.id`, `worker.skill`, `worker.state`
- `metadata.title`, `metadata.project`, `metadata.task_id`
- `files_touched`, `next_steps`

Desktop extracts these loosely. Should have typed struct.

---

## 4. Mock Data Inventory

All mock data lives in `src/lib/tauri.ts` and `src/hooks/use-empire-data.ts`. Used when `isTauri()` returns false (web development mode).

### 4.1 mockWorkers (tauri.ts)

```typescript
// 8 workers with outdated data
{ id: 'cfo-{company}', type: 'FinanceWorker', team: 'finance' }
{ id: 'dev-team', type: 'CodeWorker', team: 'engineering' }
// ...
```

**Issues:**
- Only 8 workers vs 38 actual workers in registry.yaml
- Wrong `type` values: `FinanceWorker`, `MarketingWorker`, `DesignWorker` don't exist in registry (actual types: OpsWorker, CodeWorker, ResearchWorker, SocialWorker, ContentWorker, Library)
- Wrong `team` values: `finance`, `marketing`, `engineering`, `design`, `analytics`, `social` don't exist (actual teams: dev-team, content-team, pr-team, or no team)
- `dev-team` listed as single worker, but it's actually a team of 16 individual workers
- Missing: all dev-team sub-workers, content-team, pr-team, all private workers added since January
- Missing `visibility` and `company` fields

### 4.2 mockThreads (tauri.ts)

```typescript
// 3 threads, stale from January 2026
```

**Issues:**
- Only 3 mock threads vs dozens of actual threads
- References non-existent worker: `hq-desktop-dev`
- Stale content from initial development

### 4.3 mockCompanies (use-empire-data.ts)

```typescript
// 5 companies
{ id: 'band-tbd', ... }  // Does not exist in current HQ
```

**Issues:**
- Lists `band-tbd` which doesn't exist (actual: golden-thread)
- Missing `golden-thread` company
- Incomplete: no manifest data

### 4.4 mockProjects (use-empire-data.ts)

```typescript
// 18 projects
{ name: 'band-launch', ... }
{ name: 'band-name-decision', ... }
```

**Issues:**
- Lists 18 projects vs 47 actual projects in orchestrator state
- Contains deleted projects: `band-launch`, `band-name-decision`, `mobile-agent-control`, `social-presence-strategy`, `personal-website`, etc.
- Missing most current projects
- All have `has_readme: true` -- should check `prd.json`

### 4.5 mockProjects (tauri.ts -- orchestrator mock)

```typescript
// 3 projects for orchestrator view
```

**Issues:**
- Only 3 mock orchestrator projects vs 47 actual
- `prdPath` references README.md not prd.json
- Missing many orchestrator fields: `startedAt`, `currentStory`, `blockedBy`, `error`, `parentProject`, `parentStory`

### 4.6 mockStats (tauri.ts)

```typescript
{ worker_count: 8, active_worker_count: 8, project_count: 18, thread_count: 3, checkpoint_count: 0 }
```

**Issues:**
- All counts are stale (actual: 38 workers, 47+ projects, many threads)

### 4.7 mockFileTree (tauri.ts)

**Issues:**
- References `apps` and `data` directories in HQ_DIRECTORIES array (`use-hq-files.ts`) but neither exists at HQ root
- References `mr-burns` directory which doesn't exist
- Missing `settings` from file tree (it exists under companies, not HQ root)
- Tree is minimal snapshot from January

### 4.8 mockPRDContent (tauri.ts)

```typescript
// Raw markdown string mimicking a README-style PRD
```

**Issues:**
- This is markdown format, but PRDs are actually JSON (prd.json)
- Content is fabricated (not matching any real PRD)

---

## 5. Priority-Ranked New Rust Commands Needed

### P0 -- Critical (blocks basic functionality)

1. **Fix `list_prds` / `parse_prd`**: Update `Prd` and `PrdFeature` structs to match actual prd.json schema (`name` not `project`, `userStories` not `features`, `acceptanceCriteria` not `acceptance`, add `metadata`, `priority`, `labels`, `dependsOn`)

2. **Fix `get_worker_detail`**: Fix path resolution to search `workers/public/`, `workers/public/dev-team/`, `workers/private/` using registry.yaml path field. Fix YAML parsing to read nested `worker.name`, `worker.type` and correct `skills` structure.

3. **Fix `list_projects`**: Check for `prd.json` instead of `README.md`. Return story count and completion percentage.

4. **Add `get_manifest`**: Parse `companies/manifest.yaml` and return full company-to-resource mapping (repos, workers, settings, deploy targets, qmd collections).

### P1 -- High (enables key Desktop features)

5. **Extend `WorkerEntry`**: Add `visibility` and `company` fields to registry parsing.

6. **Add `qmd_search`**: Wrap qmd CLI for keyword/semantic/hybrid search. Accept query string, collection name, mode, result count.

7. **Add `list_qmd_collections`**: Return available qmd collections with index stats.

8. **Add `get_hq_config` / `set_hq_config`**: Read/write Desktop configuration (HQ path, preferences). Covered by hq-desktop-config PRD.

9. **Fix `list_companies`**: Enrich with manifest.yaml data (repo count, worker count, settings list).

### P2 -- Medium (enables enhanced views)

10. **Add `list_learnings`**: Read `workspace/learnings/*.json` and return learning events.

11. **Add `get_execution_state`**: Read execution tracking from `workspace/orchestrator/{project}/executions/`.

12. **Add `resolve_symlink`**: Resolve knowledge directory symlinks to actual repo paths.

13. **Improve `list_threads`**: Parse full thread schema with typed struct (git state, worker details, metadata).

14. **Fix `get_project_detail`**: Read prd.json not README.md. Return parsed PRD with stories, metadata, progress.

### P3 -- Low (polish and completeness)

15. **Remove `spawn_worker_skill` / `open_terminal_in_hq`**: Replace AppleScript Terminal.app with PTY-based execution (terminal.rs already supports this via `spawn_pty`).

16. **Add `get_knowledge_tree`**: Build knowledge directory tree with symlink awareness and INDEX.md parsing.

17. **Add file watcher expansion**: Watch more directories beyond prd.json and threads (worker state, learnings, orchestrator state).

18. **Add `list_commands`**: Structured command discovery (currently done via FS plugin in useSkills hook).

---

## 6. Summary

### By severity:
- **BROKEN (3):** list_prds, start_prd_watcher, get_worker_detail
- **STALE (3):** list_projects, get_project_detail, spawn_worker_skill + open_terminal_in_hq
- **PARTIAL (5):** list_workers, list_threads, list_companies, get_hq_stats, get_empire_data
- **OK (15):** All terminal.rs commands, orchestrator.rs commands, generic readers

### Mock data:
- **7 mock datasets** across tauri.ts and use-empire-data.ts, all stale
- Mock data references deleted companies (`band-tbd`), non-existent worker types, wrong field names
- Every mock needs full replacement with current HQ state

### New commands needed: **14** (4 critical fixes + 4 high + 4 medium + 2 low)
### Fields to add to existing structs: **8** across 4 structs
