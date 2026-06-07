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

**Personal overlay (`personal/policies/`).** Files in `personal/policies/<slug>.md` are user-personal authoring locations. The `reindex.sh` Stop/PostToolUse hook symlinks each entry into `core/policies/<slug>.md`, so personal entries become indistinguishable from core at load time — they are *not* a separate precedence layer. Author user-global policies here; they will be picked up by the SessionStart trigger hook (`inject-policy-on-trigger.sh`) and surface through the global scope.

> **`personal/policies/` is the default home for operator-global rules — including everything `/learn` captures at global/command scope.** `core/policies/` is release-shipped scaffold that `/update-hq` replaces wholesale, so a rule written directly there is lost on the next upgrade. `/learn` therefore never writes to `core/policies/`; it writes operator-universal rules to `personal/policies/` (re-symlinked into `core/policies/` by `reindex.sh`, so they still load as global) and company/repo rules to their own scoped dirs. The only sanctioned path *into* `core/policies/` is the staging → `/promote-hq-core` pipeline, for policies that genuinely ship to every HQ install. This is enforced mechanically by `protect-core.sh`, which blocks creation of a new `.md` under `core/policies/` (override: `HQ_ALLOW_CORE_POLICY_WRITE=1`). Authoritative rule: `core/policies/hq-customizations-live-in-personal-or-company.md`.

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
| `applies_to` | array | Workspace stack tags (documentation only — the stack-based filtering it once drove was retired with the policy digest). Omit for cross-cutting policies. See **Applicability Tagging** below. |
| `when` | string | Boolean trigger expression evaluated just-in-time to inject the policy when relevant. See **Trigger Expressions** below. |
| `on` | array | Evaluation site(s) for `when` — any of `PreToolUse`, `UserPromptSubmit`, `PostToolUse`, `SessionStart`, or the pseudo-event `AssistantIntent` (AI-message-only facts). Defaults to `[PreToolUse]` when `when` is set and `on` is omitted. |

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

**Status of `applies_to` filtering:** The `applies_to` field remains a documented part of the policy schema, but its **stack-based digest-filtering behavior was retired together with the policy digest**. The former pipeline — `build-policy-digest.sh` embedding `applies_to` as an HTML-comment suffix on each digest line, and `load-policies-for-session.sh` resolving the active service set from `manifest.yaml`/`stack.yaml` to drop disjoint lines — no longer exists. The current SessionStart trigger hook (`inject-policy-on-trigger.sh`) injects on:[SessionStart] policies and does **not** stack-filter on `applies_to`. Keep tagging stack-specific policies for documentation/clarity, but do not rely on `applies_to` to suppress a policy at runtime.

### Trigger Expressions (`when:` / `on:`)

`when:` decides *when* a policy is injected **just-in-time** during a session.
The SessionStart trigger hook (`inject-policy-on-trigger.sh`) injects every
on:[SessionStart] policy at session start; reactive `when:` policies fire later
on a concrete signal. A reactive `when:` policy costs nothing until its
expression is true, then a short `<policy-reminder>` is injected once per session.

**Expression grammar — a tiny boolean algebra over open tokens:**

```yaml
when: git && push && shared_branch     # AND
when: deploy || share                  # OR
when: git && ! shared_branch           # NOT (use the derived shared_branch fact, not a literal branch name)
when: git && ( push || commit )        # parentheses / precedence
when: .mcp.json || settings.json       # filename tokens (dots/slashes allowed)
when: /brainstorm || /deep-plan        # slash-command tokens
```

- **Tokens are open** — there is no fixed vocabulary. An identifier is TRUE iff
  it appears in the fact set derived for the current event; an absent or
  misspelled identifier is simply FALSE.
- **Identifier charset:** `[A-Za-z0-9_./][A-Za-z0-9_./-]*` — letters, digits,
  `_ . / -`, and may start with `.` or `/`. So a filename (`.mcp.json`,
  `settings.json`) or a slash-command (`/brainstorm`) is a single literal token.
- **Operators:** `&&` (and), `||` (or), `!` (not), `( )` (grouping). Nothing else.
- **Fail-open:** an empty or malformed/unsafe expression injects the policy
  rather than silently hiding it (a typo never suppresses a hard rule).

**`on:` selects the evaluation site(s):**

```yaml
on: [PreToolUse]                       # default when omitted
on: [PreToolUse, UserPromptSubmit]     # also evaluate on the user's message
on: [PostToolUse]                      # evaluate against the tool's output
on: [AssistantIntent]                  # evaluate against what the AI said it will do
on: [SessionStart]                     # introduce at the very start of a session
```

`SessionStart` evaluates `when` against **static facts only** (`company`, `repo`,
`shared_branch`) plus the reserved **`always`** token. Use `when: always` +
`on: [SessionStart]` for advisory policies that should be introduced at the very
start regardless of context. There is no longer a pre-built digest to dedup
against, so **every** policy whose `on:` includes `SessionStart` and whose `when:`
matches is injected unconditionally — hard and soft alike.

**`always`** is a reserved token present in every fact set — `when: always`
matches unconditionally. It is the canonical "no condition" expression.

