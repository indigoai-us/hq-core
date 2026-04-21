# Worker System to Desktop UX Mapping

> US-007: Full worker lifecycle, skill execution flow, MCP server integration points, and learning injection paths as they should appear in HQ Desktop.

---

## 1. Worker YAML Schema (Full Reference)

Every worker is defined by a `worker.yaml` file. The schema has required and optional sections that vary by worker type.

### 1.1 Core Identity Block

```yaml
worker:
  id: string              # Unique ID (matches registry.yaml)
  name: string             # Human-readable name
  type: WorkerType         # OpsWorker | CodeWorker | ResearchWorker | SocialWorker | ContentWorker
  version: string          # Schema version
  company?: string         # Company scope (private workers only)
  team?: string            # Team membership (e.g. "dev-team")
  description?: string     # Brief description (also in registry.yaml)
```

**Worker types in production:**

| Type | Count | Examples |
|------|-------|---------|
| CodeWorker | 16 | architect, frontend-dev, backend-dev, codex-coder |
| OpsWorker | 10 | cfo-{company}, infobip-admin, qa-tester, pretty-mermaid |
| ContentWorker | 5 | content-brand, content-sales,  |
| ResearchWorker | 2 | {company}-analyst, pr-monitor |
| SocialWorker | 1 | x-user |
| Library | 2 | content-shared, pr-shared |

### 1.2 Identity Block (Optional)

```yaml
identity:
  persona?: string         # Persona key for voice/style
  voice_guide?: string     # Path to voice guide file
  purpose?: string         # Extended purpose description
```

Used by content/social workers that need a specific voice.

### 1.3 Execution Block

```yaml
execution:
  mode: string             # on_demand | scheduled | on-demand
  schedule?: string        # Cron expression (scheduled mode only)
  max_runtime: string      # e.g. "10m", "20m"
  retry_attempts: number   # Max retries on failure
  spawn_method?: string    # task_tool | inline (default: inline)
  spawn_per_task?: boolean # Whether to spawn sub-agent per task
```

### 1.4 Context Block

```yaml
context:
  base:                    # Always-loaded files/dirs
    - workers/{path}/
    - knowledge/{path}/
  dynamic:                 # Conditionally loaded
    - pattern: "{target_repo}/src/"
      when: always
  exclude:                 # Never loaded
    - node_modules/
    - dist/
```

### 1.5 Skills Block (Two Formats)

**Format A: Structured skills (dev-team workers)**
```yaml
skills:
  - id: generate-code
    file: skills/generate-code.md
  - id: implement-feature
    file: skills/implement-feature.md
```

**Format B: Command-mapped skills (private/social workers)**
```yaml
skills:
  - name: contentidea
    command: /contentidea
    description: "Generate content suite from raw idea"
  - name: suggestposts
    command: /suggestposts
    description: "Research and suggest posts"
```

**Format C: Capability list (product-planner)**
```yaml
skills:
  installed:
    - api-design-principles
    - typescript-advanced-types
  capabilities:
    - Product requirements documentation
    - Technical specification writing
```

### 1.6 Verification Block

```yaml
verification:
  pre_execute?:            # Checks before running
    - string               # Human-readable check
  post_execute:            # Back-pressure checks
    - check: typescript
      command: npm run typecheck
    - check: lint
      command: npm run lint
    - check: test
      command: npm test
  approval_required: boolean
  human_checkpoints?:      # Points requiring human approval
    - before_feature_implementation
    - on_breaking_changes
```

### 1.7 MCP Server Block

```yaml
mcp:
  server:
    command: node
    args: [dist/mcp-server.js]
    cwd: workers/public/dev-team/{worker-id}
  tools:
    - tool_name_1
    - tool_name_2
```

### 1.8 State Machine Block

```yaml
state_machine:
  enabled: true
  max_retries: 1
  hooks:
    post_execute:
      - auto_checkpoint
      - log_metrics
    on_error:
      - log_error
      - checkpoint_error_state
```

