# Workers

Workers are autonomous AI assistants with specialized roles. This knowledge base documents the Workers framework and how to build/operate them.

## Philosophy

**Workers, not Agents**
- "Agent" is technical jargon
- "Worker" is human, relatable
- Workers have jobs, context, and output
- They do real work, not just assist

**Built on Ralph Principles**
- ONE task at a time
- Fresh context per task (no context rot)
- Back pressure verification before completion
- Simple loops over complex orchestration

## Worker Types

| Type | Purpose | Example |
|------|---------|---------|
| **CodeWorker** | Implement features, fix bugs | {company} |
| **SocialWorker** | Draft posts, maintain presence | x-user |
| **ResearchWorker** | Competitive analysis, market research | {company}-analyst |
| **OpsWorker** | Monitoring, automation, reports | cfo-{company} |

## Building Workers (Build Mode)

When creating or modifying workers, follow this structure:

### Worker Definition (`worker.yaml`)

```yaml
id: worker-id
name: Human-readable Name
type: WorkerType
status: active|planned|deprecated

context:
  base:
    - path/to/always/load.md
  dynamic:
    - pattern: "*.yaml"
      when: "task.type == 'config'"

skills:
  - id: skill-name
    description: What this skill does
    inputs: [required, parameters]
    outputs: [what, it, produces]
    verification:
      - command: "npm run typecheck"
        must_pass: true

schedule:
  type: on-demand|cron|event
  cron: "0 8 * * *"  # if cron type
```

### File Structure

```
workers/
├── registry.yaml           # Index of all workers
├── {category}/
│   └── {worker-id}/
│       ├── worker.yaml     # Definition
│       ├── prd.json        # If code-based, task tracking
│       └── skills/         # Skill implementations
```

### Build Checklist

1. Add entry to `workers/registry.yaml`
2. Create `workers/{category}/{id}/worker.yaml`
3. Define skills with clear inputs/outputs/verification
4. Test with on-demand execution first
5. Document in this knowledge base if patterns emerge

## Running Workers (Work Mode)

### On-Demand Execution

```
"Run the {company}-analyst anomaly check"
"Execute cfo-{company} monthly report"
```

The agent will:
1. Load the worker's context
2. Execute the relevant skill
3. Run verification checks
4. Output results

### Ralph Loop Pattern

For multi-task projects (3+ tasks), use the orchestrator pattern:

```
Orchestrator (main agent):
  - Read PRD/task list
  - Pick ONE task (status: pending)
  - Spawn sub-agent via Task tool
  - Read checkpoint when done
  - Update task status
  - Repeat until all tasks done

Sub-agent (spawned):
  - Fresh 100% context
  - Implements ONE task
  - Runs back pressure (typecheck, build, tests)
  - Writes checkpoint
  - Exits
```

**Why this pattern:**
- Main agent context stays light (<30%)
- Sub-agents get full context per task
- Parallel execution possible for independent tasks
- Clear audit trail via checkpoints

**Spawn template:**
```
Task({
  subagent_type: "general-purpose",
  prompt: `
    Task: {id} - {title}

    Acceptance criteria:
    - {criteria}

    Files: {file_paths}

    Instructions:
    1. Implement the task
    2. Run verification: {verification_command}
    3. Commit: "feat({id}): {title}"
    4. Write checkpoint to workspace/checkpoints/{id}.json
    5. Exit
  `
})
```

### Checkpointing

After significant progress, write state:

```json
{
  "task_id": "string",
  "completed_at": "ISO8601",
  "summary": "what was done",
  "next_steps": ["array"],
  "files_touched": ["paths"]
}
```

Location: `workspace/checkpoints/{task-id}.json`

## Back Pressure

Every worker skill should define verification checks:

| Type | Example | When |
|------|---------|------|
| Code | `npm run typecheck && npm run build` | After code changes |
| Tests | `npm test` | After feature implementation |
| Lint | `npm run lint` | Before commit |
| Voice | Compare against style guide | Social/content workers |

**Rule:** Never mark a task complete without passing verification.

## Registry

All workers are indexed in `workers/registry.yaml`:

```yaml
workers:
  - id: worker-id
    path: workers/category/worker-id/
    type: WorkerType
    status: active|planned
    description: "What this worker does"
```

## See Also

- [Ralph Methodology](../Ralph/) - Core principles
- [ralph-loop-pattern.md](./ralph-loop-pattern.md) - Detailed loop docs
- [state-machine.md](./state-machine.md) - Worker state machine (Loom pattern)
- [skill-schema.md](./skill-schema.md) - Skill interface specification
- [Thread Schema](../hq-core/thread-schema.md) - Thread persistence format
- [Loom Patterns](../loom/) - Reference implementation
- Individual worker docs in `workers/{category}/{id}/`
