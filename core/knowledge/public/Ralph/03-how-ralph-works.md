---
type: guide
domain: [engineering]
status: canonical
tags: [ralph, loop, bash-script, autonomous-coding, workflow]
relates_to: []
---

# How Ralph Works

## The Basic Loop

At its core, Ralph is a simple bash script that runs in a for loop:

```bash
#!/bin/bash
for i in {1..N}; do
    claude --print "Pick ONE incomplete item from plans/prd.json and implement it.
    Run tests. If they pass, commit. Update the PRD passes field.
    Write progress to progress.txt"
done
```

> "Everyone's calling it Ralph Wiggum. This is credited to Geoffrey Huntley."
> — Matt Pocock

## The Components

### 1. PRD (Product Requirements Document)

A JSON file containing user stories with pass/fail status:

```json
{
  "features": [
    {
      "id": "beat-display",
      "description": "Beats should display as three orange ellipses dots below the clip",
      "acceptance_criteria": [
        "Add a beat to a clip",
        "Verify three orange dots appear below the clip",
        "Verify they're orange colored",
        "Verify they form an ellipses pattern"
      ],
      "passes": false
    }
  ]
}
```

The PRD serves dual purposes:
- A specification for what to build
- A test harness tracking what's done

### 2. Progress File (progress.txt)

A running log of what the agent has accomplished:

```
[2026-01-13 10:30] Implemented beat-display feature
[2026-01-13 10:32] Tests passing, committed: abc123
[2026-01-13 10:35] Started work on beat-animation
```

This provides:
- Audit trail
- Context for subsequent runs
- Human review capability

### 3. agents.md / CLAUDE.md

Configuration file that tells the AI how to behave:

```markdown
# Project Context
This is a video editing application built with TypeScript and React.

# Build Commands
- `npm run build` - Build the application
- `npm test` - Run tests
- `npm run lint` - Run linter

# Coding Standards
- Use TypeScript strict mode
- All functions must have JSDoc comments
- Keep files under 300 lines
```

### 4. Back Pressure Mechanisms

The verification layer that ensures code quality:

- **Type checking**: `tsc --noEmit`
- **Linting**: `eslint .`
- **Unit tests**: `npm test`
- **Build verification**: `npm run build`
- **Pre-commit hooks**: Run all checks before allowing commits

## The Execution Flow

```
┌─────────────────┐
│  Start Loop     │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Load PRD.json  │
│  Load agents.md │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Pick ONE task   │
│ (not passing)   │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Generate code   │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Run back        │
│ pressure checks │
└────────┬────────┘
         │
    ┌────┴────┐
    │ Pass?   │
    └────┬────┘
         │
    Yes  │  No
    ┌────┴────┐
    │         │
    ▼         ▼
┌───────┐ ┌───────┐
│Commit │ │Retry  │
│Update │ │       │
│PRD    │ └───┬───┘
└───┬───┘     │
    │         │
    └────┬────┘
         │
         ▼
┌─────────────────┐
│  Next iteration │
└─────────────────┘
```

## Key Implementation Details

### Why --print Flag?

The `--print` flag (or equivalent) ensures a fresh context for each task:

> "What happens is you work out a unit economic cost for software development... but to get it working, you have to understand the bare bones fundamentals from first principles."
> — Geoffrey Huntley

### Small Changes Are Critical

> "Keep these changes really small so that you still have context window left for the LLM to actually check that the change works."
> — Matt Pocock

### The Anthropic Recommendation

> "Effective harnesses for long-running agents from Anthropic... they noticed Claude's tendency to mark a feature as complete without proper testing. But it did much better at verifying features end to end once explicitly prompted to use browser automation tools."
> — Matt Pocock

## Advanced: Visual Feedback Loops

For frontend work, add browser automation:

```javascript
// MCP configuration for Chrome DevTools
{
  "mcpServers": {
    "chrome-devtools": {
      "url": "http://localhost:9222"
    }
  }
}
```

This allows the AI to:
- Take screenshots
- Verify visual changes
- Test user interactions
- Check responsive design

> "Without it, your LLM is essentially flying blind. It can't see the execution environment in which the changes are being made."
> — Matt Pocock
