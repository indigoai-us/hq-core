---
type: reference
domain: [engineering, product]
status: canonical
tags: [desktop-app, structure-detection, starter-kit, directory-schema, validation]
relates_to: []
---

# HQ Structure Detection Requirements

> US-001: Audit of required vs optional directories and files that constitute a valid HQ instance, with comparison of starter-kit to personal HQ and detection algorithm for Desktop.

## 1. Required vs Optional Dirs/Files for a Valid HQ Instance

### Required (Minimum Viable HQ)

These must exist for Desktop to recognize a directory as an HQ instance:

| Path | Type | Purpose | Validation |
|------|------|---------|------------|
| `.claude/CLAUDE.md` | file | Session protocol, context diet, learned rules | Must exist, non-empty |
| `.claude/commands/` | dir | Slash commands (at least 1 `.md` file) | Dir exists |
| `workers/registry.yaml` | file | Worker index | Valid YAML with `workers:` array |
| `projects/` | dir | Project PRDs | Dir exists |
| `workspace/` | dir | Runtime state container | Dir exists |
| `workspace/threads/` | dir | Auto-saved sessions | Dir exists |
| `knowledge/` | dir | Knowledge bases | Dir exists |

### Standard (Starter-Kit Baseline)

Present in every fresh `hq-starter-kit` clone. Desktop should expect these and render them:

| Path | Type | Purpose | Notes |
|------|------|---------|-------|
| `.claude/commands/*.md` | files | 18 slash commands (v5) | checkpoint, cleanup, execute-task, exit-plan, handoff, learn, metrics, newworker, nexttask, personal-interview, prd, reanchor, remember, run-project, run, search-reindex, search, setup |
| `.claude/scripts/` | dir | Shell scripts (pure-ralph-loop) | Optional but shipped |
| `.claude/settings.json` | file | Claude Code settings | JSON |
| `README.md` | file | Instance README | Informational |
| `CHANGELOG.md` | file | Version history | Informational |
| `LICENSE` | file | MIT license | Informational |
| `MIGRATION.md` | file | Upgrade guide | Informational |
| `.gitignore` | file | Git ignore rules | Standard |
| `agents.md` | file | User profile + preferences | Created by /personal-interview or /setup |
| `data/journal/` | dir | Journal entries | .gitkeep in starter |
| `docs/images/` | dir | Banner SVG, assets | Decorative |
| `knowledge/Ralph/` | dir | Ralph methodology (10 chapters) | Core knowledge |
| `knowledge/ai-security-framework/` | dir | Security best practices | Core knowledge |
| `knowledge/design-styles/` | dir | Design guidelines + swipes | Core knowledge |
| `knowledge/dev-team/` | dir | Development patterns | Core knowledge |
| `knowledge/hq-core/` | dir | Thread schema, INDEX spec, quick-ref | Core knowledge |
| `knowledge/loom/` | dir | Agent architecture patterns | Core knowledge |
| `knowledge/projects/` | dir | Project guidelines + templates | Core knowledge |
| `knowledge/workers/` | dir | Worker framework, templates, patterns | Core knowledge |
| `modules/modules.yaml` | file | Module manifest | Declares external modules |
| `modules/cli/` | dir | HQ CLI tool (TypeScript) | npm package |
| `projects/.gitkeep` | file | Placeholder | Empty starter |
| `prompts/` | dir | Prompt templates | pure-ralph-base.md |
| `settings/` | dir | Credentials (gitignored contents) | .gitkeep only |
| `settings/pure-ralph.json` | file | Ralph loop config | Non-secret |
| `social-content/drafts/` | dir | Content drafts (x/, linkedin/) | INDEX.md + .gitkeep |
| `workers/sample-worker/` | dir | Example worker template | Copy + customize |
| `workspace/checkpoints/` | dir | Manual saves | .gitkeep |
| `workspace/content-ideas/` | dir | Idea capture | inbox.jsonl |
| `workspace/drafts/` | dir | General drafts | .gitkeep |
| `workspace/learnings/` | dir | Task insights (event log) | .gitkeep |
| `workspace/orchestrator/` | dir | Project execution state | .gitkeep |
| `workspace/reports/` | dir | Generated reports | .gitkeep |
| `workspace/scratch/` | dir | Temp files | .gitkeep |
| `workspace/threads/` | dir | Auto-saved sessions | .gitkeep |

### Extended (Personal HQ Additions)

Present in {your-name}'s production HQ but NOT in the starter-kit. These represent advanced/custom features:

