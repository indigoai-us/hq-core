# Project Management View Specs

Detailed view specifications for the project dashboard, PRD viewer, story tracker, and execution controls in HQ Desktop. Produced for US-011 of hq-desktop-epics.

**Dependency:** Built on top of US-010 `project-system-mapping.md` which documents prd.json schema, orchestrator state machine, story states, quality gates, and data points.

**Existing components to extend:** `projects-dashboard.tsx`, `project-detail.tsx` (dashboard), `projects-drill.tsx`, `project-detail.tsx` (empire), `projects-sidebar.tsx`, `use-orchestrator.ts`

---

## 1. Project List View

### 1.1 Layout

The project list is the entry point for all project work. It appears in two contexts:

1. **Dashboard mode** (projects-dashboard.tsx) -- Full-width card with sections grouped by state
2. **Empire sidebar** (projects-sidebar.tsx) -- Narrow 300px sidebar for empire navigation

Both should share the same data source (`useOrchestrator`) but render differently.

### 1.2 Information Architecture

```
Project List
  |-- Filter Bar (state, company, has-parent)
  |-- Section: Active (IN_PROGRESS)
  |   |-- ProjectRow (name, state badge, progress, current story, actions)
  |-- Section: Ready (READY, QUEUED)
  |   |-- ProjectRow
  |-- Section: Blocked (BLOCKED)
  |   |-- ProjectRow (+ blocked-by indicator)
  |-- Section: Paused (PAUSED)
  |   |-- ProjectRow
  |-- Section: Completed (COMPLETED)
  |   |-- ProjectRow (muted styling)
  |-- Footer: keyboard shortcuts
```

### 1.3 Filter Bar Spec

The current project list has no filtering. Add a filter bar above sections.

| Filter | Type | Options | Default |
|--------|------|---------|---------|
| State | Multi-select chips | All states from `ProjectState` enum | Show all except COMPLETED |
| Company | Dropdown | Derived from `manifest.yaml` company list + "All" | All |
| Has Parent | Toggle | "Child projects only" / "Top-level only" / "All" | All |
| Search | Text input | Fuzzy match on project name | Empty |

**Interaction:** Filters are persistent within the session (stored in React state, not persisted to disk). Clearing filters resets to defaults. Filter bar collapses to a single row of active filter chips when not focused.

### 1.4 ProjectRow Spec (Enhanced)

Current ProjectRow displays: status dot, name, state badge, stories count, progress bar.

**Add:**

| Element | Position | Source | Behavior |
|---------|----------|--------|----------|
| Current story badge | Below name, next to stories count | `project.currentStory` from orchestrator state | Only visible when `state === IN_PROGRESS`. Shows `US-XXX` with blue badge. Pulse animation while executing |
| Worker phase indicator | Right of current story badge | Requires new execution state reader (see data-layer PRD) | Shows "Phase 2/4: code-reviewer" when execution is active |
| Time since last update | Right-aligned, below progress bar | `project.updatedAt` | Relative time (e.g. "2m ago", "1h ago"). Updates every 30s |
| Parent project link | Below name, if `parentProject` set | `state.json` `parentProject` field | Small linked text: "child of {parent-name}". Clicking navigates to parent |
| Run/Pause action | Far right | State-dependent | Play icon for READY/PAUSED/BLOCKED. Pause icon for IN_PROGRESS. Hidden for COMPLETED |

### 1.5 State Badge Colors (Confirmed from existing code)

| State | Color | Animation | Label |
|-------|-------|-----------|-------|
| PLANNING | `text-muted-foreground` / `bg-muted/50` | None | Planning |
| READY | `text-emerald-400` / `bg-emerald-500/10` | None | Ready |
| QUEUED | `text-blue-400` / `bg-blue-500/10` | None | Queued |
| IN_PROGRESS | `text-green-400` / `bg-green-500/10` | `animate-pulse-working` on dot | Running |
| BLOCKED | `text-amber-400` / `bg-amber-500/10` | `animate-pulse-pending` on dot | Blocked |
| PAUSED | `text-yellow-400` / `bg-yellow-500/10` | None | Paused |
| COMPLETED | `text-muted-foreground` / `bg-muted/30` | None | Done |
| FAILED | `text-red-400` / `bg-red-500/10` | `animate-pulse-error` on dot | Failed |

