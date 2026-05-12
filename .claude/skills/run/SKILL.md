---
name: run
description: Run a worker or list available workers. Prefer isolated Codex sub-agents with filesystem memory; fall back to inline execution only when delegation is unavailable.
allowed-tools: Read, Grep, Bash(qmd:*), Bash(grep:*), Bash(ls:*), Bash(git:*), Bash(cat:*), Bash(which:*), Bash(wc:*), Edit, Write
argument-hint: "[worker-id] [skill] [args]"
---

# Run - Worker Execution

Unified interface to run workers and their skills in Codex sessions.

> **Codex Delegation Note**
>
> In Codex, `/run` should prefer an isolated worker sub-agent when the runtime exposes sub-agent delegation. Worker instructions, knowledge, and policies live in that sub-agent context and return as a compact handoff.
>
> The parent session stays responsible for user communication, integration, verification, commits, and durable memory. If delegation is unavailable, execute inline and write the same memory files.

**Usage:**
```
run                          # List available workers
run {worker-id}              # Show worker skills
run {worker-id} {skill}      # Run specific skill
run {worker-id} {skill} arg  # Run with argument
```

**User's input:** $ARGUMENTS

---

## Step 1 — Parse Arguments

Extract from `$ARGUMENTS`:
- `worker_id` — first token
- `skill` — second token (optional)
- `args` — remaining tokens (optional, passed to skill as `$ARGUMENTS`)

---

## Step 2 — Route by Input

### No Arguments → List Workers

Read `core/workers/registry.yaml` and display all workers:

```
Available Workers:

  x-{your-handle}    X/Twitter posting for {your-name}
  cfo-{product}    Financial reporting
  {product}-analyst LR/{PRODUCT} data analysis
  ...

Usage: run {worker-id} [skill] [args]
```

Stop here.

### Worker ID Only → Show Skills

1. Read `core/workers/registry.yaml`
2. Find the entry matching `{worker_id}`
3. Read `{worker_path}/worker.yaml`
4. List skills from the `skills:` section

```
Worker: x-{your-handle}
Description: X/Twitter posting for {your-name}

Skills:
  contentidea   Build out a content idea into posts
  suggestposts  Research and suggest posts
  scheduleposts Choose what to post now

Usage: run x-{your-handle} {skill}
```

Stop here.

### Worker + Skill (+ Args) → Execute Worker

Proceed to the full execution pipeline below.

---

## Step 3 — Load Worker Context

### 3a. Find Worker Registry Entry

Use the Read tool to read `core/workers/registry.yaml`. The registry stores workers as a YAML list under the `workers:` key, with each entry shaped like:

```yaml
workers:
  - id: x-user
    path: companies/personal/workers/x-user/
    description: "..."
```

Scan the list for the entry where `id:` matches `{worker_id}` and extract its `path:` field. If needed, use Grep with the correct pattern to find the path:

```bash
grep -A 4 "  - id: {worker_id}$" core/workers/registry.yaml | grep "path:"
```

Extract the `path:` value (strip the `path: ` prefix). If no matching entry found, display:
```
Error: Worker '{worker_id}' not found in registry.
Run 'run' (no args) to list available workers.
```
Stop.

### 3b. Read worker.yaml

Read `{worker_path}/worker.yaml` in full. This contains:
- `instructions:` — the worker's accumulated knowledge and learnings
- `tools:` — permitted tools (respect these during execution)
- `knowledge:` — paths to knowledge files (load relevant ones)
- `company:` — company scope (used for policy loading)
- `skills:` — available skill definitions

### 3c. Find and Read the Skill File

Skill definitions are in `{worker_path}/skills/{skill}.md`.

If the skill file does not exist, check `worker.yaml` `skills:` section for an inline definition. If still not found:
```
Error: Skill '{skill}' not found for worker '{worker_id}'.
Run 'run {worker_id}' to see available skills.
```
Stop.

---

## Step 4 — Load Policies

Determine the company scope from:
1. `worker.yaml` `company:` field
2. Worker path prefix: `companies/{co}/workers/` → company is `{co}`
3. Fallback: no company scope

