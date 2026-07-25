---
name: learn
description: Turn reusable findings into scoped policies or insight files.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash(qmd:*), Bash(grep:*), Bash(mkdir:*), Bash(date:*), Bash(ls:*), Bash(bash:*), Bash(git:*), Bash(rm:*), Bash(stat:*), Bash
---

# Learn - Automated Learning Pipeline

Capture a learning, classify it, and inject the rule directly into the file it governs (or the insight into the insight tree).

Called programmatically by `/execute-task` and `/run-project` after task completion or failure. Also callable manually with `--hard` flag for hard-enforcement rules (formerly `/learn --hard`). `/handoff` and `/checkpoint` call this for session insights.

**Input:** the user's argument — structured JSON event data, free text description, or empty/"auto" for hook-triggered mode.

## Core Principle

**Two output types, one pipeline.** Content is classified (Step 1.5) and routed to the appropriate format:

### Rules → Policy files (operational directives)

| Scope | Target directory | Format |
|-------|-----------------|--------|
| Company | `companies/{co}/policies/{slug}.md` | Policy file (YAML frontmatter + Rule + Rationale) |
| Repo | `repos/{pub\|priv}/{repo}/.claude/policies/{slug}.md` | Policy file |
| Command (operator) | `personal/policies/{slug}.md` (scope: command) | Policy file |
| Global / personal (**default**) | `personal/policies/{slug}.md` (scope: global) | Policy file |
| Worker (legacy) | `core/workers/*/{id}/worker.yaml` | Instructions block `## Learnings` |

> **`/learn` never writes to `core/policies/`.** `core/` is release-shipped scaffold, replaced wholesale by `/update-hq` — anything written there is lost on the next upgrade (hard policy `hq-customizations-live-in-personal-or-company`). Operator-universal learnings go to `personal/policies/`, which the policy trigger hook (`inject-policy-on-trigger.sh`) reads directly — no `core/policies/` mirror — so they still load as global at SessionStart while living in an upgrade-safe location. A genuine product-level core policy (one that should ship to *every* HQ install) is **not** captured via `/learn`: author it locally, then publish through the hq-core staging repo + `/promote-hq-core` (see `staging-promotion-required`). If a learning is judged truly core, `/learn` stops and points you at that pipeline rather than writing into `core/`.

### Insights → Insight files (educational understanding)

| Scope | Target directory | Format |
|-------|-----------------|--------|
| Global / repo | `workspace/insights/global/{slug}.md` | Insight file (YAML frontmatter + Insight + Context) |
| Company | `companies/{co}/knowledge/insights/{slug}.md` | Insight file (inside company knowledge repo) |
| Tool | `workspace/insights/tools/{slug}.md` | Insight file |
| Conceptual | `workspace/insights/concepts/{slug}.md` | Insight file |

See `core/knowledge/public/hq-core/insights-spec.md` for the insight file format.

**Before creating:** always scan existing policies/insights for updates (Step 4.5). Update > duplicate.

## Step 0: Load Policies (frontmatter-only gate)

Before processing, load applicable policies with minimal context burn:

1. For each file in `core/policies/` (skip `example-policy.md`), run `bash core/scripts/read-policy-frontmatter.sh {file}` to get frontmatter-only
2. Note `enforcement: hard` titles. Only Read the `## Rule` section of hard-enforcement policies if one looks relevant to the current learning

Skip full policy body loads — the frontmatter contains enough metadata for the learn pipeline.

## Step 1: Parse Input

Three input modes:

### Mode 1: Hook-Triggered (auto/empty input)

If the argument is empty or "auto":

1. Check for `workspace/learnings/.observe-patterns-latest.json`
2. If file exists, read it and extract the `observations` array
3. For each observation in the array:
   - Extract `pattern_type`, `confidence`, `description`, `severity`, `evidence`
   - Generate a structured learning event with `source: "hook-observation"`, `scope: "global"` (or inferred from pattern type)
   - Process through Steps 2–9 (extract rules, classify scope, dedup, inject, etc.)