---

## 2. Project Detail View

### 2.1 Layout

The project detail replaces the current README-parsing implementation with a proper prd.json-backed view. Split into a header section and a tabbed content area.

```
Project Detail
  |-- Header
  |   |-- Title (prd.name)
  |   |-- Description (prd.description)
  |   |-- Goal (metadata.goal)
  |   |-- Progress bar (storiesComplete / storiesTotal)
  |   |-- Status badges (state, current story, checked-out files)
  |   |-- Action buttons (Run, Pause, Stop, Resume)
  |-- Tab Bar
  |   |-- [Stories] [PRD] [Execution] [Settings]
  |-- Tab Content (scrollable)
```

### 2.2 Header Spec

The header is always visible (sticky top) while scrolling tab content.

| Element | Source | Notes |
|---------|--------|-------|
| Title | `prd.name` | Large text (text-lg font-semibold) |
| Description | `prd.description` | `text-sm text-white/60`, max 2 lines with clamp |
| Goal | `prd.metadata.goal` | Shown below description in smaller text. Expandable if long |
| Success Criteria | `prd.metadata.successCriteria` | Collapsible section, default collapsed |
| Progress bar | `storiesComplete / storiesTotal` | Green fill bar with percentage label. Same as current |
| State badge | `project.state` | Color-coded badge per state table above |
| Current story badge | `project.currentStory` | Blue badge with clock icon. Only when IN_PROGRESS |
| Branch name | `prd.branchName` | Monospace, small, clickable (copy to clipboard) |
| Target repo | `prd.metadata.repoPath` | Monospace, small. Linked to open in Finder or terminal |
| Related workers | `prd.metadata.relatedWorkers` | Small chips/badges with worker names |

### 2.3 Action Buttons Spec

| Button | Visible When | Action | Confirmation |
|--------|-------------|--------|-------------|
| Run | READY, PAUSED, FAILED | Spawn PTY: `claude "/run-project {name}"` | None for READY. Confirm for FAILED ("Restart from scratch?") |
| Run Story | Always (per-story) | Spawn PTY: `claude "/execute-task {project}/{story-id}"` | None |
| Pause | IN_PROGRESS | Send Ctrl+C to active PTY + set state PAUSED | "Pause after current story completes?" |
| Resume | PAUSED | Spawn PTY: `claude "/run-project --resume {name}"` | None |
| Stop | IN_PROGRESS | Kill PTY + set state PAUSED | "Stop immediately? Current story work may be lost." |

### 2.4 Tab: Stories (Default Tab)

This is the primary working view. Displays all user stories with their states.

#### Story List (default sub-view)

Stories displayed as expandable cards, sorted by: state group (in-progress > eligible > blocked > complete), then priority (ascending), then ID (ascending).

Each story card shows:

```
[State Icon] [ID] [Title]                    [Priority] [Labels]
[Description - 1 line, truncated]
[Dependencies: US-001, US-003]               [AC progress: 3/5]
```

**State icons:**
- Pending: Empty circle (`Circle`, white/30)
- Blocked: Lock icon (`Lock`, amber/60)
- In Progress: Spinning loader (`Loader2`, green/40, animate-spin)
- Complete: Check circle (`CheckCircle`, green/400)
- Failed: X circle (`XCircle`, red/400)

**Expandable content (on click):**

```
Acceptance Criteria:
  [x] Criterion 1 (green check)
  [ ] Criterion 2 (empty circle)
  [ ] Criterion 3 (empty circle)

Notes: {story.notes}

Execution History:
  [Link to execution detail if execution file exists]

[Run This Story] button (spawns /execute-task)
```

#### Label filtering

Stories should be filterable by label. Show label chips above the story list. Clicking a label highlights stories with that label and dims others.

### 2.5 Tab: PRD

Rendered view of the full prd.json content. Not raw JSON, but a structured document view.

```
PRD Viewer
  |-- Metadata Section
  |   |-- Created: {metadata.createdAt}
  |   |-- Goal: {metadata.goal}
  |   |-- Success Criteria: {metadata.successCriteria}
  |   |-- Quality Gates: {metadata.qualityGates as list}
  |   |-- Target Repo: {metadata.repoPath}
  |   |-- Branch: {branchName}
  |   |-- Related Workers: {metadata.relatedWorkers as chips}
  |   |-- Knowledge: {metadata.knowledge as list of paths}
  |-- Story Summary Table
  |   |-- ID | Title | Priority | Status | Dependencies | Labels
  |-- Dependency Graph (visual)
  |   |-- DAG rendering of story dependencies
  |-- Raw JSON toggle (collapsed, for debugging)
```

