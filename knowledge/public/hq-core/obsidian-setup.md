---
type: reference
domain: [engineering, operations]
status: canonical
tags: [obsidian, doc-viewer, knowledge-management, setup]
relates_to: [index-md-spec.md]
---

# Obsidian as HQ Doc Viewer

HQ ships with a pre-configured `.obsidian/` vault. Open the HQ folder in Obsidian for instant browsing.

## Quick Start

1. Install [Obsidian](https://obsidian.md)
2. Open vault → select your HQ directory
3. Done — INDEX.md opens in reading mode

## What's Visible

| Directory | Content |
|-----------|---------|
| `companies/` | Company knowledge, projects, data, workers |
| `knowledge/` | Public + private knowledge bases |
| `workers/` | Worker definitions and skills |
| `projects/` | Personal/HQ projects |
| `workspace/reports/` | Generated reports |
| `workspace/social-drafts/` | Content pipeline |
| Root | INDEX.md, USER-GUIDE.md, CHANGELOG.md |

## What's Excluded

Large, noisy, or non-markdown directories excluded from indexing:

| Directory | Why |
|-----------|-----|
| `repos/` | Cloned repos — independent git repos |
| `node_modules/` | Dependencies |
| `.claude/` | Commands/skills for Claude, not human browsing |
| `workspace/threads/` | Session thread JSON files (1000+) |
| `workspace/orchestrator/` | Execution state |
| `workspace/checkpoints/` | Session checkpoints |
| `settings/` | Credentials (gitignored) |
| `modules/` | Synced module clones |

Edit exclusions in `.obsidian/app.json` → `userIgnoreFilters`.

## Features

### Graph View

Color-coded by folder:
- **Blue** — `companies/` (company knowledge)
- **Green** — `knowledge/` (shared knowledge bases)
- **Orange** — `workers/` (worker definitions)
- **Amber** — `projects/` (project docs)
- **Gray** — `workspace/` (reports, drafts)

Orphan nodes hidden by default. Open via Ctrl/Cmd+G.

### Frontmatter Properties

HQ knowledge files use YAML frontmatter (`type`, `domain`, `status`, `tags`, `relates_to`). These render in Obsidian's Properties panel — click any tag or domain value to find related docs.

### Bookmarks

Six default bookmarks: INDEX.md, USER-GUIDE.md, and folders for knowledge, companies, workers, projects. Access via the bookmark icon in the left sidebar.

### CSS Theme

`hq-reading.css` snippet provides clean table styling (for INDEX.md files), refined code blocks, and subtle hover effects. Works in both light and dark mode.

## Design Philosophy

- **Reading mode by default** — Obsidian is the viewer, Claude Code is the editor
- **Standard markdown links** — `[text](path)` format preserved (works in CLI, GitHub, everywhere)
- **No wiki-links** — avoids lock-in to Obsidian-specific syntax
- **No community plugins required** — works out of the box with core plugins only

## Recommended Community Plugins

Optional enhancements (install via Settings → Community Plugins):

| Plugin | What it adds |
|--------|-------------|
| Dataview | Query frontmatter fields across all docs |
| Folder Note | Makes INDEX.md behave as a folder's landing page |
| Tag Wrangler | Rename/merge tags across vault |
| Minimal Theme | Clean, customizable theme |
| Iconize | Add icons to folders in the file explorer |

## Customization

- **Exclusions**: `.obsidian/app.json` → `userIgnoreFilters`
- **Graph colors**: `.obsidian/graph.json` → `colorGroups`
- **CSS**: `.obsidian/snippets/hq-reading.css` (or add your own snippets)
- **Bookmarks**: Add via right-click in file explorer
- **Theme**: Settings → Appearance → select system/light/dark

## For Kit Users

The `.obsidian/` config ships with hq-starter-kit. Your personal customizations (installed plugins, themes, workspace layout) are gitignored and won't be overwritten by `/update-hq`.
