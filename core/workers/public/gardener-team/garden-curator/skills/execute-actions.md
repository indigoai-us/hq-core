# execute-actions

Execute approved audit actions and log results.

## Arguments

`$ARGUMENTS` = path to audit-report.json

Required context (provided by orchestrator):
- `audit_path`: path to audit-report.json
- `run_id`: garden run identifier
- `output_path`: where to write actions-log.json
- `approved_ids`: list of finding IDs approved for action (or "all")

## Process

### 1. Load Audit Report

Read audit-report.json. Filter to `approved_ids`. Skip any with action "skip".

### 2. Execute Actions (in order: clean → archive → deduplicate → update → reassign → escalate)

Order matters — clean orphans first, then archive stale, then dedup, then fix INDEX, then escalate.

**ARCHIVE:**
```bash
# Ensure _archive exists
mkdir -p "$(dirname {path})/_archive"
# Move with datestamp
mv "{path}" "$(dirname {path})/_archive/$(date +%Y%m%d)-$(basename {path})"
```
- If file listed in an INDEX.md, remove that line from INDEX
- If file is in a knowledge repo (symlinked), commit to target repo

**DEDUPLICATE:**
1. Verify canonical file still exists
2. Delete duplicate file
3. If duplicate was in a different knowledge base, leave a redirect note:
   ```markdown
   <!-- Canonical location: {canonical_path} -->
   ```
4. Update any INDEX.md that referenced the duplicate

**UPDATE:**
- For INDEX drift: regenerate the INDEX.md section (use existing INDEX format)
- For fact corrections: Edit the specific outdated line with correct info from auditor notes

**CLEAN:**
```bash
# Remove empty directories
rmdir "{path}" 2>/dev/null
# Remove orphaned state files
rm "{path}"
# Remove old threads
mv "{path}" "workspace/threads/_archive/"
```

**REASSIGN:**
1. Move file to correct company directory
2. Update source INDEX.md (remove entry)
3. Update destination INDEX.md (add entry)
4. If moving between knowledge repos, commit to both target repos

**ESCALATE:**
1. Generate slug from prd_title
2. Create `projects/garden-discovery-{slug}/` directory
3. Write minimal prd.json (see worker.yaml template)
4. Write README.md with context from audit finding

### 3. Post-Action

After all actions:
- Regenerate affected INDEX.md files
- Run `qmd update 2>/dev/null || true`
- Identify which repos need commits:
  - Knowledge repos: `cd` to target, `git add -A`, `git commit -m "garden: {action summary}"`
  - HQ repo: stage only garden-related changes

### 4. Output

Write `actions-log.json` to `{output_path}`:

```json
{
  "run_id": "{run_id}",
  "executed_at": "ISO8601",
  "actions": [
    {
      "finding_id": "F-001",
      "action": "archive",
      "status": "success|failed|skipped",
      "before": "companies/{product}/knowledge/gtm/old-pixel-setup.md",
      "after": "companies/{product}/knowledge/gtm/_archive/20260219-old-pixel-setup.md",
      "commits": [{"repo": "knowledge-{product}", "sha": "abc1234"}],
      "error": null
    }
  ],
  "summary": {
    "total_actions": 0,
    "succeeded": 0,
    "failed": 0,
    "skipped": 0,
    "prds_created": [],
    "repos_committed": []
  }
}
```

## Rules

- NEVER delete without archival
- Commit knowledge repo changes to TARGET repo, not HQ git
- Always verify `git branch --show-current` before committing to any repo
- If action fails, log error and continue (don't abort)
- Output MUST be valid JSON