#### Dependency Graph Spec

Render story dependencies as a directed acyclic graph (DAG).

- **Layout:** Top-to-bottom (dependencies flow downward)
- **Nodes:** Story cards with ID, title, state color
- **Edges:** Arrows from dependency to dependent story
- **Colors:** Node border matches state color. Complete nodes are muted. Blocked nodes pulse amber
- **Interaction:** Hover on node highlights its direct dependencies (up) and dependents (down). Click navigates to story detail
- **Library:** Use a lightweight SVG-based approach or `dagre` for layout computation. Avoid heavy graph libraries
- **Fallback:** If graph is too complex (>20 nodes), show a simplified list view with indentation

### 2.6 Tab: Execution

Real-time and historical execution monitoring.

#### Active Execution Panel (when IN_PROGRESS)

```
Active Execution: {current_task.id} - {title}
  |-- Task Type: {classification}
  |-- Worker Pipeline
  |   |-- [Step 1: backend-dev] ---- COMPLETED (green check)
  |   |-- [Step 2: code-reviewer] -- IN PROGRESS (spinning)  <-- current
  |   |-- [Step 3: dev-qa-tester] -- PENDING (gray)
  |-- Back Pressure Results (per completed phase)
  |   |-- Phase 1: tests=pass lint=pass typecheck=pass
  |-- Handoff Context (expandable per transition)
  |   |-- backend-dev -> code-reviewer: "Implemented API endpoints..."
  |-- Terminal Link: "View in Terminal" (switches to terminal panel with active PTY)
```

**Worker Pipeline Visualization:**

Horizontal stepper component with connected dots:

```
  [backend-dev] -----> [code-reviewer] -----> [dev-qa-tester]
       (done)            (current)              (pending)
```

- Each step: circle + worker name below
- Completed: filled green circle, green text
- Current: pulsing green circle, bold text, spinner icon
- Pending: empty gray circle, muted text
- Failed: red circle with X
- Connector lines: green (completed segments), gray (pending segments)

#### Execution History (always visible)

List of past executions for this project, reverse chronological.

```
Execution History
  |-- US-010 (completed 2h ago)
  |   Workers: architect, knowledge-curator | Duration: 8m
  |   Back pressure: all pass
  |-- US-009 (completed 3h ago)
  |   Workers: product-planner | Duration: 5m
  |   Back pressure: all pass
```

Clicking an execution expands to show full details: phases, handoffs, key decisions, files touched.

### 2.7 Tab: Settings

Project-level settings and metadata management. Mostly read-only.

```
Settings
  |-- Quality Gates (editable list)
  |   |-- bun run test
  |   |-- bun check
  |   |-- [Add gate]
  |-- Linear Integration (if configured)
  |   |-- Status: Connected / Not configured
  |   |-- Done State: {linearDoneStateId}
  |-- Related Knowledge Paths (list)
  |-- Related Workers (list)
```

---

## 3. Story Board (Kanban View)

### 3.1 Layout

An alternative to the story list, providing a kanban-style board view. Accessible via a toggle in the Stories tab header: [List | Board].

```
Story Board
  |-- Column: Pending
  |   |-- Story Card
  |   |-- Story Card
  |-- Column: Blocked
  |   |-- Story Card (with blocking story name)
  |-- Column: In Progress
  |   |-- Story Card (with worker pipeline mini-viz)
  |-- Column: Complete
  |   |-- Story Card (muted)
```

### 3.2 Column Definitions

| Column | Stories Matching | Header Color | Count Badge |
|--------|-----------------|--------------|-------------|
| Pending | `passes: false`, no execution file, all deps met | White/40 | White circle |
| Blocked | `passes: false`, has unmet dependencies | Amber/60 | Amber circle |
| In Progress | Execution file with `status: in_progress` | Green/60 | Green pulse circle |
| Complete | `passes: true` | Green/40 (muted) | Green check |

### 3.3 Story Card (Kanban)

