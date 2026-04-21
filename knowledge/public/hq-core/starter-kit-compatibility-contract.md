---
type: reference
domain: [engineering, product]
status: canonical
tags: [hq-template, compatibility, desktop-app, version-detection, feature-degradation]
relates_to: []
---

# HQ Template Compatibility Contract

> US-023: Defines the minimum HQ structure Desktop requires, feature degradation behavior for simpler instances, and version detection strategy. Enables Desktop to work with any HQ instance from fresh template clone (indigoai-us/hq) to fully evolved production setup.

## 1. Minimum Required Structure

Desktop MUST function with this absolute minimum. If any item is missing, Desktop shows an "Invalid HQ" error and refuses to load.

| # | Path | Type | Validation Rule | Why Required |
|---|------|------|----------------|--------------|
| 1 | `.claude/CLAUDE.md` | file | Exists, non-empty | Core identity of an HQ instance |
| 2 | `.claude/commands/` | dir | Contains >= 1 `.md` file | Commands panel needs at least one entry |
| 3 | `workers/registry.yaml` | file | Valid YAML, has `workers:` key (array) | Worker browser needs a parseable registry |
| 4 | `projects/` | dir | Exists (may be empty) | Project dashboard mount point |
| 5 | `workspace/` | dir | Exists | Runtime state container |
| 6 | `workspace/threads/` | dir | Exists (may be empty) | Thread browser mount point |
| 7 | `knowledge/` | dir | Exists (may have subdirs or be empty) | Knowledge browser mount point |

**Contract rule:** If and only if all 7 items validate, Desktop proceeds to feature detection. Otherwise, it renders a diagnostic screen listing which items are missing with remediation instructions (e.g., "Run `mkdir -p workspace/threads` to fix").

## 2. Instance Levels

Desktop classifies every valid HQ into one of three levels. The level determines which UI panels are active, which nav items appear, and which background watchers start.

### Level 1: Minimal

**Definition:** Passes the 7-item validation but has little or no populated content.

**Typical instance:** A fresh clone of `indigoai-us/hq` template that has not yet run `/setup`.

**Structural fingerprint:**
- `workers/registry.yaml` has <= 4 workers (sample + 3 codex)
- `projects/` contains no `prd.json` files
- `workspace/threads/` is empty or has only `.gitkeep`
- No `companies/` directory
- No `workspace/orchestrator/state.json`

### Level 2: Standard

**Definition:** Has active workers AND/OR active projects. The user has started building on top of the starter kit.

**Typical instance:** A template clone after running `/setup`, creating 1-2 workers with `/newworker`, and starting a project with `/plan`.

**Structural fingerprint (any of):**
- `workers/registry.yaml` has > 4 workers
- At least one `projects/*/plan.json` exists
- `workspace/threads/` has >= 1 `.json` file
- `workspace/orchestrator/state.json` exists

### Level 3: Full

**Definition:** Multi-company structure with extensive workers, projects, and orchestration state. Power user / production HQ.

**Typical instance:** {your-name}'s personal HQ with 5 companies, 40+ workers, 60+ projects, 170+ threads.

**Structural fingerprint (all of):**
- `companies/` directory exists with >= 1 company subdirectory
- `companies/manifest.yaml` exists with valid company entries
- `workers/registry.yaml` has > 10 workers
- `workspace/orchestrator/state.json` exists

## 3. Feature Matrix by Level

Each Desktop feature is available at specific instance levels. Features degrade gracefully at lower levels -- they hide or show placeholder states, never error.

