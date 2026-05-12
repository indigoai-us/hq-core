# Gardener Team

Multi-worker team that audits, deduplicates, and cleans stale/inaccurate information across HQ.

## Workers

| Worker | Model | Role |
|--------|-------|------|
| `garden-scout` | haiku | Fast scan — inventory files, detect staleness signals, orphans, broken links, duplicates |
| `garden-auditor` | sonnet | Deep analysis — validate findings, cross-reference content, detect conflicts |
| `garden-curator` | sonnet | Execute actions — archive, deduplicate, update INDEX, create escalation PRDs |

## Orchestration

Triggered by `/garden {scope}`. Three-phase pipeline with human approval gates between each phase:

```
Scout (scan) → Human gate → Auditor (validate) → Human gate → Curator (execute)
```

## Scope Resolution

- Company slug → all company dirs + owned workers + related projects
- Directory path → that subtree
- `all` → chunked by company + orphan sweep

## Output

- State: `workspace/orchestrator/garden-{run-id}/`
- Reports: `workspace/reports/garden/`
- Escalation PRDs: `projects/garden-discovery-{slug}/`
