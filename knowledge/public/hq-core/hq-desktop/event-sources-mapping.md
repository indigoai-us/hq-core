# HQ Event Sources for Real-Time Desktop Updates

> US-019: Comprehensive map of all file-system events Desktop should react to -- thread creation, worker state changes, project progress, auto-handoff triggers, learning captures, checkpoint saves.

## 1. Current State (Baseline)

Desktop currently has **2 file watchers** and **1 polling mechanism**:

| Mechanism | Target | Events Emitted | Debounce |
|-----------|--------|----------------|----------|
| `start_prd_watcher` | `projects/`, `apps/`, `repos/private/` (recursive) | `prd-changed` (with parsed payload) | 100ms sleep |
| `start_threads_watcher` | `workspace/threads/` (non-recursive) | `threads-changed` (empty payload) | 100ms sleep |
| Polling (useOrchestrator) | `workspace/orchestrator/state.json` | None (2s setInterval when active projects) | N/A |

**Gaps identified:** No watchers for orchestrator state, worker registry, checkpoints, learnings, company data, knowledge changes, or Claude session files.

## 2. Complete Event Source Inventory

### 2.1 Thread Lifecycle Events

| File Path | Change Type | Frequency | Payload |
|-----------|-------------|-----------|---------|
| `workspace/threads/T-*.json` | Create | ~5-20/day during active work | Full thread JSON (thread_id, worker, summary, git state) |
| `workspace/threads/T-*.json` | Modify | ~2-5/day (updates during execution) | Updated thread JSON |
| `workspace/threads/handoff.json` | Modify | ~2-5/day (session transitions) | Handoff context (last_thread, context_notes) |
| `workspace/threads/recent.md` | Modify | ~5-20/day (mirrors thread creation) | Markdown summary |

**Desktop UI triggers:**
- Thread list refresh (threads panel)
- Badge count update on Threads nav item
- Toast: "Thread created: {title}" or "Handoff saved"
- Worker state indicator update if thread references active worker

### 2.2 Project & PRD Events

| File Path | Change Type | Frequency | Payload |
|-----------|-------------|-----------|---------|
| `projects/*/prd.json` | Modify | ~10-50/day (story passes flip, metadata updates) | Full PRD with userStories array |
| `projects/*/prd.json` | Create | ~1-3/week (new projects via /prd) | New PRD |
| `workspace/orchestrator/state.json` | Modify | ~20-100/day during project runs | Full orchestrator state (all projects, states, progress) |
| `workspace/orchestrator/checkouts.json` | Modify | ~5-20/day | File checkout mapping |
| `workspace/orchestrator/*/executions/*.json` | Create/Modify | ~5-20/day per active project | Execution state per story |

**Desktop UI triggers:**
- Story progress bar update (passes count)
- Project state badge change (READY -> IN_PROGRESS -> COMPLETED)
- Kanban board card movement
- Current story indicator update
- Toast: "Story {id} completed" or "Project {name} state changed to {state}"

### 2.3 Worker & Skill Events

| File Path | Change Type | Frequency | Payload |
|-----------|-------------|-----------|---------|
| `workers/registry.yaml` | Modify | Rare (~1-3/month, new workers added) | Full registry YAML |
| `workers/*/worker.yaml` | Modify | Low (~1-5/week, learnings injected) | Updated worker config |
| Thread files with `worker.state` changes | Indirect (via threads) | ~5-20/day | Worker state in thread JSON |

**Desktop UI triggers:**
- Worker list refresh (only on registry.yaml change)
- Worker detail refresh (on worker.yaml change -- learnings added)
- Worker state indicator in threads panel
- Toast: "New worker registered: {id}" (rare)

### 2.4 Checkpoint & Learning Events

| File Path | Change Type | Frequency | Payload |
|-----------|-------------|-----------|---------|
| `workspace/checkpoints/*.json` | Create | ~3-10/day | Checkpoint JSON (task_id, summary, completed_at) |
| `workspace/checkpoints/*.md` | Create | Occasional | Markdown checkpoint |
| `workspace/learnings/*.json` | Create | ~2-10/day (post-task learning capture) | Learning entry (rule, scope, severity) |

**Desktop UI triggers:**
- Checkpoint list refresh
- Badge count on Checkpoints nav item
- Toast: "Checkpoint saved: {summary}"
- Learning captured indicator (subtle, non-interruptive)

### 2.5 Company & Settings Events

