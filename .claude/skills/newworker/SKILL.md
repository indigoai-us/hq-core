---
name: newworker
description: Scaffold a new worker with skills, tools, and knowledge
allowed-tools: Read, Write, Edit, AskUserQuestion
---

# New Worker Builder

Create a new worker with proper structure, skills, and verification.

**Technology:** All HQ workers use TypeScript + Node.js (ESM). No Python for new workers.

**PRDs live in `personal/projects/` or `companies/{co}/projects/`** - Workers reference them, don't create their own. If the worker needs a PRD:
1. Run `/plan {worker-name}` first to create the PRD
2. Then return to `/newworker` to create the worker that references it

## Context to Load First

1. `core/knowledge/public/workers/README.md` - Worker framework
2. `core/knowledge/public/workers/templates/` - Worker templates
3. `core/workers/registry.yaml` - Existing workers

## Interactive Setup

Ask these questions (can batch related ones):

### 1. Identity
- **What type of worker?** (CodeWorker, SocialWorker, ResearchWorker, OpsWorker)
- **What's its name/id?** (e.g., "competitive-researcher", "x-user")
- **What does it do?** (1-sentence purpose)

### 2. Skills
- **What skills does it have?** (list specific capabilities)
- **What inputs does it need?** (context, triggers, data)
- **What outputs does it produce?** (reports, code, posts, etc.)

### 3. Execution
- **When does it run?** (on-demand, scheduled, event-triggered)
- **Schedule if applicable** (cron format: "0 9,14,19 * * *" = 9am, 2pm, 7pm)

### 4. Context
- **What files should always be loaded?** (base context)
- **What files should be loaded per-task?** (dynamic context)
- **What should be excluded?** (noise reduction)

### 5. Context Needs
- **What project context does this worker need?** (overview, architecture, domain, decisions, stakeholders, learnings)
- **Does it need more or less than its type's defaults?** (see `core/knowledge/context-needs/registry.yaml`)
- **Any external context required?** (brand guidelines, API specs, voice guides, etc.)

**Tip:** Reference `core/knowledge/context-needs/README.md` for context file descriptions. Most workers can use their type's defaults.

### 6. Verification
- **What checks ensure quality?** (type checks, character limits, voice consistency)
- **Does it need human approval?** (before external actions)

## Generate Worker

**First, resolve scope explicitly — do not infer silently.** Ask (or confirm from clear context) whether this worker is:
- **Company-scoped** (only meaningful for one tenant) → `companies/{company}/workers/{worker-id}/`
- **Shared** (release-shipped, useful across all HQ installs) → `core/workers/public/{worker-id}/`

A company-scoped worker placed in `core/` would be lost on the next `/update-hq` wholesale-replace and leaks one tenant's specifics into the shared scaffold. When in doubt, default to company scope and confirm. See `core/policies/hq-customizations-live-in-personal-or-company.md`.

Then create the folder at the resolved path and **echo the chosen scope + target path before scaffolding.**

### worker.yaml

```yaml
worker:
  id: {worker-id}
  name: "{Human Name}"
  type: {WorkerType}
  version: "1.0"

identity:
  persona: {your-name}  # or company_context, voice_guide

execution:
  mode: {on-demand|scheduled|event-triggered}
  schedule: "{cron if scheduled}"
  max_runtime: 10m
  retry_attempts: 2

context:
  base:
    - {always-loaded-files}
  dynamic:
    - {per-task-files}
  exclude:
    - "*.log"
    - "node_modules/"

verification:
  post_execute:
    - {checks}
  approval_required: {true|false}

context_needs:
  # Reference core/knowledge/context-needs/registry.yaml for type defaults
  # Only include if overriding type defaults
  extends: {WorkerType}  # Inherit type defaults
  overrides:  # Optional: override specific needs
    required:
      - file: {context-file}
        reason: "{why this worker needs this}"

tasks:
  source: personal/projects/{associated-project}/prd.json  # Or companies/{co}/projects/{associated-project}/prd.json
  one_at_a_time: true

output:
  destination: workspace/{output-folder}/
  format: {markdown|json}

instructions: |
  {Worker-specific instructions and constraints}
```

### Registry — Auto-Generated

`core/workers/registry.yaml` is an auto-generated index produced by `core/scripts/generate-workers-registry.sh` (invoked from `.claude/hooks/reindex.sh` on every Stop / PostToolUse-Write). **Do not edit it directly.** Just create the worker.yaml with `worker.id`, `worker.type`, `worker.description` and the registry regenerates automatically. Optional fields the generator picks up: `worker.status` (default "active"), `worker.company`, `worker.team`.

### Update Context Needs Registry (if overriding defaults)

If the worker has context needs different from its type's defaults, add to `core/knowledge/context-needs/registry.yaml`:

```yaml
workers:
  {worker-id}:
    extends: {WorkerType}
    overrides:
      required:
        - file: {context-file}
          reason: "{why this worker specifically needs this}"
    additional_external:
      - type: {external-context-type}
        path: {path-to-external-context}
        when: "{when this context is needed}"
```

**Skip this if:** The worker's needs match its type's defaults (most common case).

### Task Source Options

Workers can get tasks from:

1. **Project PRD** (recommended): `personal/projects/{project-name}/prd.json` or `companies/{co}/projects/{project-name}/prd.json`
   - For workers that implement features
   - Reference existing project or create one with `/plan`

2. **Queue file**: `companies/{company}/workers/{worker-id}/queue.json` (or `core/workers/public/{worker-id}/queue.json` for shared)
   - For workers with simple, repeating tasks (posting, monitoring)
   - Create with:
     ```json
     {
       "worker": "{worker-id}",
       "tasks": []
     }
     ```

**Do NOT create prd.json inside worker directories.** PRDs belong in `personal/projects/` or `companies/{co}/projects/`.

## Rules

- Follow existing worker patterns
- One task at a time (Ralph principle)
- Always include verification
- Default to `approval_required: true` for external actions
- **Registration is automatic** — `worker.yaml` is the source of truth; registry regenerates on save
- **Always reindex** — run `qmd update` after creation

## After Creation

### Register Worker

The `worker.yaml` you just created IS the registration. `core/workers/registry.yaml` regenerates from it automatically when reindex fires (Stop / PostToolUse-Write hook). No manifest edits required for shared workers; company-scoped workers are discovered via the `worker.company:` field inside their own `worker.yaml`.

To force an immediate regen: `bash core/scripts/generate-workers-registry.sh`.

### Capture Learning (Auto-Learn)

Run `/learn` to register the new worker in the learning system:
```json
{
  "source": "build-activity",
  "severity": "medium",
  "scope": "global",
  "rule": "Worker {worker-id} exists at companies/{company}/workers/{worker-id}/ (or core/workers/public/{worker-id}/ if shared) for {1-sentence purpose}",
  "context": "Created via /newworker"
}
```

### Reindex + Update INDEX

1. `qmd update 2>/dev/null || true`
2. Regenerate `core/workers/public/INDEX.md` (shared workers) or `companies/{company}/workers/INDEX.md` (company workers) per `core/knowledge/public/hq-core/index-md-spec.md`.

### Report to User

Provide next steps:
1. "Worker created at `companies/{company}/workers/{worker-id}/` (or `core/workers/public/{worker-id}/` if shared)"
2. "Registry auto-regenerated on next reindex (or run `bash core/scripts/generate-workers-registry.sh` to force)"
3. "Test with on-demand execution first"
4. If using queue: "Add tasks to queue.json to get started"
5. If using PRD: "Run `/plan {project-name}` to create the PRD, then link it in worker.yaml"