| Path | Type | Purpose | Starter Equivalent |
|------|------|---------|-------------------|
| `INDEX.md` | file | Root directory map | Not in starter |
| `USER-GUIDE.md` | file | Commands, workers, session guide | Not in starter |
| `agents-profile.md` | file | Profile + style (split from agents.md) | `agents.md` (single file) |
| `agents-companies.md` | file | Company contexts + roles | Not in starter |
| `.claude/settings.local.json` | file | Local permission overrides | Not in starter |
| `.claude/skills/` | dir | Agent skills (agent-browser) | Not in starter |
| `.claude/plans/` | dir | Plan mode artifacts | Not in starter |
| `.agents/skills/` | dir | Anthropic-format agent skills | Not in starter |
| `.mcp.json` | file | MCP server configuration | Not in starter |
| `.env`, `.env.local` | files | Environment variables | Not in starter |
| `companies/` | dir | Multi-company structure | Not in starter (optional) |
| `companies/manifest.yaml` | file | Company-resource isolation map | Not in starter |
| `companies/{co}/settings/` | dir | Per-company credentials | Not in starter |
| `companies/{co}/data/` | dir | Per-company data exports | Not in starter |
| `companies/{co}/knowledge/` | dir/symlink | Per-company knowledge (symlinked repos) | Not in starter |
| `knowledge/public/` | dir | Public knowledge (split) | Flat `knowledge/` |
| `knowledge/private/` | dir | Private knowledge | Not in starter |
| `repos/public/` | dir | Public git repos | Not in starter |
| `repos/private/` | dir | Private git repos | Not in starter |
| `scripts/` | dir | Utility scripts (migrate-prd, prd-to-beads) | Not in starter |
| `settings/{service}/` | dirs | Service-specific credentials | settings/.gitkeep only |
| `social-kit.yaml` | file | Social kit configuration | Not in starter |
| `starter-projects/` | dir | Project templates | In modules/.synced/hq-core/ |
| `tools/` | dir | Auxiliary tools (session-manager) | Not in starter |
| `archives/` | dir | Retired projects + state | Not in starter |
| `workspace/digests/` | dir | Daily/weekly digests | Not in starter |
| `workspace/image-gallery/` | dir | Generated images | Not in starter |
| `workspace/metrics/` | dir | Worker metrics | Not in starter |
| `workspace/orchestrator/INDEX.md` | file | Orchestrator directory map | .gitkeep only |
| `workspace/orchestrator/state.json` | file | Live project execution state | Not in starter |
| `workspace/orchestrator/{project}/` | dirs | Per-project execution state | Not in starter |
| `workspace/pr-drafts/` | dir | PR draft content | Not in starter |
| `workspace/reports/INDEX.md` | file | Reports directory map | .gitkeep only |
| `workspace/social-drafts/` | dir | Social media drafts + queue | Not in starter |
| `workspace/threads/INDEX.md` | file | Thread index | .gitkeep only |
| `workspace/threads/handoff.json` | file | Latest handoff state | Not in starter |
| `workspace/threads/recent.md` | file | Recent thread summary | Not in starter |
| `workers/public/` | dir | Public workers (30+) | Flat `workers/` |
| `workers/private/` | dir | Private workers (10+) | Not in starter |
| `workers/public/dev-team/` | dir | 12-worker dev team | Not in starter |
| `workers/public/content-*` | dirs | Content team (5 workers) | Not in starter |
| `workers/public/pr-*` | dirs | PR team (5 workers) | Not in starter |
| `node_modules/`, `package.json` | files | npm dependencies | Not in starter root |

## 2. Comparison Table: Starter-Kit vs Personal HQ