### 1.9 Integrations Block (Optional)

```yaml
integrations:
  x:
    client: workers/private/x-user/src/x-client.ts
    config: companies/personal/settings/x/config.json
```

### 1.10 Output Block

```yaml
output:
  destination: workspace/reports/{area}/
  format: markdown | json | both
  naming: "{date}-{skill}.{ext}"
```

### 1.11 Tasks Block

```yaml
tasks:
  source: projects/{project}/prd.json
  format: prd | simple
  one_at_a_time: true
```

### 1.12 Reporting Block (Optional)

```yaml
reporting:
  on_complete:
    - log_generation
    - extract_learnings
  metrics:
    - generation_time
    - files_created
    - back_pressure_pass_rate
```

### 1.13 Instructions Block

```yaml
instructions: |
  # Worker Name

  Extended instructions including:
  - Role description
  - Skills table
  - Patterns to follow
  - Human-in-the-loop rules

  ## Learnings
  (Accumulated rules injected by /learn)
```

The `instructions` field is a markdown string that also serves as the accumulation point for learned rules. `/learn` injects new rules directly into this block.

---

## 2. Worker State Machine

### 2.1 States and Transitions

```
                  skill_requested
        Idle ─────────────────────► Loading
                                       │
                              context_loaded
                                       │
                                       ▼
                                   Planning
                                       │
                                  plan_ready
                                       │
                                       ▼
                                  Executing
                                   │      │
                          exec_done│      │exec_failed
                                   │      │
                                   ▼      ▼
                              Verifying  Error ◄── verify_failed
                                   │      │  ▲
                          verify_pass│    retry│
                                   │      │
                                   ▼      │
                               PostHook   │
                                   │      │
                          hook_done │      │
                                   ▼      │
                              Completed   │
                                          │
                               max_retries│
                                          ▼
                              Completed (with error)
```

### 2.2 State Definitions

| State | Description | Desktop Should Show |
|-------|-------------|---------------------|
| `idle` | Worker ready, no active task | Gray dot, "idle" label |
| `loading` | Loading context files (worker.yaml, knowledge) | Pulsing blue dot, "loading context..." |
| `planning` | Analyzing task, determining approach | Pulsing blue dot, "planning..." |
| `executing` | Running skill logic | Animated green dot, "executing {skill}..." |
| `verifying` | Running back-pressure checks (typecheck, lint, test) | Pulsing yellow dot, "verifying..." with check list |
| `post_hook` | Auto-checkpoint, metrics logging | Brief flash, "saving state..." |
| `completed` | Skill finished successfully | Green check, "completed" with timestamp |
| `error` | Recoverable error, may retry | Red dot, error message, retry count |

### 2.3 State Persistence

Worker state is persisted in thread JSON files at `workspace/threads/`:

```json
{
  "worker": {
    "id": "cfo-{company}",
    "skill": "mrr",
    "state": "completed",
    "started_at": "2026-01-23T14:30:52.000Z",
    "completed_at": "2026-01-23T14:35:00.000Z",
    "error": null
  }
}
```

Desktop currently derives worker state by scanning threads and taking the most recent state per worker (in `use-empire-data.ts`). This is **poll-based**, not event-driven -- there is no real-time state update mechanism.

---

## 3. Skill Execution Flow: Desktop Trigger to Completion

### 3.1 Current Flow (Desktop → Claude Code)

