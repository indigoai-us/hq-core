# validate-findings

Validate scout findings and produce an audit report with recommended actions.

## Arguments

`$ARGUMENTS` = path to findings.json

Required context (provided by orchestrator):
- `findings_path`: path to findings.json from scout phase
- `run_id`: garden run identifier
- `output_path`: where to write audit-report.json
- `approved_ids`: list of finding IDs approved by human (or "all")

## Process

### 1. Load Findings

Read findings.json. Filter to only `approved_ids` (findings the human approved for audit).

### 2. Validate Each Finding

For each finding, based on type:

**STALE:**
1. Read the file content
2. Check for references to deprecated/outdated things:
   - Old API versions, removed endpoints
   - References to deleted files/dirs
   - Outdated URLs or domain names
   - Superseded by newer file (check for v2, updated, new prefix)
3. If content is still accurate despite age → action: "skip" (stable reference)

**DUPLICATE:**
1. Read both files fully
2. Compare: same topic? Overlapping content? Contradicting?
3. Determine canonical: more complete, more recent commit, correct location per manifest
4. If contradicting → might be "conflict" instead

**ORPHAN:**
1. Check parent context (project state, workflow status)
2. Verify no other files reference this orphan
3. If referenced elsewhere → might not be orphan

**DRIFT:**
1. Read INDEX.md
2. List actual directory contents
3. Produce specific diff (added to disk, removed from disk, in INDEX but not on disk)

**CONFLICT:**
1. Read both files
2. Identify specific contradictions (different values for same fact)
3. Check git log to see which was updated more recently
4. If resolvable → recommend "update" with correct value
5. If not resolvable → flag needs_discovery with prd_title

**EMPTY/UNOWNED:**
1. Verify emptiness (might have hidden files)
2. For unowned: read content, suggest company based on topic

### 3. Cross-Reference

After individual validation, check for patterns:
- Multiple stale files in same directory → might suggest whole area is abandoned
- Duplicates across companies → might indicate company isolation violation
- Use `qmd search` to find related content when needed

### 4. Output

Write `audit-report.json` to `{output_path}`:

```json
{
  "run_id": "{run_id}",
  "audited_at": "ISO8601",
  "findings_audited": 0,
  "findings": [
    {
      "id": "F-001",
      "scout_type": "stale",
      "validation": "Confirmed stale. References Pixel v1 API deprecated in Oct 2025. Superseded by meta-pixel-v2.md.",
      "action": "archive|deduplicate|update|clean|escalate|reassign|skip",
      "confidence": "high|medium|low",
      "needs_discovery": false,
      "prd_title": null,
      "notes": "Optional additional context for curator"
    }
  ],
  "summary": {
    "total_audited": 0,
    "actions": {"archive": 0, "deduplicate": 0, "update": 0, "clean": 0, "escalate": 0, "reassign": 0, "skip": 0},
    "escalations": []
  }
}
```

## Rules

- NEVER modify files — read-only analysis
- Always read actual file content before making a judgment
- Cite specific evidence in validation notes
- When in doubt, recommend "skip" — false positives waste curator time
- Keep notes concise: what's wrong, why, what should happen
- Output MUST be valid JSON
