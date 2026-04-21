---
description: Audit and clean HQ to enforce current policies and migrate outdated structures
allowed-tools: Task, Read, Glob, Grep, Bash, Write, Edit, AskUserQuestion
argument-hint: [--audit | --migrate | --fix | --consolidate-learnings]
visibility: public
---

# /cleanup - HQ Maintenance

Audit HQ for policy violations, migrate outdated structures, and fix inconsistencies.

**User's input:** $ARGUMENTS

## Modes

- **No args / --audit**: Report issues only (default, safe)
- **--migrate**: Convert old formats to new (prd.json → README.md)
- **--fix**: Auto-fix simple issues (git cleanup, archive stale files)
- **--reindex**: Regenerate ALL INDEX.md files from disk (full rebuild)
- **--consolidate-learnings**: Deduplicate, merge, and reorganize learned rules across all target files
- **--consolidate-insights**: Deduplicate, merge, and flag stale insights in `workspace/insights/` and `companies/*/knowledge/insights/`

## The Job

1. Run audit checks
2. Report findings
3. If --migrate or --fix: propose changes, ask confirmation, execute

---

## Audit Checks

### 1. Project Structure

**Policy**: All projects in `projects/` folder with `README.md`

```bash
# Find projects with only prd.json (no README)
for dir in projects/*/; do
  if [[ -f "${dir}prd.json" && ! -f "${dir}README.md" ]]; then
    echo "MIGRATE: $dir has prd.json but no README.md"
  fi
done

# Find projects outside projects/ folder
find companies apps -name "prd.json" 2>/dev/null
```

**Violations**:
- prd.json without README.md → needs migration
- prd.json in companies/ or apps/ → needs relocation

### 2. Worker Registry

**Policy**: All workers indexed in `workers/registry.yaml`

```bash
# Find workers not in registry
for dir in workers/public/*/ workers/private/*/; do
  worker=$(basename "$dir")
  if ! grep -q "id: $worker" workers/registry.yaml; then
    echo "UNINDEXED: $worker"
  fi
done
```

### 3. Deprecated Directories

**Policy**: No apps/ directory (use projects/ or workers/)

```bash
# Check if apps/ still exists
if [[ -d "apps" ]]; then
  echo "DEPRECATED: apps/ directory still exists"
  ls apps/
fi
```

### 4. Git Status

**Policy**: Clean working tree, no orphaned deletions

```bash
git status --short
```

**Issues**:
- Deleted files not committed
- Untracked new files (should commit or ignore)
- Modified submodules

**Note:** Knowledge folders are symlinks to repos in `repos/public/` and `repos/private/` (gitignored). Symlinks themselves should be tracked by HQ git. Knowledge file changes are invisible to HQ git (they live in their own repos).

### 4b. Knowledge Repo Status

**Policy**: Knowledge repos should be clean (committed)

```bash
for symlink in knowledge/public/* knowledge/private/* companies/*/knowledge; do
  [ -L "$symlink" ] || continue
  repo_dir=$(cd "$symlink" && git rev-parse --show-toplevel 2>/dev/null) || continue
  dirty=$(cd "$repo_dir" && git status --porcelain)
  [ -z "$dirty" ] && continue
  echo "DIRTY: $symlink → $repo_dir"
done
```

**With --fix**: Auto-commit dirty knowledge repos:
```bash
(cd "$repo_dir" && git add -A && git commit -m "chore: cleanup commit")
```

### 5. Stale Threads & Checkpoints

**Policy**: Archive manual threads/checkpoints older than 30 days. Purge auto-checkpoints older than 14 days.

```bash
# Auto-checkpoints older than 14 days (purge, not archive)
find workspace/threads -name "T-*-auto-*.json" -mtime +14 2>/dev/null

# Stale manual threads (new format, 30 days)
find workspace/threads -name "*.json" -not -name "*-auto-*" -mtime +30 2>/dev/null

# Stale checkpoints (legacy format)
find workspace/checkpoints -name "*.json" -mtime +30 2>/dev/null
```

### 6. Worker State Machine

**Policy**: Workers should have state_machine section (Loom pattern)

```bash
# Find workers without state_machine
for f in workers/*/worker.yaml workers/public/dev-team/*/worker.yaml; do
  if [[ -f "$f" ]] && ! grep -q "state_machine:" "$f"; then
    echo "MISSING: $f lacks state_machine section"
  fi
done
```

