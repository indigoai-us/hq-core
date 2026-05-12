# scan-scope

Scan a resolved set of directories and produce a findings manifest.

## Arguments

`$ARGUMENTS` = scope paths (resolved by /garden command)

Required context (provided by orchestrator):
- `resolved_paths`: array of directories to scan
- `run_id`: garden run identifier
- `output_path`: where to write findings.json

## Process

### 1. Inventory

For each path in `resolved_paths`:
1. List all files and subdirectories (use Glob with scoped `path:`)
2. Check for INDEX.md — if present, parse its entries
3. Count files, note structure

### 2. Staleness Checks

For each file found:

```bash
# Get last commit date for file
git log -1 --format="%ai" -- "{file}" 2>/dev/null
```

- >90 days since last commit → severity: medium
- >60 days → severity: low
- No git history (untracked) → flag as "unowned" or "orphan"

### 3. Structural Checks

**Broken symlinks:**
```bash
find {path} -type l ! -exec test -e {} \; -print 2>/dev/null
```

**Empty directories:**
```bash
find {path} -type d -empty 2>/dev/null
```

**INDEX drift:**
- Read INDEX.md if present
- Compare listed entries against actual directory contents
- Flag entries that exist in INDEX but not on disk (or vice versa)

### 4. Duplicate Detection

- Track all filenames across scanned paths
- Flag when same filename appears in 2+ locations
- Note: duplicates are only suspicious across different knowledge bases, not within the same one

### 5. Orphan Detection

**Orchestrator state:**
- Check `workspace/orchestrator/*/state.json`
- If project status is "completed" or last update >30d with status "in_progress" → orphan

**Threads:**
- Check `workspace/threads/*.json`
- Auto-checkpoint threads >14 days old → stale
- Manual threads >60 days old → stale

**Projects:**
- Check `projects/*/prd.json` or `projects/*/README.md`
- No activity >60d → stale signal

### 6. Unowned Check

- Read `companies/manifest.yaml`
- For each scanned path, check if it falls under a company's declared resources
- Paths not claimed by any company → "unowned"

## Output

Write `findings.json` to `{output_path}`:

```json
{
  "run_id": "{run_id}",
  "scope": "{scope}",
  "scanned_at": "ISO8601",
  "paths_scanned": ["..."],
  "total_files_scanned": 0,
  "findings": [
    {
      "id": "F-001",
      "type": "stale|duplicate|orphan|drift|conflict|empty|unowned",
      "path": "relative/path/to/file",
      "severity": "low|medium|high",
      "signal": "Human-readable description of what was detected",
      "recommended_action": "archive|investigate|clean|reassign"
    }
  ],
  "summary": {
    "total_findings": 0,
    "by_type": {"stale": 0, "duplicate": 0, "orphan": 0, "drift": 0, "empty": 0, "unowned": 0},
    "by_severity": {"high": 0, "medium": 0, "low": 0}
  }
}
```

## Rules

- NEVER modify files — read-only
- Use git log for age (not filesystem mtime)
- Use Glob with scoped path: always
- Keep findings concise — one entry per issue, not per file in a stale directory
- Group related files (e.g. "3 files in gtm/ are stale") into one finding when appropriate
- Output MUST be valid JSON