4. Delete the file after processing all observations
5. Report each learning processed

Example `.observe-patterns-latest.json`:
```json
{
  "metadata": {
    "created_at": "2026-03-07T21:35:00Z",
    "session_end_timestamp": "20260307-213500",
    "git_branch": "main",
    "git_commit": "abc1234",
    "project_context": "hq"
  },
  "observations": [
    {
      "pattern_type": "back-pressure-retry",
      "confidence": 0.8,
      "description": "Git log shows fixup/amend commits",
      "severity": "high",
      "evidence": "fixup commits in recent history",
      "recommendation": "Extract pattern about what caused retry"
    }
  ]
}
```

Note: in Codex runtime, the observe-patterns hook is not wired up, so this mode typically returns empty — fall through to manual modes.

### Mode 2: Structured JSON (from /execute-task, /run-project, /handoff, /checkpoint)

If input is a JSON object:
```json
{
  "task_id": "TASK-001",
  "project": "my-project",
  "source": "back-pressure-failure|user-correction|success-pattern|task-completion|build-activity|hook-observation|session-insight",
  "severity": "critical|high|medium|low",
  "scope": "global|worker:{id}|command:{name}|knowledge:{path}|project:{slug}",
  "workers_used": ["backend-dev"],
  "back_pressure_failures": [{"worker": "frontend-dev", "check": "lint", "error": "..."}],
  "retries": 0,
  "key_decisions": ["..."],
  "issues_encountered": ["..."],
  "patterns_discovered": ["..."]
}
```

Parse it and proceed to Step 1.5.

### Mode 3: Free Text (manual invocation or /learn --hard delegation)

Parse for keywords to determine scope. Generate rule statement from the description. Proceed to Step 1.5.

### Mode 4: Batch Input (from /handoff or any caller passing an array)

If the input starts with `[` (JSON array), enter batch mode:

**Batch input format:**
```json
[
  {"type": "rule|insight", "content": "...", "scope": "global|company:{co}|...", "source": "..."},
  ...
]
```

**Batch processing rules:**

1. **Detect batch input:** if the input is a JSON array (starts with `[`), enter batch mode
2. **Run qmd vsearch dedup ONCE for all items:** concatenate all item `content` fields as a single query string for a single `qmd vsearch` call, then match results against each item individually
3. **Process each item through Steps 2–6 normally:** extract rules, classify scope, create/update policy files — one item at a time using the shared dedup results
4. **Write a single event log entry** covering all items processed in the batch
5. **Backward compatibility:** all existing modes (1, 2, 3) work exactly as before — batch is a new detection branch only

## Step 1.5: Classify Content Type

Determine if input is an operational rule or an educational insight:

| Signal | Type | Route to |
|--------|------|----------|
| NEVER/ALWAYS/condition→action | rule | Policy file (Steps 2–6) |
| "why X works", "pattern behind", conceptual explanation | insight | `workspace/insights/` or `companies/{co}/knowledge/insights/` (Step 5b) |
| User correction (`/learn --hard`) | rule | Policy file (always) |
| `back_pressure_failures` | rule | Policy file (always) |
| `patterns_discovered` (educational) | insight | Insight file (Step 5b) |
| `source: "session-insight"` | insight | Insight file (always — from `/handoff` or `/checkpoint` step 0c) |

**Default:** if ambiguous, route as policy (existing behavior). Insights are opt-in.

If content type is **insight**, skip Steps 2 and 5 (rule extraction and policy creation). Proceed to Step 3 for scope classification, Step 4 for dedup, then Step 5b for insight file creation.

## Step 2: Extract Rules

From structured input, generate rules:

- `back_pressure_failures` → `NEVER: {anti-pattern that caused failure}` (scope: worker:{id})
- `retries > 0` → Rule about what caused retry and how to avoid it
- `key_decisions` → `ALWAYS: {pattern}` if broadly applicable
- `issues_encountered` → Scoped rule to prevent recurrence
- `patterns_discovered` → `ALWAYS: {pattern}` for success patterns

