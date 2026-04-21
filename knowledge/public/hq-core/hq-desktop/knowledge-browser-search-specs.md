# Knowledge Browser & Search UI Specs

**Story:** US-014 - Design knowledge browser & search UI specs
**Date:** 2026-02-11
**Depends on:** US-013 (Knowledge System to Desktop UX Mapping)

Detailed view specifications for the knowledge tree browser, markdown viewer, search interface, and collection scoping UI. All specs assume the dark glass morphism design language documented in the US-005 UI component audit.

---

## 1. Knowledge Tree Browser

### 1.1 Overview

The knowledge tree is an expandable directory view that lets the user navigate through HQ's knowledge hierarchy. It replaces the current "Knowledge browser coming soon..." placeholder in `empire-view.tsx`.

### 1.2 Entry Point

The Knowledge glass card on the Empire root view becomes clickable (currently it has no `onClick`). Clicking it drills into the knowledge browser using the same drill-path pattern as Workers, Companies, and Projects:

```
Empire Root → [click Knowledge card] → Knowledge Browser (Level 1)
           → [click a knowledge base] → Knowledge Base Detail (Level 2)
           → [select a file] → Markdown Viewer (Level 2, panel)
```

### 1.3 Knowledge Browser (Level 1) — `KnowledgeDrill`

**Component:** `knowledge-drill.tsx`
**Pattern:** Same as `WorkersDrill` — `DrillHeader` + grouped list of `GlassCard` items.

**Layout:**

```
┌─────────────────────────────────────────────────┐
│ ← Knowledge                                     │
│   {count} bases • {totalFiles} files             │
│                                                  │
│ ┌─────────────────────────────────────────────┐  │
│ │ 🔍 Search knowledge...          [Hybrid ▾]  │  │
│ │                               [All ▾]       │  │
│ └─────────────────────────────────────────────┘  │
│                                                  │
│ HQ KNOWLEDGE                                     │
│ ┌──────────┐ ┌──────────┐ ┌──────────┐          │
│ │ Ralph    │ │ HQ Core  │ │ Dev Team │          │
│ │ 12 files │ │ 8 files  │ │ 6 files  │          │
│ └──────────┘ └──────────┘ └──────────┘          │
│ ┌──────────┐ ┌──────────┐ ┌──────────┐          │
│ │ Workers  │ │ Design   │ │ Loom     │          │
│ │ 4 files  │ │ 3 files  │ │ 5 files  │          │
│ └──────────┘ └──────────┘ └──────────┘          │
│                                                  │
│ COMPANY: {company}                             │
│ ┌──────────┐ ┌──────────┐                        │
│ │ LR Know  │ │ {PRODUCT}      │                        │
│ │ 40 files │ │ (codebase│                        │
│ └──────────┘ └──────────┘                        │
│                                                  │
│ PRIVATE                                          │
│ ┌──────────┐                                     │
│ │ Linear   │                                     │
│ │ 3 files  │                                     │
│ └──────────┘                                     │
└─────────────────────────────────────────────────┘
```

**Grouping logic:**

| Group | Source | Condition |
|-------|--------|-----------|
| HQ Knowledge | `knowledge/public/*` | Always visible |
| Company: {name} | `companies/{co}/knowledge/` | Visible when that company's context is active, or when no company filter is set |
| Private | `knowledge/private/*` | Always visible |

**Each knowledge base card shows:**
- Name (derived from directory name, title-cased)
- File count (non-hidden files, recursive)
- Scope badge: `Public`, `Private`, or company name
- Symlink indicator icon (chain-link icon) for HQ-level symlinked knowledge
- Git status dot: green (clean), yellow (dirty), gray (no git)
- Last modified timestamp

**Data source:** `list_knowledge_repos` Rust command (defined in US-013 section 8).

### 1.4 Knowledge Base Detail (Level 2) — `KnowledgeBaseDetail`

**Component:** `knowledge-base-detail.tsx`
**Pattern:** Split-pane layout — tree sidebar on left, content viewer on right.

