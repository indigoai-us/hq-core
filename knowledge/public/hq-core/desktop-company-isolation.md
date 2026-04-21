---
type: reference
domain: [engineering, operations]
status: canonical
tags: [desktop-app, company-isolation, manifest, credential-scoping, routing]
relates_to: []
---

# Company Isolation in HQ Desktop

How `manifest.yaml` maps to Desktop routing, credential visibility rules, knowledge scoping per company, and company switching UX.

## manifest.yaml Schema

`companies/manifest.yaml` is the single source of truth for company-to-resource ownership. Every company entry has these fields:

```yaml
{company_id}:
  repos: [list of repo paths]           # Git repos owned by this company
  settings: [list of setting dir names]  # Credential/config dirs under companies/{id}/settings/
  workers: [list of worker IDs]          # Private workers scoped to this company
  knowledge: companies/{id}/knowledge/   # Knowledge base path (symlinked to a git repo)
  deploy: [list of deploy commands]      # Slash commands for deployment
  vercel_projects: [list of domains]     # Vercel deployment targets
  qmd_collections: [list of names]       # Semantic search collections
```

Nullable fields: `knowledge` (golden-thread has `null`), `settings` (can be empty array), `qmd_collections` (can be empty array).

### Current Companies

| Company | Repos | Settings Dirs | Workers | Knowledge | qmd Collections |
|---------|-------|--------------|---------|-----------|-----------------|
| {company} | {product}, {product}-popup-builder, agent-ops-hq, {product}-cx | stripe, gusto, deel, quickbooks, shopify-partner, linear-voyage + (on disk: attio, browser-state, gmail, google-cloud, infobip, meta, stripe-voyage) | cfo-{company}, {company}-analyst, {product}-deploy | yes | {company}, {product} |
| {company} | {company}-advisory | (on disk: linkedin, loops, meta, x) | cmo-brand | yes | {company} |
| personal | (none) | slack + (on disk: gmail, linkedin, x) | x-user, invoices | yes | personal |
| golden-thread | golden-thread-portal | (none) | (none) | null | (none) |

Note: The manifest `settings` list does not always match the on-disk contents of `companies/{id}/settings/`. Desktop must discover settings from the filesystem, but the manifest defines which are "declared" vs which are incidental.

## Desktop Isolation Enforcement

### Current State (Gaps)

Desktop currently has **no company isolation enforcement**. The existing code:

1. **`list_companies()` in files.rs** -- Scans `companies/` directory, returns basic existence checks (`has_settings`, `has_data`, `has_knowledge`). No manifest awareness.
2. **`get_company_detail()` in files.rs** -- Lists raw file names from `settings/`, `data/`, `knowledge/` subdirectories. No filtering, no masking, no ownership mapping.
3. **`CompanyDetailView` component** -- Displays all settings/data/knowledge files for any company the user clicks. No credential masking. No cross-company guardrails.
4. **No manifest.yaml parsing** -- Desktop does not read `manifest.yaml` at all. The `WorkerEntry` struct lacks a `company` field. Projects have no company association.
5. **No company context state** -- There is no "active company" concept in the UI. All views show all companies' data simultaneously.

### Required Isolation Model

Desktop must enforce company isolation at three layers:

#### Layer 1: Data Access (Rust Backend)

A new Tauri command `read_manifest()` must parse `companies/manifest.yaml` and return a typed `CompanyManifest` struct:

```rust
struct CompanyManifest {
    id: String,
    repos: Vec<String>,
    settings: Vec<String>,
    workers: Vec<String>,
    knowledge: Option<String>,
    deploy: Vec<String>,
    vercel_projects: Vec<String>,
    qmd_collections: Vec<String>,
}
```

All company-scoped queries (`get_company_detail`, `list_workers`, `list_projects`) should accept an optional `company_filter: Option<String>` parameter. When set, the backend filters results to resources owned by that company per the manifest.

#### Layer 2: State Management (React)

