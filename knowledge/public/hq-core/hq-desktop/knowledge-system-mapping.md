# Knowledge System to Desktop UX Mapping

Maps HQ's knowledge repository structure, symlink resolution, INDEX.md hierarchy, company-scoped knowledge, and qmd search collections to Desktop browsing, navigation, and search UX.

---

## 1. Knowledge Directory Layout

HQ knowledge is distributed across three tiers:

### Tier 1: HQ-Level Knowledge (`knowledge/`)

```
knowledge/
├── public/                    # Shared knowledge bases (symlinks to git repos)
│   ├── Ralph/                → repos/public/ralph-methodology/docs
│   ├── ai-security-framework/→ repos/public/knowledge-ai-security
│   ├── curious-minds/        → repos/public/knowledge-curious-minds
│   ├── design-styles/        → repos/public/knowledge-design-styles
│   ├── dev-team/             → repos/public/knowledge-dev-team
│   ├── hq/                   → repos/public/knowledge-hq-core (alias)
│   ├── hq-core/              → repos/public/knowledge-hq-core
│   ├── loom/                 → repos/public/knowledge-loom
│   ├── pr/                   → repos/public/knowledge-pr
│   ├── projects/             → repos/public/knowledge-projects
│   ├── workers/              → repos/public/knowledge-workers
│   └── INDEX.md              # Navigation index (not a symlink)
└── private/                   # Private knowledge bases
    └── linear/               → repos/private/knowledge-linear
```

### Tier 2: Company-Scoped Knowledge (`companies/{co}/knowledge/`)

Each company directory contains a knowledge subdirectory that is its own git repo (not a symlink -- these are actual cloned repos with `.git/` inside):

| Company | Knowledge Path | Git Repo | File Count |
|---------|---------------|----------|------------|
| {company} | `companies/{company}/knowledge/` | Own repo (has `.git/`) | ~40 files across 8 subdirs |
| {company} | `companies/{company}/knowledge/` | Own repo (has `.git/`) | ~12 files across 3 subdirs |
| personal | `companies/personal/knowledge/` | Own repo (has `.git/`) | ~8 files |
| golden-thread | N/A | No knowledge dir | 0 |

### Tier 3: Worker-Embedded Knowledge

Workers carry domain knowledge in their `worker.yaml` `instructions:` block and any markdown files in their directory. These are not browseable as "knowledge" per se, but contain accumulated learnings. Relevant for Desktop's knowledge search scope.

---

## 2. Symlink-to-Repo Mapping

### Resolution Table

| Symlink Path | Target Repo | Repo Type |
|-------------|-------------|-----------|
| `knowledge/public/Ralph/` | `repos/public/ralph-methodology/docs` | Public |
| `knowledge/public/ai-security-framework/` | `repos/public/knowledge-ai-security` | Public |
| `knowledge/public/curious-minds/` | `repos/public/knowledge-curious-minds` | Public |
| `knowledge/public/design-styles/` | `repos/public/knowledge-design-styles` | Public |
| `knowledge/public/dev-team/` | `repos/public/knowledge-dev-team` | Public |
| `knowledge/public/hq/` | `repos/public/knowledge-hq-core` | Public (alias) |
| `knowledge/public/hq-core/` | `repos/public/knowledge-hq-core` | Public |
| `knowledge/public/loom/` | `repos/public/knowledge-loom` | Public |
| `knowledge/public/pr/` | `repos/public/knowledge-pr` | Public |
| `knowledge/public/projects/` | `repos/public/knowledge-projects` | Public |
| `knowledge/public/workers/` | `repos/public/knowledge-workers` | Public |
| `knowledge/private/linear/` | `repos/private/knowledge-linear` | Private |

### Alias Detection

`knowledge/public/hq/` and `knowledge/public/hq-core/` point to the same repo (`repos/public/knowledge-hq-core`). Desktop should:
- Detect aliases (two symlinks resolving to the same canonical path)
- Display one entry with an "also known as" note, not duplicate entries
- Prefer the canonical name (`hq-core`) over the alias (`hq`)

### Company Knowledge: Not Symlinks

Company knowledge directories (`companies/*/knowledge/`) are NOT symlinks. They are actual git repositories cloned directly into the company directory structure. They have `.git/` inside them. Desktop must handle these differently:
- No symlink resolution needed
- Git status is available directly (check `.git/` presence)
- Knowledge repo identity comes from the directory path, not a symlink target