**Layout:**

```
┌─────────────────────────────────────────────────┐
│ ← Ralph                                         │
│   Public knowledge base • 12 files               │
│                                                  │
│ ┌──────────────────┬────────────────────────────┐│
│ │ FILE TREE        │ CONTENT                    ││
│ │                  │                            ││
│ │ ▾ docs/          │  # Ralph Methodology       ││
│ │   methodology.md │                            ││
│ │   principles.md  │  Pick a task. Complete it. ││
│ │   patterns.md    │  Commit it.                ││
│ │ ▾ examples/      │                            ││
│ │   migration.md   │  ## Core Loop              ││
│ │   crud-api.md    │                            ││
│ │ README.md        │  1. Select task from PRD   ││
│ │ INDEX.md (nav)   │  2. Classify task type     ││
│ │                  │  3. Route to workers...    ││
│ │                  │                            ││
│ │                  │                            ││
│ │                  │                            ││
│ └──────────────────┴────────────────────────────┘│
│                                                  │
│ ┌─ METADATA ────────────────────────────────────┐│
│ │ Repo: repos/public/ralph-methodology          ││
│ │ Branch: main • Clean • Last commit: 2h ago    ││
│ └───────────────────────────────────────────────┘│
└─────────────────────────────────────────────────┘
```

**File tree panel (left, 30% width):**

- Expandable directory tree using the same `FileTreeNode` pattern from `files-sidebar.tsx`
- INDEX.md displayed at top if present, with a special "nav" badge (it is the table of contents)
- Directories are expandable/collapsible; start collapsed except first level
- Files show icons by extension: `.md` (document), `.yaml` (gear), `.json` (braces), directory (folder)
- Selected file is highlighted with `glass-surface-elevated` background
- Clicking a file loads it in the content panel
- If INDEX.md exists, parse its table to show descriptions next to file names in the tree (tooltip or inline subtitle)

**Content panel (right, 70% width):**

- Renders selected file as markdown (details in section 2)
- Shows "Select a file to view" placeholder when no file is selected
- Breadcrumb at top: Knowledge > {Base} > {Subdir} > {File}

**Metadata bar (bottom):**

- Repo path (relative to HQ root)
- Git branch name
- Git status: "Clean" / "3 dirty files"
- Last commit relative timestamp
- "Open in Editor" button (invokes system `open` command on the file)

**Data sources:**
- `get_knowledge_tree` for file tree with INDEX.md enrichment
- `read_file_content` for markdown content
- `get_knowledge_git_status` for repo metadata

### 1.5 INDEX.md Integration

INDEX.md files serve as pre-built tables of contents. The knowledge browser uses the **Option B** approach from US-013: file system scan with INDEX.md enrichment.

**Behavior:**
1. Scan directory via `get_knowledge_tree` (which calls `fs::read_dir`)
2. If INDEX.md exists in the directory, parse it for descriptions
3. Merge file system entries with INDEX descriptions
4. Display entries with descriptions as subtitle text in the file tree
5. Files on disk but not in INDEX.md appear as "unindexed" (no description, slightly dimmer)
6. INDEX.md itself appears in the tree with a "nav" badge, clickable to view as rendered markdown

**INDEX.md parsing (client-side):**