```
┌──────────────────────────────────────────────────────────────────────┐
│ Desktop UI                                                          │
│                                                                     │
│  1. User clicks worker → navigates to worker-detail.tsx             │
│  2. Skills listed from get_worker_detail Rust command                │
│  3. User enters optional args, clicks "Run"                         │
│  4. useSkillRunner.runSkill() called                                │
│     │                                                               │
│     ├─ Tauri mode: spawn_pty → PTY session created                  │
│     │  │                                                            │
│     │  └─ write_pty: types `claude "/run {worker}:{skill} {args}"\n`│
│     │     into PTY                                                  │
│     │                                                               │
│     └─ Web mode: creates mock session in session-store              │
│                                                                     │
│  5. Session added to session-store (Zustand)                        │
│     - type: 'worker'                                                │
│     - workerId, skillId, company (inferred)                         │
│     - status: 'running'                                             │
│                                                                     │
│  6. Terminal panel shows PTY output                                 │
│                                                                     │
│  7. No completion detection — user must manually observe            │
└──────────────────────────────────────────────────────────────────────┘
```

### 3.2 Claude Code Side (Inside PTY)

```
┌──────────────────────────────────────────────────────────────────────┐
│ Claude Code (inside PTY session)                                     │
│                                                                      │
│  1. /run {worker} {skill} received                                   │
│     │                                                                │
│  2. Load worker config                                               │
│     ├─ Read workers/registry.yaml → find worker path                 │
│     ├─ Read workers/{path}/worker.yaml → full config                 │
│     └─ Load context files listed in context.base                     │
│     │                                                                │
│     │  STATE: idle → loading → planning                              │
│     │                                                                │
│  3. Load skill definition                                            │
│     ├─ Format A: Read workers/{path}/skills/{skill}.md               │
│     └─ Format B: Execute command mapped in worker.yaml               │
│     │                                                                │
│  4. Execute skill instructions                                       │
│     │  STATE: planning → executing                                   │
│     │                                                                │
│     ├─ Read knowledge files as needed                                │
│     ├─ Perform work (generate content, write code, analyze data)     │
│     └─ Produce output files                                          │
│     │                                                                │
│  5. Run verification (back-pressure)                                 │
│     │  STATE: executing → verifying                                  │
│     │                                                                │
│     ├─ npm run typecheck                                             │
│     ├─ npm run lint                                                  │
│     ├─ npm test                                                      │
│     └─ Custom checks from verification.post_execute                  │
│     │                                                                │
│  6. PostToolsHook                                                    │
│     │  STATE: verifying → post_hook                                  │
│     │                                                                │
│     ├─ auto_checkpoint: write thread to workspace/threads/           │
│     └─ log_metrics: append to workspace/metrics/metrics.jsonl        │
│     │                                                                │
│  7. Complete                                                         │
│     │  STATE: post_hook → completed                                  │
│     │                                                                │
│     └─ Thread file written triggers threads_watcher event            │
│        → Desktop receives "threads-changed" Tauri event              │
│        → useEmpireData re-fetches all data                           │
│        → Worker state updated in UI                                  │
└──────────────────────────────────────────────────────────────────────┘
```

### 3.3 Ideal Flow (What Desktop Should Do)