---

## 3. Symlink Resolution in Rust/Tauri Context

### Challenge

Rust's `std::fs` follows symlinks transparently by default:
- `fs::read_dir(path)` follows symlinks and lists target contents
- `fs::metadata(path)` follows symlinks (returns metadata of target)
- `fs::symlink_metadata(path)` does NOT follow symlinks (returns symlink metadata)
- `fs::read_link(path)` returns the symlink target path

### Recommended Approach for Desktop

```rust
use std::fs;
use std::path::PathBuf;

#[derive(Debug, Serialize)]
pub struct KnowledgeRepo {
    pub name: String,              // "Ralph", "hq-core", etc.
    pub display_path: String,      // "knowledge/public/Ralph/"
    pub canonical_path: String,    // Resolved absolute path (after following symlink)
    pub repo_path: Option<String>, // "repos/public/ralph-methodology/docs" (relative)
    pub is_symlink: bool,          // true for knowledge/public/*, false for company knowledge
    pub is_alias: bool,            // true if another entry points to same canonical_path
    pub alias_of: Option<String>,  // name of the canonical entry this aliases
    pub visibility: String,        // "public" or "private"
    pub scope: String,             // "hq" or company ID ("{company}", etc.)
    pub has_git: bool,             // Whether .git exists in resolved path
    pub has_index: bool,           // Whether INDEX.md exists
    pub file_count: usize,         // Number of non-hidden files (recursive)
}
```

### Symlink Resolution Algorithm

```
for each entry in knowledge/public/ and knowledge/private/:
  1. Check if entry is symlink: fs::symlink_metadata(path).is_symlink()
  2. If symlink: resolve target with fs::read_link(path)
  3. Canonicalize with fs::canonicalize(path) to get absolute resolved path
  4. Extract repo name from target path (e.g., repos/public/knowledge-hq-core → hq-core)
  5. Check for aliases: if canonical_path matches another entry, mark as alias

for each company in companies/:
  1. Check if companies/{co}/knowledge/ exists
  2. Check if .git/ exists inside it
  3. Treat as standalone knowledge repo (not symlink)
```

### Tauri FS Plugin Behavior

The `@tauri-apps/plugin-fs` `readDir()` also follows symlinks transparently. The existing `use-hq-files.ts` hook does NOT distinguish symlinks from real directories. For the knowledge browser, this is mostly fine (content is accessible), but Desktop should:
- Show a link icon on symlinked knowledge bases (visual distinction)
- Show the repo target path in detail view
- Show git status of the target repo (not the HQ repo)

### Edge Cases

1. **Broken symlinks:** If a repo is deleted but the symlink remains, `fs::read_dir()` will fail. Desktop should catch this and show a "broken link" indicator.
2. **Relative vs absolute symlinks:** HQ uses both relative (`../../repos/public/knowledge-hq-core`) and absolute (`~/Documents/HQ/repos/public/knowledge-curious-minds`) symlinks. `fs::canonicalize()` handles both.
3. **Nested symlinks:** Some knowledge repos contain internal symlinks (e.g., {company} CDP knowledge has `audit/` and `flow-migration/` symlinks). Desktop should resolve these recursively.

---

## 4. INDEX.md Navigation Pattern

### How INDEX.md Works

INDEX.md files are auto-generated navigation indexes placed at key directory levels. They follow a standard format:

```markdown
# {Directory Name}

> Auto-generated. Updated: {YYYY-MM-DD}

| Name | Description |
|------|-------------|
| `item/` | 1-line description |
| `file.md` | First heading from file |
```

### INDEX.md Locations in Knowledge System

| Location | Exists | Content |
|----------|--------|---------|
| `knowledge/public/INDEX.md` | Yes | Lists all public knowledge bases |
| `knowledge/private/INDEX.md` | No | Missing -- only 1 entry (linear) |
| `companies/{company}/knowledge/INDEX.md` | Yes | Lists LR knowledge files/dirs |
| `companies/{company}/knowledge/INDEX.md` | Yes | Lists {company} knowledge files/dirs |
| `companies/personal/knowledge/INDEX.md` | Yes | Lists personal knowledge files |

### Navigation Pattern for Desktop

INDEX.md provides a pre-built table of contents for each knowledge directory. Desktop can use this in two ways:

**Option A: Parse INDEX.md as TOC**
- Read INDEX.md, extract the markdown table
- Use rows as navigation items (name + description)
- Render as a list view with descriptions
- Advantage: Descriptions are pre-extracted, no need to parse each file
- Disadvantage: INDEX.md can be stale if not regenerated after changes

**Option B: File system scan with INDEX.md enrichment**
- Scan directory contents via `fs::read_dir()`
- If INDEX.md exists, parse it for descriptions
- Merge FS entries with INDEX descriptions
- Show entries that exist on FS but not in INDEX as "unindexed"
- Advantage: Always up-to-date file list, descriptions where available
- Recommended approach for Desktop

### INDEX.md Variants

| Directory | Extra Column | Notes |
|-----------|-------------|-------|
| `projects/` | Status (active/completed/archived) | |
| `workspace/orchestrator/` | Progress (e.g. "5/11 45%") | |
| `workspace/reports/` | Date | |
| All others | Standard (Name, Description) | |

### Excluded from qmd

INDEX.md files are excluded from qmd indexing via `.qmdignore`. They are navigation aids, not searchable content. Desktop should NOT include INDEX.md in search results.

---

## 5. Knowledge Entities for Desktop

### Entity Hierarchy

```
KnowledgeBase (top-level grouping)
├── name: "Ralph", "hq-core", "{company}", etc.
├── scope: "hq-public" | "hq-private" | "company:{id}"
├── repo_info: { path, is_symlink, target, git_status }
├── index: parsed INDEX.md (if exists)
└── files: KnowledgeFile[]
    ├── name: "architecture.md"
    ├── path: absolute path
    ├── type: "markdown" | "yaml" | "json" | "directory"
    ├── description: from INDEX.md or first heading
    ├── size: bytes
    ├── modified: timestamp
    └── children: KnowledgeFile[] (if directory)
```

### What Desktop Needs to Display

**Knowledge Base List View:**
- Name (e.g., "Ralph", "HQ Core", "{company}")
- Scope badge (Public / Private / Company: {name})
- File count
- Last modified date
- Git status indicator (clean / dirty / untracked)
- Symlink indicator (for HQ-level knowledge)

**Knowledge Base Detail View:**
- INDEX.md rendered as navigation sidebar
- File tree (expandable directory view)
- File selection opens rendered markdown
- Breadcrumb navigation: Knowledge > {Base} > {Subdir} > {File}
- Git status: branch, last commit, dirty files count

**Individual File View:**
- Rendered markdown (syntax-highlighted code blocks)
- Raw source toggle
- File metadata (path, size, last modified)
- "Open in editor" action (via `open` command or VS Code)
- Navigation: prev/next file in same directory

---

## 6. Company Knowledge Isolation

### Scoping Rules

Per `manifest.yaml`, each company owns its knowledge:

```yaml
{company}:
  knowledge: companies/{company}/knowledge/
  qmd_collections: [{company}, {product}]


{company}:
  knowledge: companies/{company}/knowledge/
  qmd_collections: [{company}]

personal:
  knowledge: companies/personal/knowledge/
  qmd_collections: [personal]
```

### Desktop Isolation Rules

1. **Company filter in UI**: When user selects a company context (e.g., "{company}"), the knowledge browser should:
   - Show that company's knowledge base
   - Show HQ-level public knowledge (always accessible)
   - Hide other companies' knowledge bases
   - Scope qmd search to that company's collections

2. **No cross-contamination**: Knowledge files from one company should never appear in another company's context. This is enforced by:
   - File system isolation (separate directories)
   - qmd collection scoping (separate indexes)
   - Desktop UI filtering

3. **HQ-level knowledge is universal**: `knowledge/public/*` and `knowledge/private/*` are accessible regardless of active company context. These contain framework docs (Ralph, workers, dev-team) that apply everywhere.

### Company Knowledge Display Grouping

```
Knowledge Browser
├── HQ Knowledge (always visible)
│   ├── Public
│   │   ├── Ralph
│   │   ├── HQ Core
│   │   ├── Dev Team
│   │   ├── Workers
│   │   ├── Design Styles
│   │   ├── AI Security
│   │   ├── Loom
│   │   ├── Projects
│   │   ├── PR
│   │   └── Curious Minds
│   └── Private
│       └── Linear
├── Company: {company} (when LR context active)
│   ├── Architecture
│   ├── Database Schema
│   ├── Infrastructure
│   ├── {PRODUCT}/
│   ├── Voyage SMS/
│   ├── CDP/
│   ├── GTM/
│   └── ...
│   ├── Brand Guidelines
│   ├── Master Narrative
│   ├── CRO/
│   └── ...
└── [other companies filtered by context]
```