Compact card for board view. Smaller than the list view card.

```
+---------------------------+
| US-003  P1                |
| Audit Rust commands       |
| [epic-2] [knowledge]     |
| AC: 3/5                  |
+---------------------------+
```

| Element | Position | Notes |
|---------|----------|-------|
| Story ID | Top-left | Monospace, small |
| Priority | Top-right | `P1`, `P2`, `P3` badge |
| Title | Middle | Bold, max 2 lines |
| Labels | Below title | Colored chips, max 2 visible + overflow count |
| AC progress | Bottom | "3/5" with mini progress bar |

### 3.4 Kanban Interaction

- **Click card** opens story detail (same expandable content as list view, but in a slide-over panel from the right)
- **No drag-and-drop** -- story state is determined by execution, not manual movement. The board is read-only for state transitions
- **Horizontal scroll** when columns overflow
- **Virtual scrolling** within columns when >20 stories in a column
- **Column collapse** -- click column header to collapse/expand. Collapsed shows count only

### 3.5 Board Filters

Same filter bar as list view (label, priority, search). Filters apply across all columns.

---

## 4. Execution Control Spec

### 4.1 Trigger /run-project

**Entry points:**
1. "Run" button in project detail header
2. "Run" action in project row (play icon)
3. Command palette: `/run-project {name}`

**Flow:**

```
1. User clicks "Run" on project in READY state
2. Desktop spawns PTY: `claude "/run-project {name}"`
   - Uses terminal.rs spawn_pty command
   - Terminal panel opens (or focuses if already open)
3. Desktop starts watching:
   - workspace/orchestrator/state.json (project state changes)
   - workspace/orchestrator/{project}/state.json (progress updates)
   - workspace/orchestrator/{project}/executions/ (new execution files)
   - workspace/orchestrator/{project}/progress.txt (log entries)
4. Project row shows IN_PROGRESS state
5. Execution tab shows live worker pipeline
6. On completion: project shows COMPLETED state, confetti/subtle animation
```

### 4.2 Trigger /execute-task for Single Story

**Entry points:**
1. "Run This Story" button in story detail
2. Right-click story card in board view: "Execute Story"
3. Command palette: `/execute-task {project}/{story-id}`

**Flow:**

```
1. User clicks "Run This Story" on eligible story
2. Validate: story not already complete, all dependencies met
   - If blocked: show toast "Story is blocked by {dep-ids}"
   - If complete: show toast "Story already complete"
3. Desktop spawns PTY: `claude "/execute-task {project}/{story-id}"`
4. Execution tab activates for this story
5. Worker pipeline stepper shows real-time progress
6. On completion: story card flips to complete state
```

### 4.3 Pause / Resume

**Pause:**
```
1. User clicks "Pause" on running project
2. Confirmation dialog: "Pause after current story completes?"
   - "Pause Now" -- sends SIGINT to PTY (may lose current story work)
   - "Pause After Story" -- sets a flag; orchestrator stops after current story
   - "Cancel" -- dismiss
3. State transitions to PAUSED
4. Project row shows yellow pause badge
```

**Resume:**
```
1. User clicks "Resume" on paused project
2. Desktop spawns PTY: `claude "/run-project --resume {name}"`
3. State transitions to IN_PROGRESS
4. Execution picks up from next eligible story
```

### 4.4 Error Handling

When execution fails:

```
1. Execution tab shows failure:
   - Red phase step indicator
   - Error details expandable
   - "Retry" button (re-runs /execute-task for the failed story)
   - "Skip and Continue" button (marks story as skipped, continues project)
2. Project state transitions to FAILED or PAUSED (depending on failure type)
3. Toast notification: "Story {id} failed in {worker} phase: {brief error}"
4. Badge count on project row: red error indicator
```

---

## 5. Progress Visualization Spec

### 5.1 Project-Level Progress

**Progress Bar (existing, enhanced):**
- Green fill proportional to `storiesComplete / storiesTotal`
- Percentage label right-aligned
- When IN_PROGRESS: subtle shimmer animation on the leading edge
- Micro-interaction: bar width animates smoothly when story completes

**Progress Ring (alternative for sidebar):**
- Circular progress indicator for compact spaces
- Shows percentage in center
- Color: green fill on gray track
- Diameter: 32px for sidebar, 48px for dashboard cards