```
┌──────────────────────────────────────────────────────────────────────┐
│ Ideal Desktop Worker Execution UX                                    │
│                                                                      │
│  TRIGGER                                                             │
│  ├─ Worker detail view → skill list → Run button                     │
│  ├─ Command palette → "/run {worker} {skill}"                        │
│  └─ Project execution → orchestrator triggers worker sequence        │
│                                                                      │
│  PARAMETER COLLECTION                                                │
│  ├─ Skill interface.inputs defines required parameters               │
│  ├─ Desktop renders typed input fields (string, number, date, path)  │
│  ├─ Default values pre-filled from skill schema                      │
│  └─ Validation before submission                                     │
│                                                                      │
│  EXECUTION MONITORING                                                │
│  ├─ Real-time state transitions displayed (loading→executing→...)    │
│  ├─ Terminal output streamed in embedded or floating panel            │
│  ├─ Back-pressure check results shown as checklist                   │
│  │   ☑ typecheck: pass                                              │
│  │   ☑ lint: pass                                                   │
│  │   ☐ test: running...                                             │
│  └─ Error state with retry option                                    │
│                                                                      │
│  COMPLETION                                                          │
│  ├─ Green completion badge                                           │
│  ├─ Summary from thread's conversation_summary                       │
│  ├─ Files touched listed with quick-open links                       │
│  ├─ Thread linkable (click to view full thread detail)               │
│  └─ Toast notification: "{worker} completed {skill}"                 │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 4. Worker Data Points Desktop Needs to Display

### 4.1 Worker List View

| Data Point | Source | Current Status |
|-----------|--------|----------------|
| Worker ID | registry.yaml `id` | Available via `list_workers` |
| Worker type | registry.yaml `type` | Available |
| Status (active/inactive) | registry.yaml `status` | Available |
| Team membership | registry.yaml `team` | Available |
| Description | registry.yaml `description` | Available |
| **Visibility (public/private)** | registry.yaml `visibility` | **MISSING from Rust struct** |
| **Company scope** | registry.yaml `company` | **MISSING from Rust struct** |
| Current execution state | threads (latest per worker) | Available (poll-based, not real-time) |
| Skill count | worker.yaml `skills` | Available only in detail view |

### 4.2 Worker Detail View

| Data Point | Source | Current Status |
|-----------|--------|----------------|
| Worker name | worker.yaml `worker.name` | **BROKEN** -- Rust reads root `name`, not `worker.name` |
| Worker type | worker.yaml `worker.type` | **BROKEN** -- same nesting issue |
| Description | worker.yaml `worker.description` or `description` | Partial |
| Execution mode | worker.yaml `execution.mode` | **NOT PARSED** |
| Schedule (if scheduled) | worker.yaml `execution.schedule` | **NOT PARSED** |
| Max runtime | worker.yaml `execution.max_runtime` | **NOT PARSED** |
| Skills list | worker.yaml `skills` | **BROKEN** -- expects `{id, name, desc}`, actual varies |
| Context paths | worker.yaml `context.base` | **NOT PARSED** |
| Verification checks | worker.yaml `verification.post_execute` | **NOT PARSED** |
| MCP server config | worker.yaml `mcp` | **NOT PARSED** |
| Instructions (markdown) | worker.yaml `instructions` | **NOT PARSED** |
| Learnings (within instructions) | worker.yaml `instructions` Learnings section | **NOT PARSED** |
| Recent threads | workspace/threads/*.json filtered by worker_id | Available (limited to 5) |
| Thread states | threads[].worker.state | Available |
| **Integrations** | worker.yaml `integrations` | **NOT PARSED** |
| **Output destination** | worker.yaml `output.destination` | **NOT PARSED** |
| **Task source** | worker.yaml `tasks.source` | **NOT PARSED** |
| **State machine config** | worker.yaml `state_machine` | **NOT PARSED** |

### 4.3 Skill Detail / Execution View

| Data Point | Source | Current Status |
|-----------|--------|----------------|
| Skill ID | worker.yaml skills[].id or skills[].name | Partial |
| Skill name | worker.yaml skills[].name | Partial |
| Description | worker.yaml skills[].description | Partial |
| **Input parameters** | skill file or worker.yaml interface.inputs | **NOT PARSED** |
| **Output type** | skill file interface.outputs | **NOT PARSED** |
| **Mutating flag** | skill file mutating | **NOT PARSED** |
| **Skill verification** | skill file verification | **NOT PARSED** |
| **Skill file content** | workers/{path}/skills/{skill}.md | **NOT PARSED** |
| Execution status | session-store + thread state | Partial |

### 4.4 Learning View

| Data Point | Source | Current Status |
|-----------|--------|----------------|
| **Learning event log** | workspace/learnings/*.json | **NOT PARSED** |
| **Learned rules in worker** | worker.yaml instructions → Learnings section | **NOT PARSED** |
| **Global learned rules** | CLAUDE.md → Learned Rules section | Not applicable to Desktop |
| **Learning injection timestamp** | learning event JSON | **NOT PARSED** |
| **Learning severity** | learning event JSON | **NOT PARSED** |
| **Learning scope** | learning event JSON | **NOT PARSED** |

### 4.5 Metrics / Performance View

| Data Point | Source | Current Status |
|-----------|--------|----------------|
| **Execution count per worker** | workspace/threads (count by worker_id) | Derivable but not computed |
| **Success/failure rate** | threads (state: completed vs error) | Derivable but not computed |
| **Average runtime** | threads (completed_at - started_at) | Derivable but not computed |
| **Back-pressure pass rate** | execution JSON back_pressure field | **NOT COLLECTED** |
| **Most-used skills** | threads (count by worker.skill) | Derivable but not computed |
| **Recent errors** | threads where state=error | Derivable but not computed |

---

## 5. MCP Integration Analysis

### 5.1 Current MCP Server Declarations

Several workers declare MCP servers in their `worker.yaml`:

| Worker | MCP Server | Tools Exposed |
|--------|------------|---------------|
| architect | dist/mcp-server.js | system_design, api_design, code_review_plan, refactor_plan |
| frontend-dev | dist/mcp-server.js | create_component, create_page, fix_ui_bug, add_form |
| codex-coder | codex-engine dist/mcp-server.js | codex_generate |
| codex-reviewer | codex-engine dist/mcp-server.js | codex_review |
| codex-debugger | codex-engine dist/mcp-server.js | codex_debug |

### 5.2 How MCP Servers Currently Work

MCP servers in worker.yaml are consumed by **Claude Code** during `/run` execution. When Claude Code executes a worker skill, it can connect to the worker's MCP server to access specialized tools. The server is started as a child process:

```yaml
mcp:
  server:
    command: node           # Process to spawn
    args: [dist/mcp-server.js]  # Arguments
    cwd: workers/public/dev-team/architect  # Working directory