| File Path | Change Type | Frequency | Payload |
|-----------|-------------|-----------|---------|
| `companies/manifest.yaml` | Modify | Very rare (~1/month) | Full manifest |
| `companies/*/settings/**` | Create/Modify | Low (~1-5/week) | Credential/config files |
| `companies/*/data/**` | Create/Modify | Variable (data exports) | Data files |
| `companies/*/knowledge/**` | Modify | Low (~1-5/week) | Knowledge content |

**Desktop UI triggers:**
- Company list refresh (manifest.yaml only)
- Company detail refresh (settings/data changes)
- Knowledge tree refresh
- No toast needed (low frequency, background update)

### 2.6 Knowledge Base Events

| File Path | Change Type | Frequency | Payload |
|-----------|-------------|-----------|---------|
| `knowledge/public/**/*.md` | Create/Modify | ~2-10/day | Markdown content |
| `knowledge/private/**/*.md` | Create/Modify | ~1-5/day | Markdown content |
| `knowledge/public/*/INDEX.md` | Modify | ~1-5/day (reindex) | Directory map |

**Desktop UI triggers:**
- Knowledge tree refresh (if browser is open)
- Search index stale indicator
- No toast (high frequency during knowledge work would be noisy)

### 2.7 Claude Session Events

| File Path | Change Type | Frequency | Payload |
|-----------|-------------|-----------|---------|
| `~/.claude/projects/-Users-{your-name}-Documents-HQ/*.jsonl` | Create/Modify | High (continuous during active sessions) | JSONL session log |

**Desktop UI triggers:**
- Active sessions count update
- Session list refresh
- Note: This is OUTSIDE HQ directory -- requires separate watcher scope

### 2.8 Report & Social Draft Events

| File Path | Change Type | Frequency | Payload |
|-----------|-------------|-----------|---------|
| `workspace/reports/**` | Create | ~1-5/day | Report files |
| `workspace/social-drafts/**` | Create/Modify | ~1-5/day | Social content |
| `workspace/content-ideas/**` | Create | ~1-3/day | Content ideas |

**Desktop UI triggers:**
- Reports list refresh
- Badge count on Reports nav item
- Toast: "New report: {filename}"

### 2.9 Auto-Handoff Trigger Events

| Source | Detection Method | Frequency | Payload |
|--------|-----------------|-----------|---------|
| Claude context at 70% remaining | Cannot detect via filesystem -- this is a Claude internal state | Rare (~1-3/day during long sessions) | N/A |
| `/handoff` command execution | Detect via `workspace/threads/handoff.json` modification | ~2-5/day | Handoff JSON |

**Desktop UI triggers:**
- Handoff notification toast: "Session handed off. Context preserved."
- Thread list refresh
- Active session indicator change

## 3. Event Categorization by Frequency

### High Frequency (continuous during active work)
- Terminal PTY output (`pty-output` event -- already handled)
- Claude session JSONL appends (external to HQ)
- Orchestrator state.json updates during `/run-project`

### Medium Frequency (5-50/day)
- Thread creation/modification
- PRD story passes updates
- Execution state updates
- Checkpoint creation
- Learning captures
- Knowledge file edits

### Low Frequency (1-5/day or less)
- Handoff.json updates
- Worker YAML modifications (learnings injected)
- Report/social draft generation
- Company settings changes

### Rare (weekly/monthly)
- Worker registry changes
- Company manifest changes
- New project PRD creation

## 4. File Watcher Strategy

### 4.1 Recommended Watcher Architecture

Replace the current 2-watcher + 1-polling approach with a **unified watcher system** using 6 scoped watchers:

| Watcher ID | Watch Path | Recursive | Debounce | Events |
|------------|-----------|-----------|----------|--------|
| `workspace-watcher` | `workspace/` | Yes | 300ms | threads-changed, checkpoint-changed, learning-captured, handoff-changed, report-created |
| `projects-watcher` | `projects/` | Yes | 500ms | prd-changed (existing), execution-changed |
| `workers-watcher` | `workers/` | Yes | 1000ms | registry-changed, worker-updated |
| `companies-watcher` | `companies/` | No (depth 2) | 1000ms | company-changed, manifest-changed |
| `knowledge-watcher` | `knowledge/` | Yes | 2000ms | knowledge-changed |
| `claude-sessions-watcher` | `~/.claude/projects/...` | No | 1000ms | claude-session-changed |

### 4.2 Debounce Intervals