From free text:
- Extract the core rule in NEVER/ALWAYS/condition→action format

If no meaningful rules can be extracted (task completed cleanly, no failures, no notable patterns), skip injection — log to event log only.

## Step 3: Classify Scope & Resolve Target

For each extracted rule, determine scope (most specific wins):

| Signal | Scope | Policy directory |
|--------|-------|------------------|
| Related to specific company | `company` | `companies/{co}/policies/` |
| Related to specific repo | `repo` | `repos/{pub\|priv}/{repo}/.claude/policies/` |
| Error in specific command | `command` | `personal/policies/` (with `scope: command`) |
| Failure in specific worker | `worker` | `core/workers/*/{id}/worker.yaml` instructions block (legacy, still supported) |
| Active session company (when no explicit repo, command, or global scope) | `company` | `companies/{co}/policies/` |
| Universal pattern (**default** when no company/repo/session context) | `global` | `personal/policies/` |
| User correction via /learn --hard | From context; default to active session company, then global | Detected scope directory |

**`/learn` does not target `core/policies/`.** The global/command rows route to `personal/policies/` — operator-owned and upgrade-safe — and the policy trigger hook reads `personal/policies/` directly (no `core/policies/` mirror), so each entry still loads as a global/command policy. Reserve `core/policies/` for release-shipped policies authored through the staging → `/promote-hq-core` pipeline. If a rule is genuinely product-core (must ship to every HQ install), stop and direct the user to that pipeline; never Write it into `core/`.

**Primary output = policy files.** The canonical format for persistent rules is structured policy files (per `core/knowledge/public/hq-core/policies-spec.md`). Worker.yaml injection is still supported for worker-specific learnings.

**Resolve company/repo context** (strongest signal wins):
- An explicit scope in the input or user request wins. Honor explicit `repo`, `command`, or `global` scope rather than the session default; explicit global scope targets `personal/policies/`. Verify an explicit company slug against the manifest.
- From the current working directory — the **leaf** `companies/<slug>/` segment (the last one in the path, not the first)
- From `prd.json` metadata if in project context
- From `companies/manifest.yaml` repo lookup if in repo context
- From worker path if worker-scoped (`companies/{co}/workers/` → `{co}`)
- From the active session: `bash core/scripts/hq-session.sh get company_slug`. For free-text and `/learn --hard` input with no explicit repo, command, or global scope, default to this active company and target `companies/{co}/policies/`.

**Verify every resolved slug, including the active session `company_slug`, exists in `companies/manifest.yaml`** before targeting `companies/{co}/policies/`. If the session value is absent or invalid, do not treat it as company context.

**Never silently fall back to a global target for a company-specific learning.** A global target (→ `personal/policies/`) is correct ONLY when the rule is genuinely universal to this operator's HQ. If a rule is clearly company-specific but the company can't be resolved unambiguously, **stop and ask which company** — do not default the write into `personal/policies/` (and never into `core/policies/`). A misrouted company policy syncs into the wrong tenant vault on the next `hq-sync` (HQ-Pro), a category-1 cross-company bug. See `core/policies/hq-company-scoped-writes-verify-company.md`.

## Step 4: Dedup Check

**Primary (if qmd available):**
```bash
qmd vsearch "{rule text}" --json -n 5
```

Check results for similarity to the new rule:
- Similarity > 0.85 → **Skip** (already captured somewhere)
- Similarity 0.6–0.85 → **Merge** (update existing rule to be more precise)
- Similarity < 0.6 → **Add new**

**Fallback (if qmd unavailable):**
Use Grep to search for key terms from the rule across the policy directories:
- Pattern: key terms from the rule (2-3 significant words)
- Files: `*.md` in `companies/*/policies/`, `personal/policies/`, `core/policies/` (the release-shipped set), and any repo policy dirs
- If matching content found → review and decide whether to merge or skip