### 7. Orphaned Skills

**Policy**: Skills only in `.claude/commands/` (not SKILL.md format)

```bash
# Find old SKILL.md format
find . -name "SKILL.md" -not -path "./repos/*"
```

### 8. Stale INDEX.md Files

**Policy**: INDEX.md files should exist and match directory contents. See `knowledge/public/hq-core/index-md-spec.md` for spec.

**Expected locations:**
- `projects/INDEX.md`
- `companies/{product}/knowledge/INDEX.md`
- `companies/{company}/knowledge/INDEX.md`
- `knowledge/public/INDEX.md`
- `workers/public/INDEX.md`
- `workers/private/INDEX.md`
- `workspace/orchestrator/INDEX.md`
- `workspace/reports/INDEX.md`
- `workspace/social-drafts/INDEX.md`

For each:
1. Check if INDEX.md exists → flag MISSING if not
2. Count entries in INDEX table vs actual directory contents → flag STALE if mismatch

**With --reindex or --fix**: Regenerate all INDEX.md files from disk per spec.

### 9. Manifest Completeness

**Policy**: Every company in `manifest.yaml` should have non-null values for all fields.

```bash
# Check for null values in manifest
grep -n "null" companies/manifest.yaml
```

**Violations**: Company with `knowledge: null`, empty settings when settings dir has files, etc.

**With --fix**: For each company with `knowledge: null`:
1. Create knowledge repo: `repos/private/knowledge-{company}/` → `git init` → initial README
2. Create symlink: `companies/{company}/knowledge → ../../repos/private/knowledge-{company}`
3. Update manifest.yaml: replace `null` with `companies/{company}/knowledge/`
4. Add to `modules/modules.yaml`

### 10. Modules Registry Completeness

**Policy**: Every knowledge symlink should have a corresponding entry in `modules/modules.yaml`.

```bash
for symlink in knowledge/public/* knowledge/private/* companies/*/knowledge; do
  [ -L "$symlink" ] || continue
  name=$(basename $(readlink "$symlink"))
  if ! grep -q "$name" modules/modules.yaml 2>/dev/null; then
    echo "UNREGISTERED: $symlink not in modules.yaml"
  fi
done
```

**With --fix**: Add missing module entries to `modules/modules.yaml`.

### 11. qmd Collection Completeness

**Policy**: Every company with a knowledge symlink should have a qmd collection. HQ itself should have 4 sub-collections: `hq-infra`, `hq-workers`, `hq-knowledge`, `hq-projects` (not a monolithic `hq`).

```bash
# Check companies with knowledge but empty qmd_collections
grep -B10 "qmd_collections: \[\]" companies/manifest.yaml | grep "^[a-z]"
# Check HQ sub-collections exist
for c in hq-infra hq-workers hq-knowledge hq-projects; do
  qmd ls "$c" 2>/dev/null | head -1 | grep -q . || echo "MISSING: $c"
done
```

**With --fix**: Create qmd collection for each missing company. If any `hq-*` sub-collection is missing, run `scripts/migrate-qmd-collections.sh`.

---

## Migration: prd.json → README.md

For each project with only `prd.json`:

1. Read prd.json
2. Extract fields:
   - `name` → title
   - `description` → overview
   - `metadata.goal` → Goal line
   - `metadata.successCriteria` → Success line
   - `userStories[]` → User Stories section
3. Generate README.md
4. Keep prd.json as backup (rename to `prd.json.bak`)

**Template**:
```markdown
# {name}

**Goal:** {metadata.goal}
**Success:** {metadata.successCriteria}

## Overview
{description}

## User Stories

### US-001: {story.title}
**Description:** {story.description}

**Acceptance Criteria:**
{story.acceptanceCriteria as checklist}

## Non-Goals
{if present}

## Technical Considerations
{if present}
```

---

## Fix Actions

### Git Cleanup
```bash
# Stage deleted files
git add -u

# Commit cleanup
git commit -m "chore: cleanup orphaned files"
```

### Purge Stale Auto-Checkpoints
```bash
# Delete auto-checkpoints older than 14 days (no archive — they're lightweight)
find workspace/threads -name "T-*-auto-*.json" -mtime +14 -delete 2>/dev/null
echo "Purged $(find workspace/threads -name "T-*-auto-*.json" -mtime +14 2>/dev/null | wc -l) auto-checkpoints"
```