### 5.2 Story-Level Progress

**Acceptance Criteria Checklist:**
- Each criterion: checkbox icon + text
- Completed: green check, strikethrough text, muted opacity
- Incomplete: empty circle, full opacity
- Progress summary: "3/5 criteria met"

**Execution Phase Progress:**
- Stepper with connected dots (see section 2.6)
- Mini version for story cards: "Phase 2/4" text badge

### 5.3 Quality Gate Status

**Per-Phase Gate Results:**

```
Back Pressure:
  [pass] Tests      [pass] Lint      [pass] Typecheck      [skip] Build
```

Each gate is a small badge:
- Pass: green check icon + "pass" text
- Fail: red X icon + "fail" text (expandable to show error)
- Skip: gray dash icon + "skip" text

**Aggregate Gate Health (project level):**

```
Quality Gates: All passing (or "2 failures in last run")
```

Shown in project detail header. Click expands to show per-story gate details.

### 5.4 Progress Log

Real-time display of `workspace/orchestrator/{project}/progress.txt`.

```
Progress Log
  [2026-02-11T20:30:00Z] US-001: Created structure detection doc (1/24)
  [2026-02-11T21:15:00Z] US-002: Created child PRD with 10 stories (2/24)
  [2026-02-11T22:00:00Z] US-003: Completed Rust commands audit (3/24)
  ...
```

- Reverse chronological (newest first)
- Auto-scrolls to latest entry when new lines appear
- Each entry is clickable -- navigates to story detail
- Timestamp formatted as relative time ("2h ago") with absolute time on hover
- File watcher on progress.txt triggers re-read on append

---

## 6. Parent/Child Project Navigation

### 6.1 Epic-to-Child Linking

When a project has `parentProject` and `parentStory` set in state.json, Desktop should show bidirectional links.

**Parent project detail:**
```
Stories tab shows child projects inline:
  US-002: Design config & onboarding flow PRD
    Child PRD: hq-desktop-config (12 stories, 3 complete) [Navigate ->]
```

**Child project detail:**
```
Header shows parent link:
  "Part of: hq-desktop-epics > US-002" [Navigate to parent ->]
```

### 6.2 Epic Progress Roll-up

When a project is an epic (has child projects), show aggregate progress:

```
Epic Progress: 48/96 stories across 8 child PRDs
  hq-desktop-config:       10/12 stories (83%)
  hq-desktop-data-layer:   8/14 stories (57%)
  hq-desktop-design-system: 6/10 stories (60%)
  ...
```

This requires reading child project entries from state.json where `parentProject` matches.

---

## 7. Component Hierarchy

### 7.1 New Components Needed

| Component | Location | Purpose |
|-----------|----------|---------|
| `ProjectFilterBar` | `components/dashboard/project-filter-bar.tsx` | Filter by state, company, parent, search |
| `ProjectDetailTabs` | `components/dashboard/project-detail-tabs.tsx` | Tab container for Stories, PRD, Execution, Settings |
| `StoryList` | `components/dashboard/story-list.tsx` | Enhanced story list with state icons, sorting, filtering |
| `StoryBoard` | `components/dashboard/story-board.tsx` | Kanban columns for story states |
| `StoryCard` | `components/dashboard/story-card.tsx` | Compact card for board view |
| `StoryDetail` | `components/dashboard/story-detail.tsx` | Expandable detail: AC, execution, notes |
| `DependencyGraph` | `components/dashboard/dependency-graph.tsx` | DAG visualization of story deps |
| `WorkerPipeline` | `components/dashboard/worker-pipeline.tsx` | Horizontal stepper for execution phases |
| `ExecutionMonitor` | `components/dashboard/execution-monitor.tsx` | Active execution tracker |
| `ExecutionHistory` | `components/dashboard/execution-history.tsx` | Past execution browser |
| `QualityGateBadges` | `components/dashboard/quality-gate-badges.tsx` | Pass/fail/skip badges for gates |
| `ProgressLog` | `components/dashboard/progress-log.tsx` | Real-time progress.txt viewer |
| `PrdViewer` | `components/dashboard/prd-viewer.tsx` | Structured prd.json renderer |

### 7.2 Modified Components