| Desktop Feature | Minimal | Standard | Full | Detection |
|----------------|---------|----------|------|-----------|
| **Dashboard (stats header)** | Zeroed counts | Real counts | Real counts + company breakdown | Parse registry + scan dirs |
| **Commands palette** | Available (template 18) | Available (may have more) | Available (22+) | Count `.claude/commands/*.md` |
| **Worker browser** | Shows sample + codex | Shows all workers | Shows all + private/public split | Parse `registry.yaml` |
| **Worker detail** | Basic info | Full skills + learnings | Full + company ownership | Read `worker.yaml` per worker |
| **Worker skill runner** | Available | Available | Available | Always enabled if workers exist |
| **Project dashboard** | "Create your first project" CTA | Project list with progress | Full project list + state badges | Scan `projects/*/plan.json` |
| **Project detail (PRD viewer)** | N/A | Render prd.json | Render prd.json + orchestrator state | Read `prd.json` + execution state |
| **Story kanban board** | N/A | Available | Available + cross-project view | Parse `userStories` array |
| **Orchestrator state** | Hidden | Available if state.json exists | Full execution monitor | Check `workspace/orchestrator/state.json` |
| **Thread browser** | "Run a session to see threads" | Thread list | Thread list + handoff context | Count `workspace/threads/*.json` |
| **Checkpoint browser** | Empty state | Available | Available | Count `workspace/checkpoints/*.json` |
| **Learning viewer** | Empty state | Available | Available | Count `workspace/learnings/*.json` |
| **Company switcher** | Hidden | Hidden | Available | Check `companies/` with subdirs |
| **Company detail** | N/A | N/A | Full (settings, knowledge, data) | Per `manifest.yaml` entry |
| **Knowledge browser** | Flat tree of `knowledge/` | Flat tree | Split public/private + company-scoped | Detect `knowledge/public/` vs flat |
| **Knowledge search (qmd)** | Disabled ("Install qmd") | Available if qmd installed | Available with collection picker | `which qmd` or `qmd status` |
| **Repo browser** | Hidden | Hidden | Available | Check `repos/` dir exists |
| **MCP panel** | Hidden | Hidden if no `.mcp.json` | Available | Check `.mcp.json` exists |
| **Social content** | Hidden | Hidden | Available if `social-kit.yaml` | Check config file |
| **Reports browser** | Hidden | Available if reports exist | Available | Check non-gitkeep files in `workspace/reports/` |
| **INDEX.md navigation** | Use dir listing | Use dir listing or INDEX if present | INDEX-based tree | Check for `INDEX.md` files |
| **Terminal** | Available | Available | Available | Always enabled |
| **User profile** | "Run /personal-interview" CTA | Available if agents.md exists | Available + companies profile | Check `agents.md` or `agents-profile.md` |

## 4. Graceful Degradation Rules

Desktop MUST follow these rules when encountering missing structures. The principle: **show what exists, hide what doesn't, never crash.**

### Directory Missing

| Missing Directory | Desktop Behavior |
|-------------------|-----------------|
| `companies/` | Hide company switcher entirely. All views show single-context mode. No company filter in search. |
| `companies/{co}/knowledge/` | Show company card without knowledge section. |
| `companies/{co}/settings/` | Show company card without credentials section. |
| `knowledge/public/` (flat layout) | Show `knowledge/` contents directly as a flat tree. No public/private toggle. |
| `knowledge/private/` | Show only public knowledge. No private tab. |
| `repos/` | Hide repo browser nav item entirely. |
| `workspace/orchestrator/` | Show projects without execution state badges. No progress bars. |
| `workspace/checkpoints/` | Show empty checkpoint panel with help text. |
| `workspace/learnings/` | Show empty learnings panel with help text. |
| `workspace/reports/` | Hide reports nav item. |
| `workspace/social-drafts/` | Hide social content section. |
| `.agents/skills/` | Hide agent skills browser. |
| `.claude/skills/` | Hide Claude skills browser. |
| `data/` | No effect (data dir is rarely surfaced in UI). |
| `docs/` | No effect. |
| `prompts/` | No effect. |

### File Missing

| Missing File | Desktop Behavior |
|-------------|-----------------|
| `workspace/orchestrator/state.json` | Project list renders without state badges. "Start /run-project" CTA on project detail. |
| `workspace/threads/handoff.json` | No "Resume last session" shortcut in dashboard. |
| `workspace/threads/recent.md` | No recent threads summary in dashboard. |
| `INDEX.md` (root) | Use `ls`-style directory listing for navigation instead of INDEX tree. |
| `companies/manifest.yaml` | Skip company isolation enforcement. Show companies as basic directories. |
| `.mcp.json` | Hide MCP integration panel. |
| `social-kit.yaml` | Hide social publishing controls. |
| `agents.md` / `agents-profile.md` | Show "Run /personal-interview" CTA in profile section. |
| `agents-companies.md` | No company context in profile (single-company users). |
| `modules/modules.yaml` | Hide module manager panel. |
| `settings/pure-ralph.json` | No Ralph loop configuration in settings view. |

### Worker-Specific Degradation

| Condition | Desktop Behavior |
|-----------|-----------------|
| `registry.yaml` has `workers: []` (empty) | Show "Create your first worker" with link to `/newworker`. |
| Worker `path` in registry points to non-existent dir | Show worker as "missing" (grayed out, warning icon). |
| Worker lacks `worker.yaml` | Show worker card with registry info only (id, type, description). No skills panel. |
| Worker `worker.yaml` has no `skills:` | Show worker detail without skill runner. |
| Worker has `company:` field | Display company badge. If `companies/` missing, ignore company field. |
| `workers/public/` + `workers/private/` split | Show visibility toggle/filter. |
| Flat `workers/` (no public/private split) | Show all workers in single list, no visibility filter. |

