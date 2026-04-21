---
description: Run a worker or list available workers
allowed-tools: Task, Read, Glob, Grep, Bash, Edit, Write, WebSearch, WebFetch, AskUserQuestion
argument-hint: [worker-id] [skill] [args]
visibility: public
---

# /run - Worker Execution

Unified interface to run workers and their skills.

**Usage:**
```
/run                          # List available workers
/run {worker-id}              # Show worker skills
/run {worker-id} {skill}      # Run specific skill
/run {worker-id} {skill} arg  # Run with argument
```

**User's input:** $ARGUMENTS

## Process

### No Arguments → List Workers

If no arguments provided, read `workers/registry.yaml` and display:

```
Available Workers:

  x-{your-handle}    X/Twitter posting for {your-name}
  cfo-{product}    Financial reporting
  {product}-analyst LR/{PRODUCT} data analysis
  ...

Usage: /run {worker-id} to see skills
```

### Worker ID Only → Show Skills

If only worker-id provided:
1. Find worker in registry
2. Read `workers/{worker-path}/worker.yaml`
3. List available skills

```
Worker: x-{your-handle}
Description: X/Twitter posting for {your-name}

Skills:
  contentidea   Build out a content idea into posts
  suggestposts  Research and suggest posts
  scheduleposts Choose what to post now

Usage: /run x-{your-handle} {skill}
```

### Worker + Skill → Execute

1. Load worker context from `workers/{path}/`
2. Load skill definition from `workers/{path}/skills/{skill}.md`
3. Execute the skill instructions
4. Write checkpoint after completion

### Worker + Skill + Args → Execute with Args

Pass arguments to the skill. The skill file will reference `$ARGUMENTS`.

## Execution Pattern

When executing a skill:
1. **Load context** - Read worker.yaml (includes accumulated learnings in `instructions:`), any knowledge files referenced
1b. **Load policies** — Determine company from worker path (`companies/{co}/workers/` → `{co}`) or from worker.yaml `company` field. Read `companies/{co}/policies/` (skip `example-policy.md`). If worker targets a repo, also check `{repoPath}/.claude/policies/`. Apply hard-enforcement policies as constraints during execution
2. **Execute** - Follow the skill's instructions
3. **Verify** - Run any verification steps defined
4. **PostToolsHook** - Auto-save thread to `workspace/threads/`

### PostToolsHook (Auto-Checkpoint)

After skill completion, automatically create a thread:

```json
{
  "thread_id": "T-{YYYYMMDD}-{HHMMSS}-{worker}-{skill}",
  "worker": { "id": "{worker-id}", "skill": "{skill}", "state": "completed" },
  "git": { /* capture current git state */ },
  "conversation_summary": "What was accomplished",
  "files_touched": ["files created/modified"],
  "metadata": { "tags": ["{worker-id}", "{skill}"] }
}
```

Write to: `workspace/threads/{thread_id}.json`

Also append to metrics: `workspace/metrics/metrics.jsonl`

## Examples

```
/run                              # See all workers
/run x-user                      # See x-user skills
/run x-user contentidea          # Run contentidea
/run x-user contentidea "AI workforce" # Run with topic
/run cfo-{product} mrr          # Run MRR report
```

## Notes

- Mode (work vs build) is determined by what the skill does, not declared upfront
- Workers have scoped permissions - only tools listed in their worker.yaml
- Skills can reference knowledge bases and other workers