If company determined, read policies:
```bash
ls companies/{co}/policies/ 2>/dev/null
```

Read each policy file (skip `example-policy.md`). Note:
- **Hard enforcement** → treat as absolute constraints during execution
- **Soft enforcement** → note deviations, proceed

If worker targets a specific repo (from `worker.yaml` `repo:` field), also read:
```bash
ls {repoPath}/.claude/policies/ 2>/dev/null
```

---

## Step 5 — Load Knowledge

From `worker.yaml` `knowledge:` section, load relevant knowledge files referenced. Prioritize files related to the requested skill. Use:

```bash
which qmd 2>/dev/null && qmd search "{worker_id} {skill}" --json -n 5
```

Or read knowledge files directly via Read tool if paths are specified in worker.yaml.

---

## Step 6 — Execute Skill

### Preferred: isolated Codex worker

When sub-agents are available, spawn a bounded worker agent:

```text
role: worker
model: omit to inherit parent for implementation; use "gpt-5.3-codex-spark" for read-only/simple work
ownership: files or directories this worker may change
prompt:
  - worker.yaml instructions
  - selected skill file
  - task args
  - applicable policies
  - minimal memory files from workspace/orchestrator/{project}/memory/
  - output JSON return contract
```

Tell the worker it is not alone in the codebase. It must not revert edits made by others and must adapt to existing concurrent changes. For code edits, assign a clear write scope and require the worker to list changed paths.

Model note: worker configs may contain legacy labels such as `opus` or `sonnet`. Do not pass those as Codex sub-agent model ids. For implementation agents, omit the model override unless the task or worker provides a real Codex model id. For bounded sidecars, use `gpt-5.3-codex-spark`.

### Fallback: inline execution

If sub-agents are unavailable, execute in the parent session:

1. Understand the skill — re-read `{skill}.md` instructions
2. Apply worker constraints — only use tools listed in `worker.yaml` `tools:` section
3. Execute — follow the skill's instructions step by step
4. Pass arguments — `$ARGUMENTS` in the skill file refers to args after `{worker_id} {skill}`
5. Verify — run any verification steps defined in the skill file

### Memory write

After either path, write the compact handoff to:

`workspace/orchestrator/{project-or-session}/memory/agents/{timestamp}-{worker_id}-{skill}.json`

---

## Step 7 — Auto-Checkpoint

After skill completion, write a thread checkpoint file:

```json
{
  "thread_id": "T-{YYYYMMDD}-{HHMMSS}-{worker_id}-{skill}",
  "version": 1,
  "type": "auto-checkpoint",
  "created_at": "{ISO8601}",
  "updated_at": "{ISO8601}",
  "workspace_root": "/Users/{your-name}/Documents/HQ",
  "cwd": "{current working directory}",
  "git": {
    "branch": "{current branch from git branch --show-current}",
    "current_commit": "{short hash from git rev-parse --short HEAD}",
    "dirty": "{true if git status --short output is non-empty, false otherwise}"
  },
  "conversation_summary": "Ran {worker_id}/{skill}: {1-sentence description of what was accomplished}",
  "files_touched": ["{list of files created or modified}"],
  "metadata": {
    "title": "Auto: {worker_id} {skill}",
    "tags": ["auto-checkpoint", "{worker_id}", "{skill}"],
    "trigger": "worker-completion"
  }
}
```

Write to: `workspace/threads/{thread_id}.json`

Get git state with:
```bash
git rev-parse --short HEAD 2>/dev/null
git branch --show-current 2>/dev/null
git status --short 2>/dev/null
```

Set `dirty: true` if `git status --short` output is non-empty; `false` if empty.

---

## Examples

```
run                              # See all workers
run x-user                      # See x-user skills
run x-user contentidea          # Run contentidea skill
run x-user contentidea "AI workforce"  # Run with topic arg
run cfo-{product} mrr          # Run MRR report
run {product}-analyst weekly   # Run weekly analysis
```