---

## 7. qmd Collection Structure

### Current Collections

| Collection | Source Path | Pattern | Files | Contexts | Purpose |
|-----------|------------|---------|-------|----------|---------|
| `hq` | HQ root | `**/*.md` | 2,285 | 7 | All HQ markdown |
| `{product}` | {PRODUCT} monorepo | `**/*.{ts,tsx,js,jsx,md,json,yaml,yml,sql,css,prisma}` | 3,078 | 3 | {PRODUCT} codebase |
| `{company}` | LR knowledge | `**/*.md` | 121 | 1 | LR company knowledge |
| `{company}` | {company} knowledge | `**/*.md` | 15 | 1 | {company} company knowledge |
| `personal` | Personal knowledge | `**/*.md` | 8 | 1 | Personal knowledge |

### Collection Contexts

qmd supports adding "context" descriptions to collections and paths within them. These provide semantic anchoring for search results. The `hq` collection has 7 contexts:

| Path | Context Description |
|------|-------------------|
| `/` | "HQ knowledge base: company knowledge, AI worker definitions..." |
| `/knowledge` | "HQ-level knowledge bases: Ralph coding methodology..." |
| `/.claude/commands` | "Claude Code slash commands: 30 agent skills..." |
| `/companies` | "Five company-scoped directories..." |
| `/workers` | "AI worker definitions with YAML configs..." |
| `/projects` | "Project PRDs and READMEs..." |
| `/workspace` | "Runtime workspace: session threads, checkpoints..." |

### qmd CLI Commands to Expose in Desktop

| Command | Purpose | Desktop UX |
|---------|---------|-----------|
| `qmd search "<query>" -c {collection} --json -n {count}` | BM25 keyword search | Search bar with "Keyword" mode |
| `qmd vsearch "<query>" -c {collection} --json -n {count}` | Vector similarity search | Search bar with "Semantic" mode |
| `qmd query "<query>" -c {collection} --json -n {count}` | Hybrid search + reranking | Search bar with "Hybrid" mode (default) |
| `qmd collection list` | List all collections | Collection picker dropdown |
| `qmd status` | Index health + stats | Status indicator in search bar |
| `qmd ls {collection}` | List files in collection | Alternative to FS browsing |
| `qmd get {docid}` | Retrieve full document | File viewer (by document ID) |

### Search Result Format (JSON mode)

```json
[
  {
    "docid": "#abc123",
    "score": 0.85,
    "file": "qmd://hq/knowledge/public/Ralph/methodology.md",
    "title": "Ralph Methodology",
    "context": "HQ-level knowledge bases: Ralph coding methodology...",
    "snippet": "Relevant excerpt with matched terms..."
  }
]
```

Desktop needs to parse:
- `file`: Extract display path by removing `qmd://{collection}/` prefix
- `score`: Display as relevance indicator (bar or percentage)
- `title`: Primary display text
- `snippet`: Preview text with highlighting
- `context`: Show as collection/section badge
- `docid`: Used for `qmd get` to retrieve full document

### qmd Integration Requirements for Rust

**Option A: Shell out to qmd CLI (recommended for v1)**

```rust
use std::process::Command;

#[tauri::command]
pub fn qmd_search(
    query: String,
    collection: Option<String>,
    mode: Option<String>,  // "keyword" | "semantic" | "hybrid"
    limit: Option<u32>,
) -> Result<JsonValue, String> {
    let cmd = match mode.as_deref() {
        Some("keyword") | None => "search",
        Some("semantic") => "vsearch",
        Some("hybrid") => "query",
        _ => "search",
    };

    let mut args = vec![cmd.to_string(), query, "--json".to_string()];

    if let Some(c) = collection {
        args.push("-c".to_string());
        args.push(c);
    }

    if let Some(n) = limit {
        args.push("-n".to_string());
        args.push(n.to_string());
    }

    let output = Command::new("qmd")
        .args(&args)
        .output()
        .map_err(|e| format!("Failed to run qmd: {}", e))?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    serde_json::from_str(&stdout)
        .map_err(|e| format!("Failed to parse qmd output: {}", e))
}
```