```typescript
interface IndexEntry {
  name: string        // File or directory name
  description: string // Extracted from INDEX.md table
}

function parseIndexMd(content: string): IndexEntry[] {
  // Find markdown table rows: | `name` | description |
  const rows = content.match(/\|\s*`([^`]+)`\s*\|\s*(.+?)\s*\|/g)
  return rows?.map(row => {
    const match = row.match(/\|\s*`([^`]+)`\s*\|\s*(.+?)\s*\|/)
    return match ? { name: match[1].replace(/\/$/, ''), description: match[2].trim() } : null
  }).filter(Boolean) as IndexEntry[]
}
```

---

## 2. Markdown Viewer

### 2.1 Rendering Approach

**Client-side rendering with `react-markdown`** (recommended in US-013 section 10).

**Dependencies:**
- `react-markdown` — core renderer
- `remark-gfm` — GitHub Flavored Markdown (tables, strikethrough, task lists)
- `rehype-highlight` or `rehype-prism-plus` — syntax highlighting for code blocks
- `rehype-slug` — heading anchors for in-document navigation

### 2.2 Component: `MarkdownViewer`

**File:** `components/empire/markdown-viewer.tsx`

**Props:**
```typescript
interface MarkdownViewerProps {
  content: string       // Raw markdown string
  filePath: string      // For "Open in Editor" action
  fileName: string      // Display name
  onNavigate?: (path: string) => void  // Handle relative link clicks
}
```

**Features:**

| Feature | Implementation |
|---------|---------------|
| Headings (h1-h6) | Rendered with appropriate text-white opacity scale: h1=90%, h2=80%, h3=70% |
| Code blocks | Syntax highlighted with a dark theme matching the glass aesthetic. Background: `rgba(255,255,255,0.03)`. Border: `rgba(255,255,255,0.06)`. Language label in top-right corner |
| Inline code | `rgba(255,255,255,0.08)` background, `text-white/80`, monospace |
| Tables | Glass-styled with `rgba(255,255,255,0.04)` header background, `rgba(255,255,255,0.02)` alternating rows, `rgba(255,255,255,0.06)` border |
| Links | `text-blue-400/80`, hover: `text-blue-300`. Internal links (relative paths) trigger `onNavigate`. External links open in system browser |
| Images | Displayed inline. Max width 100%. For images in knowledge repos, resolve relative paths against the file's directory |
| Task lists | Checkbox items rendered as styled checkboxes (read-only) |
| Blockquotes | Left border `rgba(255,255,255,0.15)`, indented, slightly dimmer text |
| Horizontal rules | `rgba(255,255,255,0.06)` border line |

**Toolbar (top of content panel):**

```
┌──────────────────────────────────────────────┐
│ methodology.md              [Raw] [Open] [↑] │
└──────────────────────────────────────────────┘
```

- File name (left)
- Raw/Rendered toggle button — switches between rendered markdown and raw source
- Open in Editor button — opens file in system editor (`open -a "Cursor" {path}` or fallback to `open {path}`)
- Scroll to top button (appears when scrolled down)

### 2.3 Internal Link Navigation

When a markdown file contains a relative link like `[see patterns](./patterns.md)` or `[architecture](../architecture.md)`:

1. Intercept the click via `onNavigate` callback
2. Resolve the relative path against the current file's directory
3. If the resolved path is within the current knowledge base, navigate the file tree to that file and render it
4. If the path is outside the knowledge base, attempt to find it in another knowledge base; if found, switch context
5. If the path cannot be resolved, show a toast: "File not found: {path}"

### 2.4 Large File Handling

Some knowledge files exceed 20KB (e.g., `verified-site-facts.md`). For files over 10KB of rendered content:

- Use virtual scrolling via `react-virtuoso` or a simpler approach: render the full markdown but wrap in a container with `overflow-y: auto` and `will-change: transform` for GPU-accelerated scrolling
- For extremely large files (>50KB), consider splitting into chunks: render the first 5KB immediately, then lazy-render subsequent sections as the user scrolls (intersection observer pattern)

Practical recommendation for v1: standard overflow scroll with the markdown rendered fully. Most knowledge files are under 20KB and modern browsers handle this fine. Add virtual scrolling only if performance issues surface.

---

## 3. Search Interface

### 3.1 Search Bar Component: `KnowledgeSearch`

**File:** `components/empire/knowledge-search.tsx`

**Layout:**

```
┌─────────────────────────────────────────────────┐
│ 🔍 Search knowledge...            [Mode ▾] [▾] │
│                                   Hybrid    All │
└─────────────────────────────────────────────────┘
```

**Elements:**
- Search input (left, takes most width)
- Mode selector dropdown (right of input)
- Collection picker dropdown (far right)

**Styling:**
- Glass inset background: `rgba(255,255,255,0.03)` with `blur(12px)`
- Border: `rgba(255,255,255,0.06)`, increases to `rgba(255,255,255,0.12)` on focus
- Placeholder text: `text-white/30`
- Input text: `text-white/80`
- Search icon: `text-white/30`, animates to `text-white/60` on focus
- Height: 40px
- Border radius: 12px (matches `--radius-button`)

### 3.2 Search Modes

Three modes mapped to qmd CLI commands:

| Mode | qmd Command | Label | Description | Debounce |
|------|------------|-------|-------------|----------|
| Keyword | `qmd search` | Keyword | Fast exact-match search (BM25) | 300ms |
| Semantic | `qmd vsearch` | Semantic | Conceptual similarity search | 500ms |
| Hybrid | `qmd query` | Hybrid | Combined BM25 + vector + reranking (best quality) | 500ms |

**Default mode:** Hybrid (best quality, acceptable latency for interactive use).

**Mode selector dropdown:**

```
┌─────────────────────┐
│ ● Hybrid (default)  │
│ ○ Keyword (fast)    │
│ ○ Semantic          │
└─────────────────────┘
```

Styled as a glass dropdown:
- Background: `rgba(25,25,25,0.95)` (glass-overlay tier)
- Border: `rgba(255,255,255,0.1)`
- Selected item has a small dot indicator
- Each option has a subtitle: "Best quality, slower" / "Fast exact match" / "Conceptual similarity"

### 3.3 Collection Picker

**Location:** Right of mode selector, or integrated as a second dropdown.

**Options (derived from `qmd collection list`):**

```
┌──────────────────────────┐
│ All Collections (default)│
│ ─── HQ ───               │
│ HQ (2,285 files)         │
│ ─── Company ───           │
│ {company} (121 files)  │
│ {company} (15 files)        │
│ Personal (8 files)       │
│ ─── Codebase ───          │
│ {PRODUCT} (3,078 files)        │
└──────────────────────────┘
```

**Behavior:**
- Default: "All Collections" (no `-c` flag, global search)
- When company context is active in the top bar, auto-select that company's collection
- Show file count per collection
- Grouped by category with section dividers
- Collection data cached on app start, refreshed on demand

**Data source:** `list_qmd_collections` Rust command.

### 3.4 Type-Ahead / Live Search

**Behavior:**

1. User types in search bar
2. After debounce period (300ms keyword, 500ms semantic/hybrid), fire search
3. Results appear below the search bar, pushing down the knowledge base grid
4. Results replace the knowledge base grid while search is active
5. Clearing the search input restores the knowledge base grid
6. Pressing Escape clears search and restores grid

**Loading state:**
- Subtle pulse animation on the search icon while query is in flight
- If results take >1s, show a "Searching..." indicator below the input

**Empty state:**
- "No results for '{query}' in {collection}" message
- Suggestion: "Try a different search mode or broader collection"

### 3.5 Search Results View

**Component:** `KnowledgeSearchResults`

**Layout:**

```
┌─────────────────────────────────────────────────┐
│ 12 results for "auth middleware" in HQ           │
│                                                  │
│ ┌───────────────────────────────────────────────┐│
│ │ Ralph Methodology                     0.92    ││
│ │ knowledge/public/Ralph/methodology.md         ││
│ │ ...the auth middleware pattern ensures that    ││
│ │ every request passes through validation...    ││
│ └───────────────────────────────────────────────┘│
│ ┌───────────────────────────────────────────────┐│
│ │ {PRODUCT} Architecture                      0.85    ││
│ │ knowledge/public/dev-team/{product}-arch.md         ││
│ │ ...auth is handled by the middleware stack    ││
│ │ at apps/function/src/middleware/...            ││
│ └───────────────────────────────────────────────┘│
│ ┌───────────────────────────────────────────────┐│
│ │ AI Security Framework                 0.78    ││
│ │ knowledge/public/ai-security/auth.md          ││
│ │ ...authentication tokens must be validated... ││
│ └───────────────────────────────────────────────┘│
│                                                  │
│ [Load more results]                              │
└─────────────────────────────────────────────────┘
```

**Each result card shows:**

| Field | Source | Display |
|-------|--------|---------|
| Title | `result.title` | Primary text, `text-white/90`, `text-sm` font weight medium |
| File path | `result.file` (strip `qmd://{collection}/` prefix) | `text-white/40`, `text-xs`, monospace |
| Snippet | `result.snippet` | `text-white/60`, `text-xs`, max 2 lines with ellipsis. Matched terms highlighted with `text-white/90` + subtle background `rgba(255,255,255,0.06)` |
| Score | `result.score` | Right-aligned, rendered as a horizontal bar or numeric value (0.00-1.00). Bar uses `--status-working` color scaled by score |
| Collection badge | Extracted from `result.file` prefix | Small pill badge: `text-xs`, e.g., "HQ", "{company}" |

**Result card styling:**
- Background: `rgba(255,255,255,0.03)` (glass-inset)
- Hover: `rgba(255,255,255,0.06)`
- Border: `rgba(255,255,255,0.04)`
- Border radius: 12px
- Padding: 12px 16px
- Gap between cards: 8px

**Click behavior:**
- Clicking a result navigates to that file in the knowledge base detail view
- The file tree expands to show the file's location
- The markdown viewer renders the file, scrolled to the matching section if possible

**Pagination:**
- Show first 10 results by default
- "Load more results" button at bottom fetches next 10
- Alternatively, infinite scroll with intersection observer

### 3.6 Search Score Display

Two options for displaying the relevance score:

**Option A: Relevance bar (recommended)**
- Thin horizontal bar (4px height, 40px width) next to each result
- Filled proportionally to score (0.0 = empty, 1.0 = full)
- Color: gradient from `rgba(255,255,255,0.2)` (low) to `#4ade80` (high)
- No numeric value shown (clean visual)

**Option B: Numeric + bar**
- Same bar as Option A, plus the numeric score as `text-white/30 text-xs`
- Use this if users want precise ranking visibility

Recommend starting with Option A for cleaner aesthetics. Add numeric on hover as a tooltip.

---

## 4. Navigation Pattern: Tree to File to Rendered Markdown

### 4.1 Full Navigation Flow

```
Empire Root
  └─ [Click "Knowledge" card]
     └─ Knowledge Browser (KnowledgeDrill)
        ├─ Search bar (inline, top)
        ├─ Knowledge base grid (grouped by scope)
        │  └─ [Click a knowledge base card]
        │     └─ Knowledge Base Detail (KnowledgeBaseDetail)
        │        ├─ File tree (left panel)
        │        │  └─ [Click a file]
        │        │     └─ Markdown Viewer (right panel)
        │        │        ├─ Rendered markdown
        │        │        ├─ [Click internal link]
        │        │        │  └─ Navigate to linked file (same view)
        │        │        └─ [Toggle Raw] → Raw source view
        │        └─ Metadata bar (bottom)
        └─ Search results (replaces grid when searching)
           └─ [Click a result]
              └─ Knowledge Base Detail (auto-navigated to file)
```

### 4.2 URL / State Schema

The drill-path extends the existing pattern in `empire-view.tsx`:

```typescript
// Current patterns:
// ['workers'] → WorkersDrill
// ['workers', 'backend-dev'] → WorkerDetail
// ['companies'] → CompaniesDrill
// ['projects'] → ProjectsDrill

// New knowledge patterns:
// ['knowledge'] → KnowledgeDrill
// ['knowledge', 'ralph'] → KnowledgeBaseDetail (with Ralph loaded)
// ['knowledge', 'ralph', 'docs/methodology.md'] → KnowledgeBaseDetail (file selected)
```

The third segment (file path) is passed as a prop to `KnowledgeBaseDetail`, which auto-selects that file in the tree and renders it.

### 4.3 Breadcrumb Component

**Location:** Top of the content panel in `KnowledgeBaseDetail`.

```
Knowledge > Ralph > docs > methodology.md
```

- Each segment is clickable
- "Knowledge" navigates back to `KnowledgeDrill`
- Knowledge base name navigates to `KnowledgeBaseDetail` root (no file selected)
- Directory segments expand/collapse tree to that level
- Current file is not clickable (active state)
- Styled with `text-white/40` for inactive segments, `text-white/70` for active, `>` separator in `text-white/20`

---

## 5. Collection Scoping UI

### 5.1 Company Context Integration

The `StatsHeader` component already has a company filter dropdown. The knowledge browser should respect this:

| Company Filter State | Knowledge Browser Behavior |
|---------------------|--------------------------|
| "All" | Show all knowledge bases (HQ public, HQ private, all companies) |
| "{company}" | Show HQ public + HQ private + {company} knowledge only |
| (etc.) | Same pattern per company |

**Search auto-scoping:**
- When company filter is set, the collection picker auto-selects that company's collection
- User can override by manually selecting a different collection
- When company filter changes, search collection resets to match

### 5.2 Collection Status Indicator

The search bar should show a small status indicator for qmd health:

| State | Indicator | Meaning |
|-------|-----------|---------|
| Ready | Green dot | qmd is installed and indexes are current |
| Stale | Yellow dot | Indexes exist but are >24h old |
| Unavailable | Red dot | qmd not found in PATH |
| Indexing | Pulse animation | qmd update is running |

**Data source:** `qmd status` command output, checked on knowledge browser mount.

**Fallback when qmd unavailable:**
- Search bar is visually disabled (dimmed, placeholder: "Search unavailable - qmd not installed")
- File-based browsing works normally
- No search results view

### 5.3 Multi-Collection Search (Future)

Not for v1, but the architecture should support it:
- Collection picker allows multi-select (checkboxes)
- Multiple collections searched in parallel
- Results merged and re-ranked by score
- Each result shows its source collection badge

For v1: single collection selection only.

---

## 6. Performance Considerations

### 6.1 Large Knowledge Bases

**Problem:** Some knowledge bases have 40+ files with nested directories. Scanning recursively can be slow.

**Mitigations:**

| Strategy | Implementation | When |
|----------|---------------|------|
| Lazy tree loading | Load top-level entries first; load subdirectory contents on expand | v1 |
| File count caching | Cache `file_count` per knowledge base in memory; refresh on file watcher event | v1 |
| Tree state persistence | Remember expanded/collapsed state per knowledge base across navigation | v1 |
| INDEX.md caching | Parse INDEX.md once and cache descriptions; invalidate on file change | v1 |

### 6.2 Search Performance

| Concern | Mitigation |
|---------|-----------|
| qmd CLI spawn overhead (~50-100ms per invocation) | Cache recent results keyed by (query, mode, collection). Invalidate on `qmd update` |
| Semantic search latency (~500ms-2s) | Show loading indicator immediately. Consider caching top queries |
| Rapid typing generating many requests | Debounce: 300ms for keyword, 500ms for semantic/hybrid. Cancel previous in-flight request when new one fires |
| Large result sets | Request only 10 results initially. "Load more" fetches next page with offset |

### 6.3 Markdown Rendering Performance

| Concern | Mitigation |
|---------|-----------|
| Large files (>20KB) rendering slowly | For v1: render fully with overflow scroll. Monitor performance. Add chunked rendering if needed |
| Syntax highlighting for large code blocks | Use `rehype-highlight` which highlights during the render pass. For code blocks >500 lines, consider collapsing with "Show full code" toggle |
| Many re-renders on navigation | Memoize rendered markdown with `useMemo(content, [content])`. Only re-render when file content changes |
| Image loading | Use lazy loading (`loading="lazy"` attribute). Show placeholder while loading |

### 6.4 Virtual Scrolling Decision

**For the file tree:** Not needed in v1. Even the largest knowledge base ({company}, ~40 files) produces a tree of ~100 nodes when fully expanded. Standard DOM rendering handles this fine.

**For search results:** Not needed in v1 with pagination (10 results per page). If switching to infinite scroll, add `react-virtuoso` for the result list.

**For the markdown viewer:** Not needed in v1. Standard overflow scroll with `will-change: transform` on the scroll container is sufficient. Re-evaluate if users report jank on files >50KB.

### 6.5 Data Fetching Strategy

```typescript
// Hooks architecture for knowledge browser

// Level 1: List all knowledge bases (called once, cached)
function useKnowledgeBases(): {
  bases: KnowledgeBase[]
  loading: boolean
  refresh: () => void
}

// Level 2: File tree for a specific knowledge base (called on drill-in)
function useKnowledgeTree(baseName: string): {
  tree: FileNode[]
  indexEntries: IndexEntry[]
  loading: boolean
}

// Level 2: File content (called on file select)
function useFileContent(filePath: string): {
  content: string
  loading: boolean
}

// Search (called on debounced query change)
function useKnowledgeSearch(query: string, mode: SearchMode, collection: string): {
  results: SearchResult[]
  loading: boolean
  hasMore: boolean
  loadMore: () => void
}

// Collection list (called once, cached)
function useQmdCollections(): {
  collections: QmdCollection[]
  status: 'ready' | 'stale' | 'unavailable' | 'indexing'
}
```

---

## 7. TypeScript Types

### 7.1 Knowledge Base Types

```typescript
interface KnowledgeBase {
  name: string              // "Ralph", "hq-core", "{company}"
  displayName: string       // Title-cased: "Ralph", "HQ Core", "{company}"
  scope: 'hq-public' | 'hq-private' | `company:${string}`
  repoPath: string          // Relative: "repos/public/ralph-methodology/docs"
  isSymlink: boolean        // true for knowledge/public/*, false for company knowledge
  isAlias: boolean          // true if duplicate entry pointing to same repo
  aliasOf?: string          // Canonical name if alias
  gitStatus: 'clean' | 'dirty' | 'no-git'
  dirtyFileCount?: number
  branch?: string
  lastCommit?: string       // ISO8601 timestamp
  fileCount: number
  hasIndex: boolean         // INDEX.md exists
  lastModified: string      // ISO8601 timestamp
}

interface FileNode {
  name: string
  path: string              // Absolute path
  relativePath: string      // Relative to knowledge base root
  type: 'file' | 'directory'
  extension?: string        // "md", "yaml", "json"
  size?: number             // Bytes
  description?: string      // From INDEX.md
  children?: FileNode[]     // If directory
  isUnindexed?: boolean     // In FS but not in INDEX.md
}

interface IndexEntry {
  name: string
  description: string
}
```

### 7.2 Search Types

```typescript
type SearchMode = 'keyword' | 'semantic' | 'hybrid'

interface SearchResult {
  docId: string             // qmd document ID (e.g., "#abc123")
  score: number             // 0.0 to 1.0
  title: string
  filePath: string          // Display path (qmd prefix stripped)
  absolutePath: string      // For navigation
  collection: string        // Source collection name
  snippet: string           // Matched excerpt
  context?: string          // Collection/section context
}

interface QmdCollection {
  name: string              // "hq", "{product}", "{company}", etc.
  fileCount: number
  lastIndexed?: string      // ISO8601
  category: 'hq' | 'company' | 'codebase'
}
```

---

## 8. Component Summary

### New Components to Create

| Component | File | Purpose |
|-----------|------|---------|
| `KnowledgeDrill` | `components/empire/knowledge-drill.tsx` | Level 1: Knowledge base grid with search |
| `KnowledgeBaseDetail` | `components/empire/knowledge-base-detail.tsx` | Level 2: Split-pane tree + viewer |
| `KnowledgeSearch` | `components/empire/knowledge-search.tsx` | Search bar with mode/collection pickers |
| `KnowledgeSearchResults` | `components/empire/knowledge-search-results.tsx` | Search result list |
| `MarkdownViewer` | `components/empire/markdown-viewer.tsx` | Rendered markdown with toolbar |
| `KnowledgeFileTree` | `components/empire/knowledge-file-tree.tsx` | Expandable file tree with INDEX enrichment |
| `KnowledgeBreadcrumb` | `components/empire/knowledge-breadcrumb.tsx` | Breadcrumb navigation |

### New Hooks to Create

| Hook | File | Purpose |
|------|------|---------|
| `useKnowledgeBases` | `hooks/use-knowledge-bases.ts` | Fetch and cache knowledge base list |
| `useKnowledgeTree` | `hooks/use-knowledge-tree.ts` | Fetch file tree for a knowledge base |
| `useFileContent` | `hooks/use-file-content.ts` | Fetch and cache file content |
| `useKnowledgeSearch` | `hooks/use-knowledge-search.ts` | Debounced search with mode/collection |
| `useQmdCollections` | `hooks/use-qmd-collections.ts` | Fetch collection list and status |

### Existing Components to Modify

| Component | Modification |
|-----------|-------------|
| `EmpireView` | Add `onClick` to Knowledge GlassCard; add `knowledge` case to drill router; add Level 2 routing for knowledge base + file |
| `StatsHeader` | No changes (company filter already exists, knowledge browser reads it) |

### New Rust Commands Required

(Defined in US-013 section 8, referenced here for completeness)

| Command | Priority |
|---------|----------|
| `list_knowledge_repos` | P0 |
| `get_knowledge_tree` | P0 |
| `qmd_search` | P0 |
| `list_qmd_collections` | P1 |
| `get_knowledge_git_status` | P2 |

---

## 9. Interaction Details

### 9.1 Keyboard Shortcuts

| Shortcut | Action | Scope |
|----------|--------|-------|
| `/` or `Cmd+F` | Focus search bar | Knowledge browser (any level) |
| `Escape` | Clear search / go back one level | Knowledge browser |
| `Cmd+Shift+R` | Toggle raw/rendered markdown | Markdown viewer |
| `Arrow Up/Down` | Navigate search results | Search results view |
| `Enter` | Open selected search result | Search results view |

### 9.2 Search Flow (Step-by-Step)

1. User opens Knowledge browser (Level 1)
2. Search bar is visible at top, above the knowledge base grid
3. User clicks search bar or presses `/`
4. Search bar gains focus, border brightens
5. User types query: "auth middleware"
6. After 500ms debounce (hybrid mode default), `qmd_search` fires
7. Search icon pulses while request is in flight
8. Results arrive; knowledge base grid fades out, results fade in
9. Result count shown: "8 results for 'auth middleware' in All"
10. User clicks a result
11. Navigates to KnowledgeBaseDetail with that file pre-selected
12. File tree expands to show the file; markdown viewer renders it
13. If user presses back, returns to search results (preserved)
14. If user clears search, grid reappears

### 9.3 File Tree Interactions

- Single click on file: select and render in viewer
- Single click on directory: expand/collapse
- Double click on file: open in external editor
- Right-click (future): context menu with "Open in editor", "Copy path", "View in terminal"

### 9.4 Transition Animations

- Grid to search results: cross-fade (200ms)
- Knowledge base card click to detail: slide-in from right (250ms, consistent with existing drill pattern)
- File selection in tree: instant render (no animation on content panel)
- Search loading: search icon rotation animation (subtle, 1s loop)
- Back navigation: slide-out to right (250ms)

---

## 10. Accessibility Notes

- Search bar has proper `aria-label="Search knowledge"`
- Search mode and collection pickers use `aria-haspopup="listbox"` and `aria-expanded`
- File tree uses `role="tree"`, directories use `role="treeitem"` with `aria-expanded`
- Search results use `role="listbox"` with `aria-activedescendant` for keyboard navigation
- Markdown viewer content is in a `role="article"` container
- All interactive elements are keyboard-focusable with visible focus rings
- Score bars have `aria-label="Relevance: {score * 100}%"`