| Feature Area | Starter-Kit | Personal HQ | Delta |
|-------------|------------|-------------|-------|
| **Commands** | 18 in `.claude/commands/` | 22+ (added checkemail, email, generateimage, post-now, pr, preview-post, social-setup, contentidea, suggestposts, scheduleposts, digest) | +10-12 custom commands |
| **Workers** | 1 (sample-worker) | 40+ (10 private, 30 public across dev-team, content-team, pr-team) | Full worker ecosystem |
| **Worker Layout** | Flat `workers/` | Split `workers/public/` + `workers/private/` | Visibility separation |
| **Knowledge** | Flat `knowledge/` (8 dirs) | Split `knowledge/public/` + `knowledge/private/`, symlinked to git repos | Repo-backed, visibility-split |
| **Companies** | Not present (optional) | 4 companies ({company}, {company}, personal, golden-thread) + manifest.yaml | Multi-company isolation |
| **Projects** | .gitkeep placeholder | 60+ projects with prd.json, README, orchestrator state | Full project lifecycle |
| **Orchestrator** | .gitkeep | state.json + per-project dirs + checkouts.json | Active execution state |
| **Threads** | .gitkeep | 170+ thread JSONs + handoff.json + INDEX.md + recent.md | Rich session history |
| **Checkpoints** | .gitkeep | 50+ checkpoint JSONs | Saved progress |
| **Learnings** | .gitkeep | 10+ learning JSONs | Accumulated rules |
| **Settings** | .gitkeep + pure-ralph.json | 12+ service credential dirs (stripe, gusto, deel, etc.) | Credential management |
| **Repos** | Not present | `repos/public/` + `repos/private/` (25+ repos) | Git repo management |
| **Modules** | modules.yaml (hq-core only) | modules.yaml (16 modules: hq-core + 10 knowledge repos + social-kit) | Module ecosystem |
| **MCP** | Not present | `.mcp.json` with server configs | MCP integration |
| **Agent Skills** | Not present | `.agents/skills/` (8 Anthropic skills) + `.claude/skills/` | Skill library |
| **Social Content** | Drafts structure only | drafts + queue.json + social-kit.yaml | Publishing pipeline |
| **INDEX.md** | Not present at root | Root INDEX.md + 6+ sub-indexes | Navigable map |
| **Reports** | .gitkeep | 20+ reports across cdp, cfo, content, cro, marketing, qa, pr | Accumulated output |

## 3. Optional Features Enabling Enhanced Desktop Functionality

Each feature below is optional but, when present, unlocks additional Desktop capabilities:

### Tier 1: Core Enhancement (high value, common in any active HQ)

| Feature | Detection | Desktop Capability Unlocked |
|---------|-----------|---------------------------|
| `workers/registry.yaml` with entries | Parse YAML, count workers > 1 | Worker browser, skill runner, worker detail panels |
| `projects/*/prd.json` files | Scan for valid prd.json | Project dashboard, story tracker, kanban board |
| `workspace/threads/*.json` | Count JSON files > 0 | Thread browser, session history, thread inspector |
| `workspace/orchestrator/state.json` | File exists, valid JSON | Project execution monitor, progress bars, state badges |
| `workspace/checkpoints/*.json` | Count JSON files > 0 | Checkpoint browser, restore capability |
| `workspace/learnings/*.json` | Count JSON files > 0 | Learning viewer, rule history |

### Tier 2: Multi-Company (medium value, power users)

| Feature | Detection | Desktop Capability Unlocked |
|---------|-----------|---------------------------|
| `companies/` dir exists | Dir present with subdirs | Company switcher, company-scoped views |
| `companies/manifest.yaml` | Valid YAML with company entries | Company isolation enforcement, resource mapping |
| `companies/{co}/settings/` | Settings dir per company | Credential visibility (masked display) |
| `companies/{co}/knowledge/` | Knowledge dir (may be symlink) | Company-scoped knowledge browser |

### Tier 3: Knowledge System (medium value, knowledge-heavy users)

| Feature | Detection | Desktop Capability Unlocked |
|---------|-----------|---------------------------|
| `knowledge/public/` + `knowledge/private/` split | Both dirs exist | Visibility-aware knowledge browser |
| Symlinked knowledge dirs | `fs.readlink()` resolves to `repos/` | Knowledge repo status, git state per KB |
| `modules/modules.yaml` with entries | Parse, count modules > 1 | Module manager, sync status |
| `INDEX.md` files | Present in key dirs | INDEX-based navigation tree |
| qmd installed (`which qmd`) | Binary on PATH | Search bar integration (keyword, semantic, hybrid) |

### Tier 4: Advanced Integration (lower value, specialized)

| Feature | Detection | Desktop Capability Unlocked |
|---------|-----------|---------------------------|
| `.mcp.json` | File exists, valid JSON | MCP server status panel |
| `.agents/skills/` | Dir with skill subdirs | Agent skill browser |
| `.claude/skills/` | Dir with skill subdirs | Claude skill browser |
| `repos/public/` + `repos/private/` | Dirs with git repos | Repo browser, git status per repo |
| `tools/` | Dir with tool subdirs | Tools panel |
| `social-kit.yaml` | File exists | Social publishing controls |
| `workspace/social-drafts/queue.json` | File exists, valid JSON | Social queue viewer |
| `workspace/reports/` with files | Non-.gitkeep files present | Reports browser |

## 4. Detection Algorithm Pseudocode