### Project-Specific Degradation

| Condition | Desktop Behavior |
|-----------|-----------------|
| `projects/` dir is empty | Show "Create your first project" with link to `/plan`. |
| `prd.json` missing `userStories` | Show project as "legacy format" with migration prompt. |
| `prd.json` has `features` instead of `userStories` | Same as above -- legacy format. |
| Story missing `passes` field | Treat as `passes: false`. |
| `workspace/orchestrator/{project}/` missing | Show project without execution history. |
| `workspace/orchestrator/{project}/executions/` missing | Show stories without execution detail. |

### Knowledge-Specific Degradation

| Condition | Desktop Behavior |
|-----------|-----------------|
| `knowledge/` contains symlinks | Resolve symlinks transparently. Show git status of target repo if available. |
| Symlink target doesn't exist (broken symlink) | Show knowledge entry as "broken link" (warning icon, skip in tree). |
| Knowledge dir has no `INDEX.md` | Use directory listing for that subtree. |
| Knowledge dir has `INDEX.md` | Parse and render INDEX.md as the tree structure. |
| `qmd` not installed | Disable search bar. Show "Install qmd for search" with link. |
| `qmd` installed but no collections | Show search bar, run default HQ search. |

## 5. Version Detection Strategy

Desktop needs to identify the HQ template version and detect custom extensions to understand what to expect structurally.

### 5.1 Template Version Detection

**Primary method: CHANGELOG.md parsing**

```
Algorithm:
1. Read CHANGELOG.md from HQ root
2. Scan for first heading matching /^## v(\d+\.\d+\.\d+)/
3. Extract version string
4. If no match, version = "unknown"
```

**Version history (for Desktop reference):**

| Version | Key Structural Changes | Impact on Desktop |
|---------|----------------------|-------------------|
| v5.3.0 | Codex workers + MCP pattern added to dev-team | Expect `workers/dev-team/codex-*` |
| v5.2.0 | Knowledge repo scaffolding in setup | May have `repos/` dir and symlinks |
| v5.1.0 | Context Diet, `recent.md` in threads | `workspace/threads/recent.md` may exist |
| v5.0.0 | Sample-worker only, `/personal-interview` | Minimal worker set, `agents.md` may exist |
| v4.0.0 | INDEX.md system, knowledge repos, `/learn` | `INDEX.md` files, `workspace/learnings/` |
| v3.3.0 | Auto-handoff, command visibility overhaul | 16 commands (down from 29) |
| v3.0.0 | qmd search, `/pure-ralph` | Search integration possible |
| v2.0.0 | Project orchestration, dev-team workers | Full dev-team, content-team (later removed in v5) |

**Fallback if no CHANGELOG.md:** Check for structural markers:
- Has `workers/dev-team/codex-*` -> >= v5.3
- Has `settings/pure-ralph.json` -> >= v3.0
- Has `workers/sample-worker/` -> >= v5.0
- Has `workspace/content-ideas/` -> >= v2.0
- None of above -> pre-v2.0 or custom

### 5.2 Template vs Custom HQ Detection

**Heuristic: Is this a template clone or a custom-built HQ?**

```
isTemplate =
  !exists('companies/')           // template has no companies
  && !exists('workers/public/')   // template uses flat workers/
  && !exists('workers/private/')  // no visibility split
  && !exists('repos/')            // no repos dir
  && !exists('.mcp.json')         // no MCP config
```

If `isTemplate` is true, Desktop can show "HQ Template v{version}" in the settings. If false, show "Custom HQ".

### 5.3 Custom Extension Detection

Desktop counts extensions beyond the template baseline to show users how much their HQ has grown:

| Metric | Baseline (v5.3) | Calculation |
|--------|-----------------|-------------|
| Custom commands | 18 | `count(.claude/commands/*.md) - 18` |
| Custom workers | 4 | `registry.workers.length - 4` (sample + 3 codex) |
| Knowledge bases | 9 | `count(knowledge/*/`) - 9` (Ralph, hq-core, hq, dev-team, workers, projects, loom, ai-security-framework, design-styles) |
| Projects | 0 | `count(projects/*/plan.json)` |
| Threads | 0 | `count(workspace/threads/*.json)` |
| Companies | 0 | `count(companies/*/` subdirs) |

**Version-specific baselines:** When Desktop detects a specific template version, it should use that version's known baselines for accurate "custom extension" counts. The baselines above are for v5.3.0.

### 5.4 Structural Evolution Detection

Desktop should detect when a user has evolved their HQ template beyond the default by checking for these structural markers (ordered by typical progression):

| Stage | Marker | Description |
|-------|--------|-------------|
| Fresh clone | Only `.gitkeep` files in workspace dirs | Just cloned, nothing done |
| Post-setup | `agents.md` exists | Ran `/setup` |
| First worker | registry has > 4 workers | Created custom worker via `/newworker` |
| First project | `projects/*/plan.json` exists | Created PRD via `/plan` |
| Active use | `workspace/threads/*.json` count > 5 | Regular session use |
| Multi-company | `companies/` exists with manifest | Set up company isolation |
| Knowledge repos | Symlinks in `knowledge/` pointing to `repos/` | Graduated to repo-backed knowledge |
| Full production | `workspace/orchestrator/state.json` exists, > 10 projects, > 10 workers | Power user |

## 6. Compatibility Contract Summary

This section is the formal contract that Desktop code MUST adhere to.

### MUST

1. Desktop MUST validate the 7 required items before loading any UI.
2. Desktop MUST classify the instance as minimal/standard/full after validation.
3. Desktop MUST hide (not error on) any missing optional structure.
4. Desktop MUST resolve symlinks transparently when reading knowledge directories.
5. Desktop MUST parse `workers/registry.yaml` from the HQ root, never assume a path like `workers/public/` or `workers/private/`.
6. Desktop MUST support both flat `knowledge/` and split `knowledge/public/` + `knowledge/private/` layouts.
7. Desktop MUST support both flat `workers/` and split `workers/public/` + `workers/private/` layouts.
8. Desktop MUST read `CHANGELOG.md` for version detection and fall back to structural markers if absent.
9. Desktop MUST display file/directory absence as empty states with help text, never as errors.
10. Desktop MUST handle `prd.json` with either `userStories` (current) or `features` (legacy) array key.

### MUST NOT

1. Desktop MUST NOT crash or show unhandled errors when any optional structure is missing.
2. Desktop MUST NOT hardcode `~/Documents/HQ` as the HQ path (currently 17 places do this -- see US-001 Section 5).
3. Desktop MUST NOT assume `companies/` exists (it is optional, not present in template).
4. Desktop MUST NOT assume `workers/public/` or `workers/private/` layout (template uses flat `workers/`).
5. Desktop MUST NOT assume `knowledge/public/` layout (template uses flat `knowledge/`).
6. Desktop MUST NOT require `qmd` to be installed (search is a progressive enhancement).
7. Desktop MUST NOT display company-scoped UI elements when no `companies/` directory exists.
8. Desktop MUST NOT require `workspace/orchestrator/state.json` to show the project list.
9. Desktop MUST NOT assume `INDEX.md` files exist (they are an advanced feature).

### SHOULD

1. Desktop SHOULD show instance level (minimal/standard/full) in settings or footer.
2. Desktop SHOULD show template version when detectable.
3. Desktop SHOULD show "custom extensions" count to help users understand their HQ's growth.
4. Desktop SHOULD start file watchers only for directories that exist.
5. Desktop SHOULD display CTAs for missing features that guide users toward activation (e.g., "Run /newworker to create your first worker").
6. Desktop SHOULD cache the instance level and feature detection result, re-evaluating on file system changes.
7. Desktop SHOULD show structural evolution stage to help users understand where they are in the HQ maturity curve.

## 7. Rust Implementation Notes

The current Rust backend (see US-001, Section 5) needs these changes to comply with this contract:

1. **Config-based HQ path:** Replace all 17 hardcoded `~/Documents/HQ` references with a config value loaded at startup. The HQ path comes from a config file (e.g., `~/.hq-desktop/config.json`) or the Tauri app's settings store.

2. **Validation command:** Add a `validate_hq_instance(path: String)` Tauri command that runs the 7-item check and returns the `HQDetectionResult` (see US-001 detection algorithm).

3. **Feature detection command:** Add a `detect_hq_features(path: String)` Tauri command that returns the full feature flags, instance level, and version info.

4. **Conditional watchers:** Only start `prd_watcher` if `projects/` has content. Only start `threads_watcher` if `workspace/threads/` exists. Add watchers for new directories only when they are detected.

5. **Worker path resolution:** `list_workers()` and `get_worker_detail()` must read paths from `registry.yaml` rather than assuming directory structure. Support both `workers/{id}/` and `workers/public/{id}/` patterns.

6. **Knowledge symlink resolution:** Use `std::fs::canonicalize()` or Tauri's path resolver when reading knowledge directories to transparently follow symlinks.

7. **PRD field compatibility:** Support both `userStories` and `features` keys in prd.json parsing. When `features` is found but not `userStories`, treat it as the story array (with field name mapping).