`AssistantIntent` is a **pseudo-event**, not a real Claude Code hook. It is
evaluated wherever an AI-message look-back exists — during `PreToolUse` and
`UserPromptSubmit` hook runs — but against a fact set built **only** from the
assistant's recent messages (see below), with no command/prompt/static facts.
Use it for "fire on what the AI is about to do" independent of the literal
command. (Tool events are CLI/Bash-only; `PreToolUse`/`PostToolUse` skip
non-Bash tools.)

**Facts available per channel** (derived by
[`core/scripts/derive-trigger-facts.sh`](../../../scripts/derive-trigger-facts.sh)):

Each text channel emits **every word token** in its text (lowercased, letter-led,
length ≥ 2) — open tokenization, no curated keyword list — plus the non-literal
derived facts (`secret`, `shared_branch`, filename, slash-command). So a policy
keys on whatever word naturally appears when it is relevant (`refactor`,
`monitor`, `docker`, `linear`, …) with nothing to register in advance.

| Source | Tokens |
|--------|--------|
| `PreToolUse` Bash command | every word of the command (`git`, `push`, `commit`, …); `gh pr`→`pr`; `op://`/`AWS_PROFILE`/`.env`→`secret`; a shared branch name→`shared_branch` |
| `PreToolUse` other tools | lowercased tool name (`glob`, `grep`, `read`, `write`, `edit`) |
| `UserPromptSubmit` | every word token of the user's message |
| `PostToolUse` | every word token of the tool's **output** |
| `AssistantIntent` | every word token of assistant message text since the last user turn — **AI-message only, no static facts** |
| `SessionStart` | static facts only (no command/prompt/AI tokens) |
| Static session facts (real events only) | `company`, `repo`, `shared_branch` (current branch) |
| Any text channel (command / prompt / output / AI-intent) | **filename tokens** — see below |
| Every fact set | `always` (reserved — `when: always` matches unconditionally) |

The raw `PreToolUse`/`UserPromptSubmit` fact sets deliberately **exclude** the
look-back so the command/prompt channel and the AI-intent channel stay distinct.

**Filename tokens.** Any file reference in the evaluated text emits two extra
facts: a literal basename token and a `.ext` token. `.claude/settings.json` yields
`settings.json` + `.json`; `.mcp.json` yields `.mcp.json` + `.json`; `shot.png`
yields `shot.png` + `.png`. The leading dot of a directory is dropped with the
path; a dotfile keeps its own leading dot. This is how a file-scoped policy fires
from `AssistantIntent` — the assistant names the file it is about to edit or read
(`when: settings.json`, `when: .mcp.json`, `when: .png || .jpg`) even though the
hook never sees the non-Bash Edit/Read tool call itself. Extensions must be
letter-led, so dotted version numbers (`v1.5`, `3.13`) are not mistaken for files.

**Slash-command tokens.** A `/command` mentioned in the evaluated text emits a
`/command` fact (`/brainstorm`, `/deep-plan`), so a slash-command-scoped policy
fires when the command is invoked or referenced in a prompt (`when: /deep-plan`).
The slash must follow a space or start-of-text, so path segments (`repos/public`)
are not treated as commands.

**How it is applied:**

1. [`.claude/hooks/inject-policy-on-trigger.sh`](../../../.claude/hooks/inject-policy-on-trigger.sh)
   takes the event from `hook_event_name`, derives facts, and for each in-scope
   policy whose `on:` includes the event evaluates `when:` via
   [`core/scripts/eval-trigger.sh`](../../../scripts/eval-trigger.sh) (exit 0=match,
   1=skip, 2=fail-open).
2. **Scope is tenant-safe:** global `core/policies` always; the active company's
   and active repo's policies only when the session is in that company/repo — so
   one tenant's `when: git` never injects during another's session.
3. Matches are injected as a `<policy-reminder>` and recorded in
   `workspace/orchestrator/policy-trigger-state/<session_id>.txt` (deduped — a
   slug fires at most once per session).
4. A legacy hardcoded regex map in the same hook still fires for precise
   PreToolUse patterns a coarse boolean token cannot express (e.g.
   `git checkout {ref} -- .`). Both paths dedupe by slug, so migrating a policy
   to `when:` is incremental and never double-injects.

**Auto-backfill at SessionStart.** A policy authored without `when:`/`on:` does
not stay untriggered: [`core/scripts/migrate-policy-triggers.sh`](../../../scripts/migrate-policy-triggers.sh)
runs as a SessionStart hook and derives a trigger from the policy's own
metadata — `when:` from its `tags:` (topical vocabulary, `vendor:x`→`x`, meta
tags dropped) OR'd with an action expression parsed from its `trigger:` prose;
`on: [PreToolUse, PostToolUse, UserPromptSubmit, AssistantIntent]` (every live
event — `when:` does the filtering). If neither tags nor trigger yield a signal
it falls back to `when: always` + `on: [SessionStart]`. The script is **strictly
idempotent**: a policy that already declares `when:` (authored or human-tuned) is
never rewritten — so it backfills new policies only, with zero writes in steady
state. Hand-tuning a generated trigger is therefore permanent.

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
