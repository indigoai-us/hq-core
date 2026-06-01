---
type: reference
domain: [operations, engineering]
status: canonical
tags: [policies, spec, learned-rules, enforcement, frontmatter, governance]
relates_to: []
---

# Policies Spec

## What is a Policy?

A **policy** is a standing operational rule that defines how work is done. Policies are proactive directives — they prescribe behavior before problems occur. They also serve as the canonical location for learned rules captured during execution.

Agents check applicable policies before executing tasks and follow them throughout execution.

## Directory Convention

Policies live in three locations, checked in this precedence order:

```
companies/{co}/policies/*.md       # Company-scoped (highest precedence)
repos/{pub|priv}/{repo}/.claude/policies/*.md  # Repo-scoped
core/policies/*.md              # Cross-cutting + command-scoped (lowest)
```

Each directory can have zero or more policy files. Policies are plain Markdown files with YAML frontmatter.

**Personal overlay (`personal/policies/`).** Files in `personal/policies/<slug>.md` are user-personal authoring locations. The `master-sync.sh` Stop/PostToolUse hook symlinks each entry into `core/policies/<slug>.md`, so personal entries become indistinguishable from core at load time — they are *not* a separate precedence layer. Author user-global policies here; they will be picked up by `build-policy-digest.sh` and surface through the global scope.

> **`personal/policies/` is the default home for operator-global rules — including everything `/learn` captures at global/command scope.** `core/policies/` is release-shipped scaffold that `/update-hq` replaces wholesale, so a rule written directly there is lost on the next upgrade. `/learn` therefore never writes to `core/policies/`; it writes operator-universal rules to `personal/policies/` (re-symlinked into `core/policies/` by `master-sync.sh`, so they still load as global) and company/repo rules to their own scoped dirs. The only sanctioned path *into* `core/policies/` is the staging → `/promote-hq-core` pipeline, for policies that genuinely ship to every HQ install. This is enforced mechanically by `protect-core.sh`, which blocks creation of a new `.md` under `core/policies/` (override: `HQ_ALLOW_CORE_POLICY_WRITE=1`). Authoritative rule: `core/policies/hq-customizations-live-in-personal-or-company.md`.

## File Format

```markdown
---
id: {scope-prefix}-{slug}
title: Short descriptive title
scope: company | repo | command | global
trigger: when-this-policy-applies
enforcement: hard | soft
version: 1
created: YYYY-MM-DD
updated: YYYY-MM-DD
public: false
---

## Rule

One or more clear, imperative statements defining what agents must do (or must not do).

## Rationale

Why this policy exists. What problem it prevents or what outcome it ensures.

## Examples

Optional. Concrete examples of correct and incorrect behavior under this policy.
```

## Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique identifier: `{prefix}-{slug}` (e.g. `acmeflow-docs-update`, `hq-git-branch-verify`, `{product}-staging-first`) |
| `title` | string | Human-readable title |
| `scope` | enum | `company`, `repo`, `command`, `global`, `team`, `worker`, `project` |
| `trigger` | string | When the policy applies (e.g. "before any task execution", "when deploying", "before any git commit") |
| `enforcement` | enum | `hard` (must follow, blocks execution if violated) or `soft` (should follow, deviations noted) |
| `version` | integer | Starts at 1, incremented on material changes |
| `created` | date | ISO date of creation |
| `updated` | date | ISO date of last update |

## Optional Fields

| Field | Type | Description |
|-------|------|-------------|
| `source` | string | Origin of the policy: `manual`, `migration`, `task-completion`, `back-pressure-failure`, `user-correction`, `pattern-repetition` |
| `learned_from` | string | Task ID or session reference (for auto-generated policies) |
| `command` | string | Command name (for `scope: command` policies only, e.g. `prd`, `email`) |
| `applies_to` | array | Workspace stack tags — policy loads only when at least one tag matches the active workspace's services. Omit for cross-cutting policies (load everywhere). See **Applicability Tagging** below. |

### Applicability Tagging (`applies_to`)

Stack-specific policies (Vercel, Shopify, Clerk, Expo/EAS, etc.) can be tagged so they only surface in workspaces that actually use the relevant service. Cross-cutting policies (git, bash, email, general HQ) omit the field and load everywhere.

**Schema:**

```yaml
applies_to: [vercel, clerk]   # OR semantics — loads if ANY tag matches active stack
```

**Tag vocabulary:** reuse the `services:` enum from [`companies/manifest.yaml`](../../../companies/manifest.yaml) (attio, aws, clerk, shopify, stripe, supabase, linear, slack, expo, gmail, meta, ...) plus the inferred platform tags `vercel` (from `vercel_team:`) and `aws` (from `aws_profile:`). Never invent new tag values — run [`core/scripts/validate-policy-tags.sh`](../../../scripts/validate-policy-tags.sh) to lint against the enum.

**When to tag:** only when the policy is *wrong or useless* without the service. Examples:

- ✅ `vercel-env-no-trailing-newline` → `applies_to: [vercel]` (Vercel-specific env-var quirk)
- ✅ `clerk-vercel-edge-removal` → `applies_to: [clerk, vercel]` (spans two stacks)
- ❌ `hq-git-branch-verify` (generic git hygiene — no tag, loads everywhere)
- ❌ A deployment policy that *mentions* Vercel as one example among many — do NOT tag; transitive mentions don't count

**Semantics:**

- **OR across tags:** `[clerk, vercel]` means "load if the workspace has clerk OR vercel."
- **Missing field:** policy has no stack restrictions → always loads (the 89%+ case).
- **Unknown active stack:** if the workspace hasn't declared a service set (`services: []` and no `vercel_team`/`aws_profile`), the filter treats it as "unknown" and loads all policies — fail-open, same as untagged.

**How the filter is applied:**

1. [`core/scripts/build-policy-digest.sh`](../../../scripts/build-policy-digest.sh) embeds each tagged policy's `applies_to` as an HTML-comment suffix on its digest line (`- [hard] **id**: rule... <!-- applies_to: vercel -->`).
2. [`.claude/hooks/load-policies-for-session.sh`](../../../.claude/hooks/load-policies-for-session.sh) resolves the active service set per session from `companies/{ACTIVE_CO}/manifest.yaml` (primary) or `.claude/stack.yaml` (fallback for starter-kit users with no company context).
3. The hook filters digest lines whose `applies_to:` comment is disjoint from the active set before emitting the `<policy-digest>` block.
4. No active set resolved → digest passes through unchanged (backwards compat).

## Optional Sections

- **Examples**: Concrete correct/incorrect behavior
- **Exceptions**: When the policy does not apply
- **Related**: Links to other policies, knowledge, or workers

## ID Prefix Convention

| Scope | Prefix | Example |
|-------|--------|---------|
| Company | `{company}-` | `acmeflow-docs-update` |
| Repo | `{repo-slug}-` | `{product}-staging-first` |
| Command | `hq-cmd-{name}-` | `hq-cmd-prd-question-batching` |
| Global | `hq-` | `hq-git-branch-verify` |

## How Agents Use Policies

1. Before executing a task, load policies from all applicable directories:
   - `companies/{co}/policies/` (determine company from context — at SessionStart this resolves from cwd, the owning repo via `manifest.yaml`, or the `company_slug` persisted to the session by `/startwork`)
   - `{repo}/.claude/policies/` (if working inside a repo)
   - `core/policies/` (always — this already includes operator rules authored in `personal/policies/`, which are symlinked in)
2. Read each policy's `trigger` field to determine if it applies to the current task
3. Follow all applicable `hard` enforcement policies — violation blocks task completion
4. Follow all applicable `soft` enforcement policies — deviations are acceptable with justification
5. **Precedence:** company > repo > command > global. If policies conflict, higher-precedence wins

## Auto-Generated Policies

The `/learn` command creates policy files automatically from execution learnings. These use the same format with the optional `source` and `learned_from` fields populated.

**Enforcement defaults:**
- `enforcement: hard` — user corrections (`source: user-correction`), critical severity, NEVER rules with safety implications
- `enforcement: soft` — informational patterns, reference rules, success patterns

**Slug generation:** First 4-5 meaningful words from the rule, lowercased, hyphenated. Deduplicated against existing files in target directory.

## Repo-Level Policies

Repos can have their own policies at:

```
repos/{pub|priv}/{repo}/.claude/policies/*.md
```

Repo-level policies use the same format as company policies. The `id` field uses `{repo-slug}-{policy-slug}` format (e.g. `{product}-no-force-push`).

Agents check repo-level policies when working within that repo. The `/learn` command auto-creates this directory when writing a repo-scoped policy.

## Global HQ Policies

Cross-cutting rules that apply to all companies and repos live at:

```
core/policies/*.md
```

These are always loaded regardless of company or repo context. They have the lowest precedence — company and repo policies override them if conflicting.

## Command-Scoped Policies

Policies that apply to specific HQ commands live at `core/policies/` with `scope: command` and an additional `command: {name}` frontmatter field.

Example:
```yaml
---
id: hq-cmd-prd-question-batching
title: Limit PRD Discovery Question Batches
scope: command
command: prd
trigger: during /plan discovery phase
enforcement: soft
---
```

These are loaded when the specified command is invoked.

## Relationship to Other HQ Concepts

| Concept | Purpose | Location |
|---------|---------|----------|
| **Company Policies** | Company-scoped standing rules | `companies/{co}/policies/` |
| **Repo Policies** | Repo-scoped rules and learnings | `repos/{repo}/.claude/policies/` |
| **Global Policies** | Cross-cutting rules | `core/policies/` |
| **Worker Instructions** | Worker-specific behavioral rules | `worker.yaml instructions:` block |
| **Knowledge** | Reference material (facts, schemas, guides) | `companies/{co}/knowledge/` or `knowledge/public/` |