Report dedup action taken.

## Step 4.5: Scan Existing Policies

Before creating a new rule, check if an existing policy file already covers this topic:

1. **Resolve policy directories** based on scope:
   - Company scope → scan `companies/{co}/policies/` (skip `example-policy.md`)
   - Repo scope → scan `{repoPath}/.claude/policies/`
   - Global/command scope → scan `personal/policies/` (the write target) and `core/policies/` (the release-shipped set)

2. **Search for matching policies:**
   ```bash
   # Grep policy titles and rules for keyword overlap
   grep -rl "{key terms from rule}" {policy_dir}/*.md 2>/dev/null
   ```
   Also check `qmd vsearch` results from Step 4 for hits in policy files.

3. **If matching policy found:**
   - Read the policy file
   - **Update** the existing policy: append to `## Rule` section, bump `version`, update `updated` date
   - If new learning contradicts existing policy, flag for user review instead of auto-merging
   - Set `dedup_action: "merged-into-policy"` in event log

4. **If no matching policy found:**
   - Proceed to Step 5 (create new rule)
   - For company/repo/global scoped rules, prefer creating a **policy file** (per `core/knowledge/public/hq-core/policies-spec.md`) over injecting into worker.yaml. Policy files are the canonical format for persistent rules. **Never** write a learned rule into `.claude/CLAUDE.md` / `AGENTS.md` — the charter is release-shipped scaffold, not a learning store (policy `learned-rules-never-in-claude-md`)

## Step 5: Create or Update Policy File (rule content type)

### Primary: Policy File (company/repo/global/command scopes)

If Step 4.5 found a matching policy → update was already handled. Otherwise, create a new policy file.

**Target directory:**
- Company scope → `companies/{co}/policies/{slug}.md`
- Repo scope → `repos/{pub|priv}/{repo}/.claude/policies/{slug}.md`
- Command scope (operator-authored) → `personal/policies/{slug}.md` (scope: command)
- Global scope → `personal/policies/{slug}.md` (scope: global) — **default for non-company/non-repo rules**

> Never Write a `.md` into `core/policies/` from `/learn` — it is lost on `/update-hq` and is now mechanically blocked by `protect-core.sh` (the block message points back here). `personal/policies/` entries are read directly by the policy trigger hook (no `core/policies/` mirror), so they load identically as global/command policies. Genuine product-core policies ship via the staging → `/promote-hq-core` pipeline only.

**Create the directory if needed:**
```bash
mkdir -p {target_directory}
```

**Policy file format** (per `core/knowledge/public/hq-core/policies-spec.md`):

```markdown
---
id: {scope-prefix}-{slug}
title: {Rule title}
when: {boolean trigger expr over context words, or `always`}
on: {[PreToolUse, PostToolUse, UserPromptSubmit, AssistantIntent] | [SessionStart]}
enforcement: {hard|soft}
public: {true|false}
version: 1
created: {YYYY-MM-DD}
updated: {YYYY-MM-DD}
source: {back-pressure-failure|user-correction|success-pattern|task-completion|hook-observation}
---

## Rule

{Rule in imperative form}

## Rationale

{Why this rule exists — from context/failure/correction}
```

**Enforcement mapping:**
- `source: user-correction` → `enforcement: hard`
- `severity: critical` → `enforcement: hard`
- Everything else → `enforcement: soft`