**Option B: qmd MCP server (future)**

qmd supports MCP mode (`qmd mcp`). Desktop could potentially connect to qmd as an MCP client. This would provide:
- Persistent connection (no shell spawn overhead)
- Streaming results
- Index update notifications

However, MCP client implementation in Tauri/Rust is non-trivial. Recommend starting with Option A (shell out) and upgrading to MCP in a future epic.

### Collection Picker UX

The collection picker should:
1. Default to "All" (no `-c` flag, searches across all collections)
2. Show company-specific collections when company context is active
3. Show per-collection file counts
4. Show last-indexed timestamp
5. Allow multi-select for cross-collection search

Suggested grouping:
```
Collection Picker
├── All Collections (default)
├── HQ (2,285 files)
├── ─── Company Collections ───
├── {company} (121 files)
├── {company} (15 files)
├── Personal (8 files)
├── ─── Codebase Collections ───
└── {PRODUCT} (3,078 files)
```

---

## 8. Rust Commands Needed (Knowledge-Specific)

Building on the US-003 audit, the knowledge browser needs these Rust commands:

### New Commands

| Command | Priority | Purpose |
|---------|----------|---------|
| `list_knowledge_repos` | P0 | List all knowledge bases with symlink resolution, scope, git status |
| `get_knowledge_tree` | P0 | Build file tree for a knowledge base with INDEX.md enrichment |
| `qmd_search` | P0 | Wrap qmd CLI for search (keyword/semantic/hybrid) |
| `list_qmd_collections` | P1 | List available qmd collections with stats |
| `resolve_symlink` | P1 | Resolve a symlink path and return target + metadata |
| `render_markdown` | P2 | Server-side markdown rendering (or do client-side) |
| `get_knowledge_git_status` | P2 | Git status for a knowledge repo (branch, dirty, last commit) |

### Existing Commands That Help

| Command | How It Helps Knowledge Browser |
|---------|-------------------------------|
| `read_dir_tree` | Can scan knowledge directories (follows symlinks transparently) |
| `read_file_content` | Can read markdown files for rendering |
| `read_yaml` | Can read worker.yaml for embedded knowledge |
| `list_companies` | Provides company list for knowledge scoping (needs manifest enrichment) |

---

## 9. Data Flow: Knowledge Browser Architecture

```
User Action                    Rust Backend              Frontend State
───────────────────────────────────────────────────────────────────────
Open Knowledge Browser    →    list_knowledge_repos()   →    KnowledgeRepo[]
                               (reads knowledge/,
                                companies/*/knowledge/,
                                resolves symlinks)

Select Knowledge Base     →    get_knowledge_tree()     →    FileNode[] with
                               (reads dir + INDEX.md)         descriptions

Select File               →    read_file_content()      →    Raw markdown string
                               (reads file content)          → Client-side render

Search                    →    qmd_search()             →    SearchResult[]
                               (shells out to qmd CLI)

Change Collection         →    list_qmd_collections()   →    Collection[]
                               (shells out to qmd)

Change Company Context    →    Filter KnowledgeRepo[]   →    Filtered list
                               (client-side filter          (company knowledge
                                by scope field)              + HQ public always)
```

---

## 10. Open Questions / Decisions for Child PRD

1. **Markdown rendering**: Client-side (react-markdown) vs server-side (Rust)? Client-side is simpler and more flexible. Recommend react-markdown with syntax highlighting plugin.

2. **Search debounce**: How long to wait after keystroke before firing qmd search? Recommend 300ms for keyword, 500ms for semantic (which is slower).

3. **qmd availability**: What happens if qmd is not installed? Desktop should detect qmd presence (`which qmd`) and show a "Search unavailable - install qmd" message. Knowledge browsing (file-based) should still work.

4. **Knowledge editing**: Should Desktop support editing knowledge files? For v1, no -- read-only browsing + search. Editing happens in Claude Code or a text editor. Desktop can offer "Open in editor" action.

5. **Git operations**: Should Desktop show git diff for dirty knowledge repos? For v1, show dirty/clean status only. Full git integration (commit, push) is out of scope.

6. **Large files**: Some knowledge files are 20KB+ (e.g., `verified-site-facts.md` at 21KB). Virtual scrolling or lazy rendering may be needed for the markdown viewer.

7. **Binary files**: Knowledge repos may contain images. Desktop's markdown renderer should support image display (inline or link).