A `CompanyContext` provider (or Zustand store) must track:

```typescript
interface CompanyState {
  activeCompany: string | null          // null = "all companies" view
  manifest: Record<string, CompanyManifest>  // parsed manifest.yaml
  setActiveCompany: (id: string | null) => void
}
```

When `activeCompany` is set:
- Worker list filters to workers owned by that company (from manifest `workers` array), plus all public workers
- Project list filters to projects whose `repoPath` maps to a repo owned by that company
- Knowledge browser scopes to that company's knowledge path
- Search defaults to that company's qmd collection(s)
- Settings view shows only that company's settings

#### Layer 3: UI Enforcement (Components)

Every view that displays company-scoped resources must respect `activeCompany`:
- **Nav/sidebar**: Company picker dropdown or tab bar
- **Worker list**: Filter by company ownership, show public workers with a "shared" badge
- **Project list**: Filter by company association
- **Knowledge browser**: Scope to active company's knowledge path
- **Search**: Default qmd collection to active company

## Credential Visibility Rules

### Classification of Settings Files

Settings files fall into three sensitivity tiers:

| Tier | Description | Desktop Behavior | Examples |
|------|-------------|-----------------|----------|
| **Secret** | API keys, tokens, OAuth credentials, service account JSON | NEVER display content. Show file name only, with a lock icon. Content masked as `[REDACTED]` | `stripe/*.json`, `google-cloud/*.json`, `gmail/credentials.json`, `linear/*.json` |
| **Config** | Non-secret configuration (feature flags, org IDs, display names) | Display content read-only | `browser-state/*.json` (session state, not secrets), `analytics/config.yaml` |
| **Reference** | Documentation, guides, READMEs within settings dirs | Display content freely | `{company}/settings/README.md` |

### Detection Heuristic

Since HQ has no explicit schema for classifying settings sensitivity, Desktop must use heuristics:

1. **File name patterns (Secret)**: `*credentials*`, `*secret*`, `*token*`, `*key*`, `*auth*`, `*.pem`, `*.p12`
2. **Content patterns (Secret)**: Files containing `apiKey`, `api_key`, `secret`, `token`, `client_secret`, `private_key`, `-----BEGIN`
3. **Known secret dirs**: `stripe`, `gusto`, `deel`, `quickbooks`, `shopify-partner`, `linear*`, `figma`, `google-drive`, `google-cloud`, `gmail`, `slack`, `meta`, `infobip`, `attio`, `clerk`, `retool`, `loops` -- all of these contain credentials
4. **Default assumption**: If uncertain, treat as Secret (fail safe)

### Implementation Approach

The Rust backend should:
1. List settings file/directory names (always safe to show names)
2. For any file content request under `companies/*/settings/`, apply the detection heuristic
3. If the file is classified as Secret, return `{ "masked": true, "type": "credential" }` instead of content
4. Never return raw credential file content through Tauri commands

The frontend should:
- Show a lock icon next to masked files
- Display "Credentials - not viewable in Desktop" for masked content
- Never attempt to decrypt or unmask

### Cross-Company Rule

Desktop MUST NOT allow viewing Company A's settings when Company B is the active context. The backend `get_company_detail` command must validate that the requested `company_id` matches the active company context (or that no company filter is active).

## Knowledge Scoping

### How Company Filter Maps to Knowledge Access

Each company's knowledge is stored at `companies/{id}/knowledge/`, which is a symlink to an independent git repo (e.g., `repos/private/knowledge-{company}/`).

When `activeCompany` is set:

| Scope | Knowledge Path | Behavior |
|-------|---------------|----------|
| Company-specific | `companies/{activeCompany}/knowledge/` | Primary knowledge source. Full browsing and search |
| Public/shared | `knowledge/public/` | Always accessible regardless of company filter |
| Other companies | `companies/{other}/knowledge/` | Hidden from tree browser. Excluded from search results |

### qmd Collection Routing

When searching via qmd, the active company determines the default collection:

```typescript
function getSearchCollections(activeCompany: string | null): string[] {
  if (!activeCompany) return ['hq']  // search everything
  const manifest = getManifest(activeCompany)
  return manifest.qmd_collections  // e.g., ['{company}', '{product}'] for {company}
}
```

The search UI should:
1. Auto-select the active company's collections when a company filter is set
2. Allow manual collection override (user might want to search across companies)
3. Show a "Searching: {collection}" indicator so the user knows the scope
4. When no company is active, default to the `hq` collection (searches everything)

### Knowledge Tree Navigation

The knowledge browser (currently a placeholder "coming soon" in `empire-view.tsx`) should render:

```
Knowledge
├── Public (always visible)
│   ├── Ralph/
│   ├── hq-core/
│   ├── dev-team/
│   ├── workers/
│   └── ...
├── {activeCompany} (when filtered)
│   └── {company knowledge files}
└── All Companies (when no filter)
    ├── {company}/
    ├── {company}/
    └── personal/
```

## Company Switching UX

### How Changing Company Context Affects All Views


| View | Effect of Company Switch |
|------|------------------------|
| **Dashboard/Stats** | Stats scope to company-owned resources (workers, projects, threads) |
| **Workers** | List filters to company-owned private workers + all public workers. Worker detail only shows threads from company context |
| **Projects** | List filters to projects targeting company-owned repos |
| **Knowledge** | Tree scopes to company knowledge path. Public knowledge remains visible |
| **Search** | Default qmd collection switches to company's collection(s) |
| **Settings** | Only company's settings dirs shown. Cross-company settings hidden |
| **Terminal** | No filtering -- terminal is company-agnostic (user controls CLI context) |
| **Threads** | Filter to threads whose `worker_id` belongs to the company, or threads with `cwd` inside company repos |

### Company Picker Design

The company picker should appear in the top bar (`top-bar.tsx`) or left sidebar, providing:

1. **"All" option** -- No company filter, show everything (default state)
2. **Company list** -- Each company from manifest, with visual indicator (color dot or icon)
3. **Active indicator** -- Highlight the currently selected company
4. **Keyboard shortcut** -- Quick switch via command palette (e.g., `/company {company}`)
5. **Persistence** -- Remember last active company across app restarts (store in Tauri's app data or localStorage)

### Visual Differentiation

Each company should have a consistent color assignment for visual identification across all views:

```typescript
const companyColors: Record<string, string> = {
  {company}: '#00ff88',   // green (matches brand)
  {company}: '#6366f1',        // {company} (matches brand name)
  personal: '#a855f7',      // purple
  'golden-thread': '#ffd700' // gold (matches brand name)
}
```

When a company is active, the top bar or sidebar should show a subtle color accent matching the company, reinforcing which context the user is operating in.

### Edge Cases

1. **Resources owned by multiple companies** -- Not currently possible in manifest schema. Each resource belongs to exactly one company.
2. **Public workers in company context** -- Always show public workers, but badge them as "Shared" to distinguish from company-owned workers.
3. **Cross-company projects** -- If a project's `repoPath` is not in any company's manifest `repos`, show it only in "All" view.
4. **Company with no resources** -- golden-thread has no workers, no settings, no knowledge. Show it in the company list but display an empty state: "No resources configured."
5. **Manifest out of sync** -- Desktop should reload manifest on file change (add `manifest.yaml` to file watcher). If manifest parse fails, fall back to no filtering with a warning toast.

## Implementation Priority

1. **Parse manifest.yaml** -- New Rust command, TypeScript types (prerequisite for everything)
2. **Company context state** -- React context/store with `activeCompany` (prerequisite for filtering)
3. **Company picker UI** -- Top bar or sidebar component
4. **Filter existing views** -- Workers, projects, settings (use manifest data)
5. **Credential masking** -- Settings file content redaction (security-critical)
6. **Knowledge scoping** -- Company-aware knowledge browser
7. **Search collection routing** -- qmd collection auto-selection
