---
type: reference
domain: [engineering, operations]
status: canonical
tags: [ralph-loop, context-preservation, task-execution, sub-agents, orchestrator]
relates_to: []
---

# Ralph Loop Pattern: Context-Preserving Task Execution

## Problem
Long implementation sessions drain orchestrator context. By task 7, context is 80%+ full, responses slow, risk of forgetting earlier decisions.

## Solution
Orchestrator stays lean. Sub-agents do heavy lifting.

```
┌─────────────────────────────────────┐
│         ORCHESTRATOR                │
│  - Reads PRD                        │
│  - Picks ONE task (passes: false)   │
│  - Spawns sub-agent with task spec  │
│  - Reads checkpoint when done       │
│  - Updates PRD (passes: true)       │
│  - Repeats until all pass           │
│                                     │
│  Context usage: ~10-20% (stays low) │
└─────────────────────────────────────┘
              │
              ▼ spawn
┌─────────────────────────────────────┐
│         SUB-AGENT                   │
│  - Receives: task spec, file paths  │
│  - Implements feature               │
│  - Runs back pressure               │
│  - Commits code                     │
│  - Writes checkpoint                │
│  - Exits                            │
│                                     │
│  Context: fresh per task, 100% avail│
└─────────────────────────────────────┘
```

## Implementation

### 1. Orchestrator Prompt Pattern

When starting a Ralph loop:

```
I am the orchestrator. I will:
1. Read PRD to find next task
2. Use Task tool to spawn implementation agent
3. Wait for checkpoint
4. Update PRD and continue

I will NOT write code directly. Sub-agents handle implementation.
```

### 2. Sub-Agent Spawn Template

```typescript
// Use Task tool with Bash subagent for implementation
Task({
  subagent_type: "Bash",  // or custom "implement" agent
  prompt: `
    ## Task: ${task.id} - ${task.title}

    ## Acceptance Criteria
    ${task.acceptance_criteria.join('\n')}

    ## Files to Create/Modify
    ${task.files.join('\n')}

    ## Instructions
    1. Read existing code in ${task.files[0]} (if exists)
    2. Implement the feature
    3. Run: npm run typecheck && npm run build
    4. If pass, commit with message: "feat(${task.id}): ${task.title}"
    5. Write checkpoint to workspace/checkpoints/${task.id}.json

    ## Checkpoint Format
    {
      "task_id": "${task.id}",
      "completed_at": "ISO8601",
      "summary": "what was done",
      "files_touched": ["paths"],
      "build_passed": true/false
    }

    Exit when checkpoint is written.
  `
})
```

### 3. Worker Config Addition

```yaml
# workers/assistant/email/worker.yaml
execution:
  mode: on-demand
  spawn_per_task: true  # KEY: spawn sub-agent per task
  orchestrator_only: true  # orchestrator doesn't implement directly
```

### 4. HQ CLAUDE.md Addition

Add to `.claude/CLAUDE.md`:

```markdown
## Ralph Loop Execution (Multi-Task Projects)

For projects with 3+ tasks:

1. **Act as orchestrator only** - don't implement directly
2. **Spawn sub-agents** for each task using Task tool
3. **Keep context lean** by delegating implementation

### Spawning Implementation Agents

Use Task tool with focused prompts:

- Include ONLY the current task spec
- List specific files to modify
- Specify back pressure commands
- Require checkpoint on completion

### Example

Instead of:
```
[Orchestrator reads PRD, implements task 1, implements task 2...]
```

Do:
```
[Orchestrator reads PRD]
[Spawns agent for task 1]
[Reads checkpoint]
[Spawns agent for task 2]
[Reads checkpoint]
...
```
```

## Context Budget Guidelines

| Role | Target Context | Activities |
|------|---------------|------------|
| Orchestrator | <30% | Read PRD, spawn agents, read checkpoints |
| Sub-agent | 100% fresh | Implement ONE task, full context available |

## Benefits

1. **Orchestrator stays fast** - small context, quick responses
2. **Sub-agents get full context** - fresh start per task
3. **Checkpoints preserve state** - handoff without context loss
4. **Parallel execution possible** - spawn multiple sub-agents

## Anti-Patterns

❌ Orchestrator implements code directly
❌ Sub-agent works on multiple tasks
❌ Skipping checkpoints between tasks
❌ Loading full PRD into sub-agent (only current task)
