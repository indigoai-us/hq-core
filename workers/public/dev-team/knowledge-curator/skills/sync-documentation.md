# sync-documentation

Sync and update documentation across the HQ system.

## Arguments

`$ARGUMENTS` = `--scope <scope>` (required)

Optional:
- `--target <path>` - Specific file to update
- `--dry-run` - Preview changes without writing

## Scopes

- `worker` - Update worker CLAUDE.md files
- `project` - Update project documentation
- `knowledge` - Sync knowledge base indices
- `all` - Full documentation sync

## Process

1. Scan scope for documentation files
2. Identify outdated or missing content:
   - Worker capabilities not documented
   - Skills not listed
   - Stale references
3. Generate updates
4. Present changes to human
5. Apply updates

## Documentation Standards

### Worker CLAUDE.md
```markdown
# Worker Name

One-line description.

## Capabilities
- Capability 1
- Capability 2

## Skills
| Skill | Description |
|-------|-------------|
| skill-1 | What it does |

## Context
What the worker needs access to.

## Usage
How to invoke the worker.
```

### Project Documentation
```markdown
# Project Name

## Overview
Brief description.

## Structure
Key directories and files.

## Conventions
Project-specific patterns.

## Learnings
Link to learnings directory.
```

## Output

- List of files updated
- Summary of changes
- Warnings for missing documentation