```

Claude Code connects via stdio transport (standard MCP pattern).

### 5.3 Can Desktop Act as MCP Client?

**Technical feasibility:** Yes, with caveats.

**Architecture options:**

**Option A: Desktop as Direct MCP Client**
```
Desktop (Tauri/Rust) → MCP stdio transport → Worker MCP Server (Node.js)
```

- Tauri can spawn child processes via `std::process::Command`
- Rust MCP client libraries exist (e.g., `mcp-rs-template`)
- Desktop could call worker tools directly without going through Claude Code
- **Pro:** Direct programmatic access to worker capabilities
- **Con:** Worker MCP servers currently assume Claude Code as consumer; tools return structured data meant for LLM consumption, not UI rendering
- **Con:** No authentication/authorization layer -- MCP servers are trusted local processes

**Option B: Desktop as MCP Client via Proxy**
```
Desktop → HTTP/WebSocket → MCP Proxy → Worker MCP Server
```

- A lightweight proxy translates between Desktop and MCP servers
- Enables connection management, request queuing, error handling
- **Pro:** Cleaner separation, can add auth/logging
- **Con:** Additional infrastructure to maintain

**Option C: Desktop Observes, Claude Code Executes**
```
Desktop → spawn PTY → Claude Code → MCP Server
Desktop ← file watcher ← thread JSON (results)
```

- Current approach: Desktop triggers via PTY, observes via file watchers
- Desktop never directly talks to MCP servers
- **Pro:** Simplest, leverages existing infrastructure
- **Con:** No real-time insight into MCP tool calls, no programmatic result access

### 5.4 Recommendation

**Phase 1 (near-term): Option C -- Observe and Trigger**

Desktop continues to trigger worker execution via PTY/Claude Code and observes results via file watchers. Enhance observation:
- Parse thread JSON for richer state display
- Add worker state file watcher (beyond just threads)
- Show MCP tools as informational in worker detail (not invocable)

**Phase 2 (future): Option A -- Direct MCP Client**

When worker MCP servers mature, Desktop could directly invoke tools:
- Start MCP server as subprocess from Rust
- Use Rust MCP client to call tools
- Render results in Desktop UI
- Requires: standardized response formats, UI renderers per output type

### 5.5 MCP Data Desktop Should Display (Regardless of Client Strategy)

| Data Point | Purpose |
|-----------|---------|
| MCP server availability | Show whether worker has MCP capabilities |
| Tool list with descriptions | Let user understand what tools are available |
| Tool input schemas | Show parameters each tool accepts |
| Tool invocation history | Track which tools were called during execution |
| Server health status | Indicate if MCP server process is running |

---

## 6. Learning Injection Paths

### 6.1 How Learnings Work

```
┌─────────────────────────────────────────────────────────────────────┐
│ Learning Lifecycle                                                   │
│                                                                      │
│  CAPTURE                                                             │
│  ├─ /learn command (manual or auto after task execution)             │
│  ├─ /remember (user corrections, always Tier 1)                     │
│  └─ Auto-Learn triggers (worker completion, back-pressure failure)  │
│                                                                      │
│  CLASSIFY & ROUTE                                                    │
│  ├─ Worker-scoped → inject into worker.yaml instructions: block     │
│  ├─ Command-scoped → inject into command .md ## Rules section       │
│  ├─ Knowledge-scoped → inject into relevant knowledge file          │
│  └─ Global → inject into CLAUDE.md ## Learned Rules                 │
│                                                                      │
│  PERSIST                                                             │
│  ├─ Rule text injected into target file (the source of truth)       │
│  └─ Event logged to workspace/learnings/*.json (audit trail)        │
│                                                                      │
│  CONSUME                                                             │
│  ├─ Claude Code reads CLAUDE.md on session start (global rules)     │
│  ├─ /run reads worker.yaml (worker rules loaded with instructions)  │
│  └─ Commands read their own .md file (command rules auto-loaded)    │
└─────────────────────────────────────────────────────────────────────┘
```

### 6.2 Learning Data Structures

**Event log entry** (`workspace/learnings/*.json`):
```json
{
  "id": "L-20260211-143000",
  "timestamp": "2026-02-11T14:30:00.000Z",
  "task_id": "US-007",
  "project": "hq-desktop-epics",
  "source": "task-completion",
  "severity": "medium",
  "scope": "worker:architect",
  "rule": "Always check worker.yaml nesting before parsing",
  "injected_to": "workers/public/dev-team/architect/worker.yaml",
  "workers_used": ["architect"],
  "back_pressure_failures": [],
  "patterns_discovered": []
}
```

**Learned rules in worker.yaml** (inside `instructions:` block):
```yaml
instructions: |
  # Worker Name

  ... main instructions ...

  ## Learnings
  - Always check worker.yaml nesting before parsing
  - Use registry.yaml path field for worker location
```

### 6.3 What Desktop Should Display

| View | Content | Source |
|------|---------|--------|
| Worker detail → Learnings tab | Rules injected into this worker's instructions | Parse `instructions:` for `## Learnings` section |
| Global learnings view | All learning events across workers | Read `workspace/learnings/*.json` |
| Learning timeline | Chronological list of learning captures | Sort learning events by timestamp |
| Per-worker learning count | Badge showing number of learned rules | Count rules in worker's Learnings section |
| Learning severity distribution | Breakdown by high/medium/low | Aggregate from event log |

---

## 7. Worker Registry Relationship Map

### 7.1 Registry → Worker → Skills → Threads

```
workers/registry.yaml
  │
  ├─ WorkerEntry (id, path, type, status, team, visibility, company)
  │     │
  │     └─ workers/{path}/worker.yaml
  │           │
  │           ├─ worker: {id, name, type, version, company}
  │           ├─ execution: {mode, schedule, max_runtime, retry}
  │           ├─ context: {base[], dynamic[], exclude[]}
  │           ├─ skills: [{id, name, command, description, file}]
  │           │     │
  │           │     └─ workers/{path}/skills/{skill}.md
  │           │           ├─ YAML frontmatter: {interface, verification, mutating}
  │           │           └─ Markdown body: execution instructions
  │           │
  │           ├─ verification: {pre_execute, post_execute[], approval_required}
  │           ├─ mcp: {server: {command, args, cwd}, tools[]}
  │           ├─ state_machine: {enabled, max_retries, hooks}
  │           ├─ output: {destination, format, naming}
  │           ├─ tasks: {source, format, one_at_a_time}
  │           └─ instructions: |
  │                 markdown with ## Learnings section
  │
  └─ workspace/threads/*.json
        │
        └─ ThreadSummary
              ├─ worker.id → links back to WorkerEntry
              ├─ worker.skill → links to skill
              ├─ worker.state → current FSM state
              └─ conversation_summary, files_touched, next_steps
```

### 7.2 Company → Workers Mapping

```
companies/manifest.yaml
  │
  ├─ {company}:
  │     workers: [cfo-{company}, {company}-analyst, {product}-deploy, infobip-admin, lr-qa, {company}-gtm]
  │
  │
  ├─ {company}:
  │     workers: [cmo-brand]
  │
  ├─ personal:
  │     workers: [x-user, invoices]
  │
  └─ (public workers: dev-team/*, content-team/*, qa-tester, etc.)
       → company-agnostic, inherit active company from invocation
```

---

## 8. Execution Flow Diagrams

### 8.1 Simple Skill Execution (/run worker skill)

```
User          Desktop              PTY/Claude Code         File System
 │               │                       │                      │
 │  Click Run    │                       │                      │
 │──────────────►│                       │                      │
 │               │  spawn_pty()          │                      │
 │               │──────────────────────►│                      │
 │               │  write_pty(claude...) │                      │
 │               │──────────────────────►│                      │
 │               │  addSession(store)    │                      │
 │               │                       │                      │
 │               │                       │ read registry.yaml   │
 │               │                       │─────────────────────►│
 │               │                       │ read worker.yaml     │
 │               │                       │─────────────────────►│
 │               │                       │ read skill file      │
 │               │                       │─────────────────────►│
 │               │                       │                      │
 │               │                       │ [execute skill]      │
 │               │                       │                      │
 │               │                       │ run verification     │
 │               │                       │                      │
 │               │                       │ write thread.json    │
 │               │                       │─────────────────────►│
 │               │                       │                      │
 │               │  threads-changed evt  │                      │
 │               │◄──────────────────────────────────────────────│
 │               │  re-fetch empire data │                      │
 │               │                       │                      │
 │  UI updates   │                       │                      │
 │◄──────────────│                       │                      │
```

### 8.2 Orchestrated Execution (/execute-task → multi-worker)

```
Orchestrator         Worker 1 (Sub-Agent)     Worker 2 (Sub-Agent)     File System
     │                       │                       │                      │
     │ read prd.json         │                       │                      │
     │─────────────────────────────────────────────────────────────────────►│
     │                       │                       │                      │
     │ spawn worker 1        │                       │                      │
     │──────────────────────►│                       │                      │
     │                       │ load context          │                      │
     │                       │─────────────────────────────────────────────►│
     │                       │ execute skill         │                      │
     │                       │ run back-pressure     │                      │
     │                       │                       │                      │
     │ receive output JSON   │                       │                      │
     │◄──────────────────────│                       │                      │
     │                       │                       │                      │
     │ write handoff context │                       │                      │
     │─────────────────────────────────────────────────────────────────────►│
     │                       │                       │                      │
     │ spawn worker 2 (with handoff)                 │                      │
     │──────────────────────────────────────────────►│                      │
     │                       │                       │ load context + handoff│
     │                       │                       │─────────────────────►│
     │                       │                       │ execute skill        │
     │                       │                       │ run back-pressure    │
     │                       │                       │                      │
     │ receive output JSON                           │                      │
     │◄─────────────────────────────────────────────│                      │
     │                       │                       │                      │
     │ update prd.json (passes: true)                │                      │
     │─────────────────────────────────────────────────────────────────────►│
     │                       │                       │                      │
     │ write execution state │                       │                      │
     │─────────────────────────────────────────────────────────────────────►│
```

---

## 9. Gaps Between Current Desktop and Full Worker System

### 9.1 Critical Gaps (Block Core Worker UX)

| Gap | Impact | Fix Required |
|-----|--------|--------------|
| `get_worker_detail` path resolution broken | Cannot load any worker detail | Fix path lookup using registry.yaml path field |
| `get_worker_detail` YAML parsing wrong | Skills, name, type all missing | Parse nested `worker.name`, `worker.type`, handle both skill formats |
| Missing `visibility` and `company` in WorkerEntry | Cannot filter workers by company or scope | Extend Rust struct + registry parsing |
| No skill interface parsing | Cannot render typed input fields for skill parameters | New Rust command or extend detail |

### 9.2 High Gaps (Needed for Useful Worker Views)

| Gap | Impact | Fix Required |
|-----|--------|--------------|
| No execution state reader | Cannot show current worker pipeline progress | New `get_execution_state` command |
| No learning viewer | Cannot display accumulated rules or learning history | New `list_learnings` command + instruction parser |
| Poll-based state updates | Worker state changes not reflected in real-time | File watcher for worker-related paths |
| No MCP server info | Cannot display tool capabilities | Parse MCP block from worker.yaml |
| Session completion detection | Desktop doesn't know when PTY skill execution finishes | Parse PTY output or watch thread creation |

### 9.3 Medium Gaps (Enhanced Worker Experience)

| Gap | Impact | Fix Required |
|-----|--------|--------------|
| No metrics aggregation | Cannot show performance dashboard | Compute from threads + execution states |
| No skill file reader | Cannot show full skill documentation | Read skill .md files from worker path |
| Instructions not rendered | Worker's full instructions not viewable | Parse and render instructions markdown |
| No execution history | Cannot browse past runs with filters | Query threads by worker_id with date range |
| No error analysis | Cannot identify recurring failure patterns | Aggregate error states from execution JSONs |

---

## 10. Summary: What Desktop Needs to Build

### 10.1 Rust Backend Changes

1. **Fix `get_worker_detail`** -- path resolution + YAML parsing (Critical, US-003 P0 item)
2. **Extend `WorkerEntry`** -- add `visibility`, `company` fields
3. **Add `get_worker_skills`** -- parse skill files from worker directory
4. **Add `list_learnings`** -- read workspace/learnings/*.json
5. **Add `get_execution_state`** -- read execution tracking files
6. **Add worker-related file watchers** -- watch registry.yaml, worker state changes

### 10.2 TypeScript Frontend Changes

1. **Update `WorkerEntry` type** -- add visibility, company
2. **Update `WorkerDetail` type** -- add execution config, instructions, MCP, integrations, learnings
3. **Create `SkillDetail` type** -- interface inputs/outputs, mutating, verification
4. **Create `LearningEvent` type** -- match event log JSON schema
5. **Create `WorkerMetrics` type** -- computed from threads
6. **Add `useWorkerExecution` hook** -- track real-time execution state
7. **Add `useWorkerLearnings` hook** -- fetch and display learnings

### 10.3 UI Components to Build/Extend

1. **workers-drill.tsx** -- add company/visibility filters, group by company
2. **worker-detail.tsx** -- full tabbed interface (Overview, Skills, Activity, Learnings, Metrics)
3. **skill-runner.tsx** -- typed parameter inputs from skill interface, execution progress
4. **execution-monitor.tsx** -- real-time state machine visualization
5. **learning-viewer.tsx** -- timeline of learning events, injected rules display
6. **worker-metrics.tsx** -- execution count, success rate, runtime stats