| Category | Interval | Rationale |
|----------|----------|-----------|
| Workspace (threads, checkpoints) | 300ms | User expects near-instant feedback on thread/checkpoint creation |
| Projects (PRDs, executions) | 500ms | Story completion should reflect quickly, but writes are batched |
| Workers | 1000ms | Changes are rare; no urgency |
| Companies | 1000ms | Changes are rare; no urgency |
| Knowledge | 2000ms | High-volume during editing sessions; avoid thrashing |
| Claude sessions | 1000ms | JSONL appends are very frequent; coalesce aggressively |

### 4.3 Event Coalescing Strategy

For directories with frequent writes, coalesce events by:

1. **Path-based dedup**: Multiple modifications to the same file within debounce window emit only one event
2. **Batch notification**: When >3 events fire in rapid succession (e.g., `/run-project` updating multiple files), coalesce into a single "batch-update" event with affected paths
3. **Payload-aware filtering**: For PRD watcher, only emit if `passes` count actually changed (compare old vs new parsed state)
4. **Directory-level events**: For knowledge/, emit directory-level change events rather than per-file (too noisy)

### 4.4 Watcher State Management

Current issue: `start_threads_watcher` shares `FileWatcherState` mutex with `start_prd_watcher`, meaning they can clobber each other.

Recommended fix: Use a `HashMap<String, RecommendedWatcher>` keyed by watcher ID:

```rust
pub struct WatcherManager {
    watchers: HashMap<String, RecommendedWatcher>,
}
```

This allows independent start/stop of each watcher without interference.

## 5. Desktop UI Update Map

### Event -> UI Component Matrix

| Event | Components to Update | Update Type |
|-------|---------------------|-------------|
| `threads-changed` | ThreadsList, StatsHeader (thread count), NavBadge | Refetch + badge |
| `handoff-changed` | ThreadsList, HandoffBanner, ActiveSessionIndicator | Refetch + toast |
| `prd-changed` | ProjectDetail, StoryBoard, StatsHeader (story progress) | Incremental update |
| `execution-changed` | ProjectDetail, StoryBoard, ExecutionMonitor | Incremental update |
| `orchestrator-changed` | ProjectsList, ProjectDetail, StatsHeader | Refetch (replace polling) |
| `checkpoint-changed` | CheckpointsList, NavBadge | Refetch + badge |
| `learning-captured` | WorkerDetail (learnings section), LearningTimeline | Refetch |
| `registry-changed` | WorkersList, StatsHeader (worker count) | Full refetch |
| `worker-updated` | WorkerDetail | Refetch |
| `company-changed` | CompanyDetail | Refetch |
| `manifest-changed` | CompaniesList, CompanyFilter | Full refetch |
| `knowledge-changed` | KnowledgeTree (if visible) | Lazy refetch |
| `claude-session-changed` | SessionsList, StatsHeader | Refetch |
| `report-created` | ReportsList, NavBadge | Refetch + badge |

### Notification Tiers

| Tier | Behavior | Examples |
|------|----------|---------|
| **Toast** (attention-worthy) | Slide-in notification, auto-dismiss 5s | Thread created, story completed, handoff saved, report generated |
| **Badge** (passive count) | Numeric badge on nav item, persists until viewed | New threads, new checkpoints, new reports |
| **Silent refresh** (background) | UI updates without notification | Knowledge changes, company settings, worker YAML updates |
| **Banner** (persistent alert) | Sticky banner until dismissed/resolved | Auto-handoff warning, project blocked, back-pressure failure |

## 6. Implementation Priority

### Phase 1: Replace Polling with Events (Critical)
1. Fix watcher state management (HashMap instead of shared mutex)
2. Add `orchestrator-watcher` for `workspace/orchestrator/state.json` -- eliminates 2s polling
3. Expand `workspace-watcher` to cover checkpoints and learnings
4. Emit typed payloads (not empty events) for all watchers

### Phase 2: Comprehensive Coverage (High)
5. Add `workers-watcher` for registry and worker.yaml changes
6. Add `companies-watcher` for manifest and company directory changes
7. Add `claude-sessions-watcher` for external session directory
8. Implement event coalescing and debounce

### Phase 3: UI Integration (Medium)
9. Toast notification system
10. Badge count system on nav items
11. Banner system for persistent alerts
12. Event history panel (notification center)

### Phase 4: Advanced (Low)
13. macOS native notifications via `tauri-plugin-notification`
14. Payload-aware diffing (only emit meaningful changes)
15. Event replay for missed updates (Desktop was backgrounded)