**`when:` / `on:` trigger (just-in-time injection):**
- `when:` is a boolean expression over an OPEN token set — any word that appears in the relevant command/prompt/AI-message text is a live token (`git && push`, `refactor`, `supabase`, `.tsx`, `/deep-plan`, `secret || credential`). Pick the word(s) that naturally show up when the rule is relevant. Operators: `&& || ! ( )`. Full grammar + fact derivation: `core/knowledge/public/hq-core/policies-spec.md`.
- `on:` is where it is evaluated. Default for a real trigger: `[PreToolUse, PostToolUse, UserPromptSubmit, AssistantIntent]` (the `when:` does the filtering). Use `[SessionStart]` **only** with `when: always` for ambient governance rules with no concrete signal.
- If you genuinely can't name a signal, use `when: always` + `on: [SessionStart]` — but prefer a real trigger so the rule loads just-in-time, not every session.
- You may omit both fields when `tags:` or `trigger:` supplies a derivable signal: the SessionStart `migrate-policy-triggers.sh` hook backfills them on the next session. If no signal is derivable, only an `enforcement: hard` policy receives the `when: always` + `on: [SessionStart]` fallback; soft or unset policies remain untriggered. Setting the fields at authoring time is better — the migrator never overwrites an existing `when:`.

**Policy frontmatter validation:** `when:` and `on:` are required and automatically checked by the `validate-policy-frontmatter.sh` write/edit hook. For stack-specific rules, express the service token in `when:` (for example, `when: vercel`); do not add retired applicability metadata. See `core/knowledge/public/hq-core/policies-spec.md` for the complete schema.

**Slug generation:** lowercase, hyphens, from rule keywords. Prefix: `{co}-` for company, `{repo}-` for repo, `hq-cmd-{name}-` for command, `hq-` for global.

### Fallback: Worker.yaml (worker-scoped learnings)

For worker-specific learnings, still inject into `core/workers/*/{id}/worker.yaml` instructions block:

```yaml
instructions: |
  ...existing instructions...

  ## Learnings
  - NEVER: {new rule}
```


## Step 5b: Create Insight File (insight content type only)

If Step 1.5 classified content as **insight**, skip Step 5 (policy creation) and create an insight file instead.

**Target directory by scope:**
- Global / repo-scoped → `workspace/insights/global/{slug}.md`
- Company-scoped → `companies/{co}/knowledge/insights/{slug}.md` (create `insights/` subdir if needed)
- Tool-specific → `workspace/insights/tools/{slug}.md`
- Conceptual/theoretical → `workspace/insights/concepts/{slug}.md`

**Insight file format** (per `core/knowledge/public/hq-core/insights-spec.md`):

```markdown
---
type: insight
domain: [engineering]
tags: [topic-tags]
scope: global | company:{co} | repo:{repo} | tool:{tool}
source_session: T-{timestamp}-{slug}
created: {YYYY-MM-DD}
confidence: high | medium
relates_to: []
---

# {Title}

## Insight

{Core conceptual understanding, 2-4 paragraphs. Educational, not directive.}

## Context

{When/why this matters. What situation makes this knowledge valuable.}

## Example

{Optional. Concrete example showing the insight in practice.}
```

**Slug generation:** kebab-case from title keywords, max 60 chars. No scope prefix (subdirectory provides scope).

**Confidence mapping:**
- Validated through execution/testing → `confidence: high`
- Observed but not extensively tested → `confidence: medium`

**After writing:** proceed to Step 7 (event logging).

## Step 6: Evaluate Global Promotion

Global promotion means **raising a rule's enforcement to hard, in a policy file** — never injecting it into the charter. Learned rules never go in `.claude/CLAUDE.md` / `AGENTS.md` (policy `learned-rules-never-in-claude-md`); they already surface for every session through the policy trigger hook (`inject-policy-on-trigger.sh`), so a hard-enforcement policy file *is* the global path.

If a rule meets ANY of:
- `severity == critical`
- `source == user-correction` (explicit `/learn --hard` invocation)
- Rule triggered 3+ times (check event log)

then ensure it lives as a **hard-enforcement policy file** at global scope:
- Personal/owner learnings → `personal/policies/{slug}.md` (read directly by the policy trigger hook — no `core/policies/` mirror — so it rides global scope and survives `/update-hq`).
- Release-shipped, all-users learnings → `core/policies/{slug}.md` with the public marker (promoted via `hq-pack-admin`).