| Component | Changes |
|-----------|---------|
| `projects-dashboard.tsx` | Add filter bar, enhanced ProjectRow |
| `project-detail.tsx` (dashboard) | Replace markdown parser with prd.json reader. Add tabs |
| `projects-drill.tsx` (empire) | Replace `has_readme` check with prd.json check |
| `project-detail.tsx` (empire) | Replace README rendering with prd.json-backed view |
| `projects-sidebar.tsx` | Add current story badge, worker phase indicator |
| `use-orchestrator.ts` | Add execution state fetching, progress log reading |

### 7.3 New Hooks Needed

| Hook | Purpose |
|------|---------|
| `useProjectPrd(name)` | Fetch and parse prd.json via Tauri command |
| `useExecutionState(project, taskId)` | Fetch per-task execution JSON |
| `useExecutionHistory(project)` | List all execution files for a project |
| `useProgressLog(project)` | Watch and read progress.txt |
| `useStoryStates(prd, executions)` | Compute derived story states (pending, blocked, in-progress, complete) |
| `useDependencyGraph(stories)` | Build DAG from story dependencies |

---

## 8. Interaction Patterns Summary

### 8.1 Navigation Flow

```
Project List -> Click project -> Project Detail (Stories tab)
  -> Click story -> Story expands (inline or slide-over in board view)
  -> Click "Execution" tab -> Execution Monitor
  -> Click execution history item -> Execution Detail (phases, handoffs)
  -> Click "PRD" tab -> PRD Viewer with dependency graph
  -> Click "Run" -> PTY spawns, Execution tab activates
```

### 8.2 Keyboard Shortcuts

| Key | Context | Action |
|-----|---------|--------|
| `Enter` | Project selected | Open project detail |
| `R` | Project selected | Run project |
| `P` | Project selected, running | Pause project |
| `Tab` | Project detail | Cycle tabs |
| `L` / `B` | Stories tab | Toggle List / Board view |
| `Esc` | Story detail slide-over | Close slide-over |
| `J` / `K` | Story list | Navigate stories up/down |

### 8.3 Real-Time Update Strategy

| Data | Update Method | Frequency |
|------|--------------|-----------|
| Project list | Poll `useOrchestrator` | 2s when IN_PROGRESS exists (existing) |
| Story states | Poll prd.json | 5s when IN_PROGRESS (new) |
| Execution state | File watcher on executions/ dir | On change (new Rust watcher needed) |
| Progress log | File watcher on progress.txt | On append (new Rust watcher needed) |
| Quality gates | Read from execution JSON | On execution phase complete |

Until new Rust watchers are built (see data-layer PRD), use polling as fallback. Polling intervals should be configurable.

---

## 9. Design Tokens (from design-system audit)

These views should use the established glass-card design language:

| Token | Value | Usage |
|-------|-------|-------|
| Card background | `bg-white/[0.04]` | Story cards, execution panels |
| Card border | `border-white/[0.06]` | Standard border |
| Card border (active) | `border-white/[0.1]` | Selected/active items |
| Hover | `bg-white/[0.04]` hover | Interactive elements |
| Section divider | `border-white/[0.06]` | Between header and content |
| Text primary | `text-white` | Titles, active content |
| Text secondary | `text-white/60` | Descriptions |
| Text muted | `text-white/40` | Metadata, timestamps |
| Text disabled | `text-white/30` | Completed items |
| Success color | `green-400` / `green-500/10` bg | Complete, pass |
| Warning color | `amber-400` / `amber-500/10` bg | Blocked, attention |
| Error color | `red-400` / `red-500/10` bg | Failed, error |
| Info color | `blue-400` / `blue-500/10` bg | Current story, in-progress |

---

## 10. Assumptions and Open Questions

### Assumptions
- Desktop cannot invoke Claude Code commands directly; it spawns PTY sessions
- File watchers will be implemented in the data-layer PRD (US-004 child stories)
- Polling is acceptable as interim solution until watchers exist
- The design system PRD (US-006) will formalize glass-card tokens referenced here

### Open Questions
- Should the kanban board support manual story reordering (changing priority)?
- Should Desktop show terminal output inline in the execution tab, or always in a separate terminal panel?
- How should Desktop handle concurrent project executions (multiple IN_PROGRESS)?
- Should the dependency graph be interactive (click to filter) or purely visual?