```
function detectHQInstance(path: string): HQDetectionResult {
  // ────────────────────────────────────
  // Phase 1: Minimum viability check
  // ────────────────────────────────────

  const required = {
    claudeMd:     exists(path, '.claude/CLAUDE.md'),
    commandsDir:  isDir(path, '.claude/commands') && countFiles(path, '.claude/commands', '*.md') > 0,
    registryYaml: exists(path, 'workers/registry.yaml'),
    projectsDir:  isDir(path, 'projects'),
    workspaceDir: isDir(path, 'workspace'),
    threadsDir:   isDir(path, 'workspace/threads'),
    knowledgeDir: isDir(path, 'knowledge'),
  }

  const isValid = Object.values(required).every(v => v === true)

  if (!isValid) {
    return {
      valid: false,
      level: 'invalid',
      missing: Object.entries(required)
        .filter(([_, v]) => !v)
        .map(([k]) => k),
      features: {},
    }
  }

  // ────────────────────────────────────
  // Phase 2: Feature detection
  // ────────────────────────────────────

  const features = {
    // Workers
    hasWorkers:          parseYaml(path, 'workers/registry.yaml').workers?.length > 1,
    workerVisibility:    isDir(path, 'workers/public') && isDir(path, 'workers/private'),
    workerCount:         parseYaml(path, 'workers/registry.yaml').workers?.length ?? 0,

    // Projects
    hasProjects:         countDirsWithFile(path, 'projects', 'prd.json') > 0,
    projectCount:        countDirsWithFile(path, 'projects', 'prd.json'),
    hasOrchestrator:     exists(path, 'workspace/orchestrator/state.json'),

    // Threads & State
    hasThreads:          countFiles(path, 'workspace/threads', '*.json') > 0,
    threadCount:         countFiles(path, 'workspace/threads', '*.json'),
    hasCheckpoints:      countFiles(path, 'workspace/checkpoints', '*.json') > 0,
    hasLearnings:        countFiles(path, 'workspace/learnings', '*.json') > 0,
    hasHandoff:          exists(path, 'workspace/threads/handoff.json'),

    // Companies
    hasCompanies:        isDir(path, 'companies') && countSubdirs(path, 'companies') > 0,
    hasManifest:         exists(path, 'companies/manifest.yaml'),
    companyCount:        countSubdirs(path, 'companies', excludeFiles: true),
    companyIds:          listSubdirs(path, 'companies', excludeFiles: true),

    // Knowledge
    knowledgeSplit:      isDir(path, 'knowledge/public') || isDir(path, 'knowledge/private'),
    knowledgeFlatCount:  countSubdirs(path, 'knowledge'),
    hasSymlinkedKB:      anySymlinks(path, 'knowledge'),

    // Modules
    hasModules:          exists(path, 'modules/modules.yaml'),
    moduleCount:         parseYaml(path, 'modules/modules.yaml').modules?.length ?? 0,

    // Search
    hasQmd:              commandExists('qmd'),

    // INDEX system
    hasRootIndex:        exists(path, 'INDEX.md'),
    indexLocations:      findFiles(path, '**/INDEX.md'),

    // MCP
    hasMcp:              exists(path, '.mcp.json'),

    // Agent Skills
    hasAgentSkills:      isDir(path, '.agents/skills') || isDir(path, '.claude/skills'),

    // Repos
    hasRepos:            isDir(path, 'repos'),

    // Social
    hasSocialKit:        exists(path, 'social-kit.yaml'),
    hasSocialQueue:      exists(path, 'workspace/social-drafts/queue.json'),

    // Reports
    hasReports:          countNonGitkeepFiles(path, 'workspace/reports') > 0,

    // User Profile
    hasProfile:          exists(path, 'agents.md') || exists(path, 'agents-profile.md'),
    hasCompanyAgents:    exists(path, 'agents-companies.md'),
  }

  // ────────────────────────────────────
  // Phase 3: Classify instance level
  // ────────────────────────────────────

  let level: 'minimal' | 'standard' | 'full'

  if (features.hasCompanies && features.hasWorkers && features.hasOrchestrator) {
    level = 'full'
  } else if (features.hasWorkers || features.hasProjects) {
    level = 'standard'
  } else {
    level = 'minimal'
  }

  // ────────────────────────────────────
  // Phase 4: Detect version/origin
  // ────────────────────────────────────

  const version = {
    // Check if this is a starter-kit clone vs custom HQ
    isStarterKit:   !features.hasCompanies && !features.workerVisibility,

    // Detect starter-kit version from CHANGELOG.md
    starterVersion: parseChangelogVersion(path, 'CHANGELOG.md'),

    // Detect custom extensions
    customCommands: countFiles(path, '.claude/commands', '*.md') - 18,  // 18 = starter baseline
    customWorkers:  features.workerCount - 1,  // 1 = sample-worker baseline
    customKBs:      features.knowledgeFlatCount - 8,  // 8 = starter baseline KBs
  }

  return {
    valid: true,
    level,
    features,
    version,
    missing: [],
  }
}
```