Set `enforcement: hard` in the policy frontmatter and ensure the file carries `when:`/`on:` frontmatter so the SessionStart trigger hook surfaces it (Step 8). Do **not** touch `CLAUDE.md`.

## Step 7: Log Event

```bash
mkdir -p workspace/learnings
```

Write `workspace/learnings/learn-{YYYYMMDD-HHMMSS}.json`:
```json
{
  "event_id": "learn-{timestamp}",
  "content_type": "rule|insight",
  "rules": [
    {
      "rule": "NEVER: ...",
      "scope": "worker:frontend-dev",
      "target_file": "core/workers/public/dev-team/frontend-dev/worker.yaml",
      "severity": "high"
    }
  ],
  "source": "back-pressure-failure|session-insight",
  "task_id": "TASK-001",
  "project": "my-project",
  "dedup_action": "new|merged|skipped",
  "promoted_to_global": true,
  "created_at": "{ISO8601}"
}
```

The event log write is mandatory for every invocation (even skipped/trivial ones) — downstream tooling relies on it.

## Step 8: Reindex

```bash
qmd update 2>/dev/null || true
```

No manual digest rebuild is needed: policies surface automatically via the SessionStart trigger hook (`inject-policy-on-trigger.sh`) and the `migrate-policy-triggers.sh` backfill. Ensure any new policy file carries `when:`/`on:` frontmatter so it gets injected. (Personal entries under `personal/policies/` are read directly by the trigger hook — there is no mirror step, so a new file loads on the next qualifying event without any reindex.)

Insight-only runs (content_type: insight) write no policy file, so there is nothing for the trigger hook to surface.

**Batch mode note:** In batch mode (Mode 4), there is no per-item or end-of-batch digest step — each policy file written during the batch surfaces on its own via its `when:`/`on:` frontmatter.

## Step 9: Report

**For rules (content_type: rule):**
```
Learning captured:
  Scope: {company:<slug> | repo:<name> | command | global}
  Rule: {rule}
  Target: {policy file path | worker.yaml path}
  Action: {created-policy | updated-policy | merged-into-policy | worker-yaml-injection}
  Global: {promoted|not promoted}
  Dedup: {new|merged|skipped}
  Event: workspace/learnings/learn-{timestamp}.json
```

For any `scope: company` rule, **surface the resolved company slug and the full target path and confirm them before writing** — this is the visible checkpoint that catches a misroute before it reaches a tenant vault (`hq-company-scoped-writes-verify-company`).

**For insights (content_type: insight):**
```
Insight captured:
  Title: {insight title}
  Target: {insight file path}
  Action: {created-insight | updated-insight | merged-into-insight}
  Dedup: {new|merged|skipped}
  Event: workspace/learnings/learn-{timestamp}.json
```

If multiple rules/insights were extracted, report each.

## Rules

- **Policy files first** — always create structured policy files for company/repo/global/command scoped rules. Worker.yaml injection only for worker-specific learnings
- **Scan before create** — always check existing policies for updates before creating new files (Step 4.5)
- **Never inject empty/trivial rules** — "task completed successfully" is not a learning
- **Dedup is mandatory** — always check before injecting (qmd first, Grep fallback)
- **Learned rules never touch the charter** — never write a learned rule into `.claude/CLAUDE.md` / `AGENTS.md`; global promotion = a hard-enforcement policy file (policy `learned-rules-never-in-claude-md`)
- **Reindex after every injection** — keeps qmd search current
- **New policies need `when:`/`on:` frontmatter** — that is what the SessionStart trigger hook (`inject-policy-on-trigger.sh`) uses to surface a policy; no manual digest rebuild exists anymore
- **Event log is always written** — `workspace/learnings/learn-{timestamp}.json` is non-optional
- **Preserve existing rules** — append only, never overwrite existing rules
- **User corrections always promote** — /learn --hard delegations go to a hard-enforcement policy file (never CLAUDE.md)
- **Match existing style** — use the same rule format as existing rules in the target file