### Archive Stale Threads & Checkpoints
```bash
mkdir -p archives/threads archives/checkpoints
find workspace/threads -name "*.json" -not -name "*-auto-*" -mtime +30 -exec mv {} archives/threads/ \;
find workspace/checkpoints -name "*.json" -mtime +30 -exec mv {} archives/checkpoints/ \;
```

### Relocate Misplaced Projects
```bash
# Move apps/{name}/prd.json to projects/{name}/
mkdir -p projects/{name}
mv apps/{name}/prd.json projects/{name}/
```

### Regenerate INDEX.md Files (--reindex)

For each expected INDEX.md location (see Audit Check #8):
1. List all files and subdirectories (skip INDEX.md, .DS_Store, node_modules, dotfiles)
2. Extract description per spec: `.md` → first `#` heading, `.yaml` → `description:`, `.json` → `name`/`description`, dirs → file count + purpose
3. Write INDEX.md using template from `knowledge/public/hq-core/index-md-spec.md`
4. Directories first, then files, alphabetical within each group

---

## Output Format

### Audit Report
```
HQ Cleanup Audit
================

✓ Worker registry: 15 workers indexed
✗ Project structure: 8 issues
  - projects/customer-cube: prd.json without README.md
  - projects/deel-analytics: prd.json without README.md
  ...
✗ Deprecated directories: apps/ still exists (4 items)
✗ Git status: 3 uncommitted changes
✓ Checkpoints: all recent
✗ INDEX.md: 2 stale, 1 missing
  - projects/INDEX.md: 30 entries vs 33 actual (stale)
  - workspace/reports/INDEX.md: missing

Summary: 14 issues found
Run `/cleanup --migrate` to convert prd.json files
Run `/cleanup --fix` to clean git and archive stale files
Run `/cleanup --reindex` to regenerate all INDEX.md files
Run `/cleanup --consolidate-learnings` to dedup and reorganize learned rules
Run `/cleanup --consolidate-insights` to dedup and flag stale insights
```

### After Migration
```
Migrated 8 projects to README.md format:
- projects/customer-cube/README.md (created)
- projects/deel-analytics/README.md (created)
...

Original prd.json files renamed to prd.json.bak
Run `/cleanup --fix` to commit changes
```

---

## Consolidate Learnings (--consolidate-learnings)

Dedup, merge, and reorganize learned rules across all target files.

### Step 1: Collect all rules

Scan these locations and extract every rule:

| Location | How to find |
|----------|-------------|
| `.claude/CLAUDE.md` `## Learned Rules` | Read section, parse `- **{name}**:` entries |
| Worker yamls `## Learnings` | `grep -rl "## Learnings" workers/` → read each |
| Command mds `## Rules` | `grep -rl "## Rules" .claude/commands/` → read each |
| Learning event log | `ls workspace/learnings/*.json` → read rules[] from each |

Build a master list: `{rule_text, source_file, section, date_added}`.

### Step 2: Cross-file dedup

For each rule in the master list:
```bash
qmd vsearch "{rule_text}" --json -n 10
```

Flag:
- **Exact duplicates** (similarity > 0.85 across different files): keep the most specific (worker > command > global), remove the other
- **Near-duplicates** (0.6–0.85): merge into one rule with combined context, remove the weaker copy
- **Contradictions**: flag for user review (don't auto-resolve)

### Step 3: Deprecate stale rules

For each rule, check if its references still exist:
- Rule mentions a worker → does that worker exist in `workers/registry.yaml`?
- Rule mentions a command → does `.claude/commands/{name}.md` exist?
- Rule mentions a tool/API → is it still in use? (best effort)

Flag stale rules for user review. Don't auto-delete — present as candidates.

### Step 4: Reorganize scope

If a scoped rule (worker/command) has been superseded by a broader global rule covering the same behavior, remove the scoped copy (the global rule covers it).

If a global rule only applies to one worker/command, demote it to the scoped file and remove from CLAUDE.md (frees global cap space).

### Step 5: Apply changes

For each proposed change (remove/merge/demote/promote), apply to target files using Edit tool.

### Step 6: Reindex

```bash
qmd update && qmd embed
```

### Step 7: Report

```
Learning Consolidation
======================
Rules scanned: {total}
  - CLAUDE.md: {n}
  - Workers: {n} across {m} files
  - Commands: {n} across {m} files

Actions taken:
  ✓ Removed {n} duplicates
  ✓ Merged {n} near-duplicates
  ✓ Demoted {n} global → scoped
  ✓ Promoted {n} scoped → global
  ⚠ {n} stale rules flagged (review below)
  ⚠ {n} contradictions flagged (review below)

Stale rules:
  - {rule} in {file} — references deleted worker {id}
  ...

Contradictions:
  - {rule_a} vs {rule_b} — {explanation}
  ...
```

---

## Consolidate Insights (--consolidate-insights)

Deduplicate, merge, and flag stale insights across all insight directories.

### Step 1: Collect all insights

Scan these locations:

| Location | How to find |
|----------|-------------|
| `workspace/insights/global/` | `ls workspace/insights/global/*.md` |
| `workspace/insights/tools/` | `ls workspace/insights/tools/*.md` |
| `workspace/insights/concepts/` | `ls workspace/insights/concepts/*.md` |
| `companies/*/knowledge/insights/` | `ls companies/*/knowledge/insights/*.md 2>/dev/null` |

Build master list: `{title, slug, scope, confidence, created, file_path}` from YAML frontmatter.

### Step 2: Cross-file dedup

For each insight:
```bash
qmd vsearch "{insight title + first sentence}" --json -n 10
```

Flag:
- **Exact duplicates** (similarity > 0.85): keep the more detailed version, remove the other
- **Near-duplicates** (0.6–0.85): merge into one insight with combined context, remove the weaker copy
- **Cross-scope overlap**: company insight that duplicates a global insight → keep company version (more specific)

### Step 3: Flag stale insights

Insights older than 90 days with `confidence: medium` are stale candidates:
```bash
# Find medium-confidence insights older than 90 days
for f in workspace/insights/**/*.md companies/*/knowledge/insights/*.md; do
  [ -f "$f" ] || continue
  confidence=$(grep "^confidence:" "$f" | awk '{print $2}')
  created=$(grep "^created:" "$f" | awk '{print $2}')
  [ "$confidence" = "medium" ] && echo "STALE CANDIDATE: $f (created: $created)"
done
```

Present stale candidates for user review. Don't auto-delete.

### Step 4: Apply changes

For each proposed change (remove/merge), apply using Edit tool. Update `updated` date on merged insights.

### Step 5: Reindex

```bash
qmd update && qmd embed
```

### Step 6: Report

```
Insight Consolidation
=====================
Insights scanned: {total}
  - Global: {n}
  - Tools: {n}
  - Concepts: {n}
  - Company-scoped: {n} across {m} companies

Actions taken:
  ✓ Removed {n} duplicates
  ✓ Merged {n} near-duplicates
  ⚠ {n} stale insights flagged (review below)

Stale candidates:
  - {title} in {file} — medium confidence, created {date}
  ...
```

---

## Rules

- **--audit is safe**: Never modifies files, only reports
- **Always ask before destructive actions**: deletions, moves
- **Backup before migration**: rename, don't delete
- **Commit after changes**: keep git clean

---

## Current HQ Policies

Reference for what we're enforcing:

| Area | Policy |
|------|--------|
| Projects | Live in `projects/{name}/` with `README.md` |
| PRD format | Markdown README.md (not prd.json) |
| Workers | Indexed in `workers/registry.yaml` |
| Worker FSM | `state_machine:` section in worker.yaml (Loom pattern) |
| Apps | Deprecated - migrate to projects/ or workers/ |
| Skills | `.claude/commands/*.md` format |
| Threads | Primary session persistence (`workspace/threads/`) |
| Auto-checkpoints | Lightweight, purge after 14 days (`T-*-auto-*.json`) |
| Checkpoints | Legacy format, archive after 30 days |
| Metrics | Append to `workspace/metrics/metrics.jsonl` |
| Git | Clean working tree |
| Knowledge repos | Symlinks in `knowledge/` and `companies/*/knowledge/` point to repos; all repos committed |
| INDEX.md | Exist at 10 key dirs, match contents (see spec) |
| Manifest | All companies have non-null knowledge, settings, repos |
| Modules | All knowledge repos registered in `modules/modules.yaml` |
| qmd | All companies with knowledge have a qmd collection |
| Learnings | No cross-file duplicates, stale rules flagged, scoped > global |
