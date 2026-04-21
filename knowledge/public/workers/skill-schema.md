---
type: reference
domain: [engineering]
status: canonical
tags: [skill-schema, worker-skills, interface, tooling, discovery]
relates_to: []
---

# Skill Interface Schema

Formalized skill structure for consistent tooling and discovery. Inspired by Loom's tool system.

## Skill Definition

Skills can be defined as YAML (in worker.yaml) or as standalone .md files with YAML frontmatter.

### Inline in worker.yaml

```yaml
worker:
  id: cfo-{company}
  # ...

skills:
  - id: mrr
    name: "MRR Report"
    description: "Current MRR from Stripe subscriptions"

    interface:
      inputs:
        - name: months
          type: number
          default: 1
          description: "Months to include"
      outputs:
        - name: report
          type: markdown
          destination: workspace/reports/finance/

    verification:
      - command: "test -f {output}"
        description: "Output file exists"

    mutating: false
```

### Standalone Skill File

`workers/{worker-id}/skills/{skill-id}.md`:

```yaml
---
skill:
  id: mrr
  name: "MRR Report"
  description: "Current MRR from Stripe subscriptions"

  interface:
    inputs:
      - name: months
        type: number
        default: 1
    outputs:
      - name: report
        type: markdown
        destination: workspace/reports/finance/

  verification:
    - command: "test -f {output}"

  mutating: false
---

# MRR Report Skill

Instructions for executing this skill...
```

## Schema Reference

### Core Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | yes | Unique skill identifier |
| `name` | string | yes | Human-readable name |
| `description` | string | yes | Brief description |
| `mutating` | boolean | no | Triggers PostToolsHook if true |

### Interface

```yaml
interface:
  inputs:
    - name: string         # parameter name
      type: string         # string, number, boolean, array
      required: boolean    # default: false
      default: any         # default value
      description: string  # help text

  outputs:
    - name: string         # output name
      type: string         # markdown, json, file, git_commit
      destination: string  # output path pattern
```

### Verification

```yaml
verification:
  - command: string        # shell command (use {output} placeholder)
    description: string    # what this verifies
    must_pass: boolean     # default: true
```

### Mutating Flag

If `mutating: true`:
- PostToolsHook runs after execution
- Thread auto-saved
- Metrics logged

Mutating skills typically:
- Write files
- Make git commits
- Modify external state

## Input Types

| Type | Description | Example |
|------|-------------|---------|
| `string` | Text input | `"customer-cube"` |
| `number` | Numeric | `6` |
| `boolean` | True/false | `true` |
| `array` | List | `["a", "b"]` |
| `date` | ISO date | `"2026-01-23"` |
| `path` | File path | `"workspace/reports/"` |

## Output Types

| Type | Description |
|------|-------------|
| `markdown` | Markdown file |
| `json` | JSON file |
| `file` | Generic file |
| `git_commit` | Creates commit |
| `console` | Prints to console |

## Example Skills

### Read-Only (non-mutating)

```yaml
skills:
  - id: mrr
    name: "MRR Report"
    description: "Current MRR"
    interface:
      outputs:
        - type: console
    verification: []
    mutating: false
```

### File-Generating (mutating)

```yaml
skills:
  - id: monthly-report
    name: "Monthly Report"
    description: "Generate monthly financial report"
    interface:
      inputs:
        - name: month
          type: string
          required: true
      outputs:
        - name: report
          type: markdown
          destination: "workspace/reports/finance/{month}-report.md"
    verification:
      - command: "test -f workspace/reports/finance/{month}-report.md"
    mutating: true
```

## See Also

- [Worker Framework](./README.md)
- [State Machine](./state-machine.md)
- [Loom Tools](../loom/tools.md) - Inspiration