### Detection Result Schema

```typescript
interface HQDetectionResult {
  valid: boolean
  level: 'invalid' | 'minimal' | 'standard' | 'full'
  missing: string[]       // Keys of required items that are missing
  features: {
    // Workers
    hasWorkers: boolean
    workerVisibility: boolean
    workerCount: number

    // Projects
    hasProjects: boolean
    projectCount: number
    hasOrchestrator: boolean

    // Threads & State
    hasThreads: boolean
    threadCount: number
    hasCheckpoints: boolean
    hasLearnings: boolean
    hasHandoff: boolean

    // Companies
    hasCompanies: boolean
    hasManifest: boolean
    companyCount: number
    companyIds: string[]

    // Knowledge
    knowledgeSplit: boolean
    knowledgeFlatCount: number
    hasSymlinkedKB: boolean

    // Modules
    hasModules: boolean
    moduleCount: number

    // Search
    hasQmd: boolean

    // INDEX system
    hasRootIndex: boolean
    indexLocations: string[]

    // MCP / Skills / Repos / Social / Reports / Profile
    hasMcp: boolean
    hasAgentSkills: boolean
    hasRepos: boolean
    hasSocialKit: boolean
    hasSocialQueue: boolean
    hasReports: boolean
    hasProfile: boolean
    hasCompanyAgents: boolean
  }
  version: {
    isStarterKit: boolean
    starterVersion: string | null
    customCommands: number
    customWorkers: number
    customKBs: number
  }
}
```

## 5. Desktop Hardcoded Path Assumptions (Current State)

The current HQ Desktop Rust backend (`files.rs`, `orchestrator.rs`) hardcodes the path `~/Documents/HQ` in every Tauri command:

| Tauri Command | Hardcoded Path |
|--------------|---------------|
| `list_prds()` | `~/Documents/HQ/projects` + `~/Documents/HQ/apps` + `~/Documents/HQ/repos/private` |
| `start_prd_watcher()` | Same 3 paths |
| `read_dir_tree()` | Falls back to `~/Documents/HQ` |
| `list_workers()` | `~/Documents/HQ/workers/registry.yaml` |
| `list_threads()` | `~/Documents/HQ/workspace/threads` |
| `list_checkpoints()` | `~/Documents/HQ/workspace/checkpoints` |
| `list_companies()` | `~/Documents/HQ/companies` |
| `list_projects()` | `~/Documents/HQ/projects` |
| `list_claude_sessions()` | `~/.claude/projects/-Users-{your-name}-Documents-HQ` (user-specific!) |
| `get_hq_stats()` | `~/Documents/HQ` (multiple sub-paths) |
| `get_worker_detail()` | `~/Documents/HQ/workers/{id}` (flat, not public/private split) |
| `get_company_detail()` | `~/Documents/HQ/companies/{id}` |
| `get_project_detail()` | `~/Documents/HQ/projects/{name}` |
| `spawn_worker_skill()` | `~/Documents/HQ` |
| `open_terminal_in_hq()` | `~/Documents/HQ` |
| `get_orchestrator_state()` | `~/Documents/HQ/workspace/orchestrator/state.json` |
| `get_checkouts_state()` | `~/Documents/HQ/workspace/orchestrator/checkouts.json` |

### Type Mismatches (Preview for US-003)

- `Prd` struct expects `features` array, but current prd.json uses `userStories`
- `PrdFeature` has `acceptance` field, prd.json has `acceptanceCriteria`
- `get_worker_detail()` looks in flat `workers/` not `workers/public/` or `workers/private/`
- `list_prds()` scans `apps/` dir which doesn't exist
- `list_claude_sessions()` has hardcoded username in path

## 6. Graceful Degradation Strategy

| Missing Structure | Desktop Behavior |
|-------------------|-----------------|
| No `companies/` | Hide company switcher, show single-context mode |
| No `workspace/orchestrator/state.json` | Show projects list without execution state badges |
| No `workers/` beyond sample | Show "Create your first worker" CTA |
| No `workspace/threads/*.json` | Show empty thread panel with "Run a session to see threads" |
| No `knowledge/public/` split | Show flat knowledge tree |
| No `.mcp.json` | Hide MCP panel |
| No `qmd` binary | Disable search bar, show install prompt |
| No `INDEX.md` files | Use directory listing instead of INDEX navigation |
| No `companies/manifest.yaml` | Skip company isolation enforcement |
| No `repos/` | Hide repo browser |
