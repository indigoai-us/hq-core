---
name: learn
description: Capture and classify learnings, route to structured policy files (rules) or insight files (educational knowledge). Deduplicates via qmd (Grep fallback), rebuilds policy digest after policy changes. Callable manually or from /execute-task, /run-project, /handoff, /checkpoint. Use --hard flag for hard-enforcement rules.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash(qmd:*), Bash(grep:*), Bash(mkdir:*), Bash(date:*), Bash(ls:*), Bash(bash:*), Bash(git:*), Bash(rm:*), Bash(stat:*)
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
| Command | `.claude/policies/{slug}.md` (scope: command) | Policy file |
| Global | `.claude/policies/{slug}.md` | Policy file |
| Worker (legacy) | `workers/*/{id}/worker.yaml` | Instructions block `## Learnings` |

### Insights → Insight files (educational understanding)

| Scope | Target directory | Format |
|-------|-----------------|--------|
| Global / repo | `workspace/insights/global/{slug}.md` | Insight file (YAML frontmatter + Insight + Context) |
| Company | `companies/{co}/knowledge/insights/{slug}.md` | Insight file (inside company knowledge repo) |
| Tool | `workspace/insights/tools/{slug}.md` | Insight file |
| Conceptual | `workspace/insights/concepts/{slug}.md` | Insight file |

See `knowledge/public/hq-core/insights-spec.md` for the insight file format.

**Before creating:** always scan existing policies/insights for updates (Step 4.5). Update > duplicate.

## Step 0: Load Policies (frontmatter-only gate)

Before processing, load applicable policies with minimal context burn:

1. Prefer the SessionStart-injected digest at `.claude/policies/_digest.md` if present — it already contains frontmatter for all global and command-scoped policies
2. Otherwise, for each file in `.claude/policies/` (skip `_digest.md` and `example-policy.md`), run `bash scripts/read-policy-frontmatter.sh {file}` to get frontmatter-only
3. Note `enforcement: hard` titles. Only Read the `## Rule` section of hard-enforcement policies if one looks relevant to the current learning

Skip full policy body loads — the digest and frontmatter contain enough metadata for the learn pipeline.

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
4. **Run `bash scripts/build-policy-digest.sh` ONCE at the end** (not per-item) — only if any item produced a policy file write
5. **Write a single event log entry** covering all items processed in the batch
6. **Backward compatibility:** all existing modes (1, 2, 3) work exactly as before — batch is a new detection branch only

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
| Error in specific command | `command` | `.claude/policies/` (with `scope: command`) |
| Failure in specific worker | `worker` | `workers/*/{id}/worker.yaml` instructions block (legacy, still supported) |
| Universal pattern | `global` | `.claude/policies/` |
| User correction via /learn --hard | From context, default global | Detected scope directory |

**Primary output = policy files.** The canonical format for persistent rules is structured policy files (per `knowledge/public/hq-core/policies-spec.md`). Worker.yaml injection is still supported for worker-specific learnings.

**Resolve company/repo context:**
- From `prd.json` metadata if in project context
- From `companies/manifest.yaml` repo lookup if in repo context
- From worker path if worker-scoped (`companies/{co}/workers/` → `{co}`)
- Fall back to `.claude/policies/` (global scope)

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
- Files: `*.md` in `companies/*/policies/`, `.claude/policies/`, and any repo policy dirs
- If matching content found → review and decide whether to merge or skip

Report dedup action taken.

## Step 4.5: Scan Existing Policies

Before creating a new rule, check if an existing policy file already covers this topic:

1. **Resolve policy directories** based on scope:
   - Company scope → scan `companies/{co}/policies/` (skip `example-policy.md`)
   - Repo scope → scan `{repoPath}/.claude/policies/`
   - Global/command scope → scan `.claude/policies/`

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
   - For company/repo/global scoped rules, prefer creating a **policy file** (per `knowledge/public/hq-core/policies-spec.md`) over injecting into worker.yaml or CLAUDE.md. Policy files are the canonical format for persistent rules

## Step 5: Create or Update Policy File (rule content type)

### Primary: Policy File (company/repo/global/command scopes)

If Step 4.5 found a matching policy → update was already handled. Otherwise, create a new policy file.

**Target directory:**
- Company scope → `companies/{co}/policies/{slug}.md`
- Repo scope → `repos/{pub|priv}/{repo}/.claude/policies/{slug}.md`
- Command scope → `.claude/policies/{slug}.md`
- Global scope → `.claude/policies/{slug}.md`

**Create the directory if needed:**
```bash
mkdir -p {target_directory}
```

**Policy file format** (per `knowledge/public/hq-core/policies-spec.md`):

```markdown
---
id: {scope-prefix}-{slug}
title: {Rule title}
scope: {company|repo|command|global}
trigger: {when this applies}
enforcement: {hard|soft}
public: {true|false}
version: 1
created: {YYYY-MM-DD}
updated: {YYYY-MM-DD}
source: {back-pressure-failure|user-correction|success-pattern|task-completion|hook-observation}
# applies_to: [vercel, clerk]   # optional — stack-specific filter; see mapping below
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

**`applies_to:` field mapping (stack applicability filter):**
- Include the `applies_to:` line ONLY when the rule is *wrong or useless* without a specific service. Tag vocabulary must match the `services:` enum used in `companies/manifest.yaml` plus inferred `vercel` / `aws`. Examples:
  - Rule about Vercel env-var newlines → `applies_to: [vercel]`
  - Rule spanning two stacks (e.g. Clerk edge runtime on Vercel) → `applies_to: [clerk, vercel]`
  - Generic git/bash/HQ hygiene rule, or a rule that merely *mentions* Vercel as one example → omit the field entirely (loads everywhere)
- OR semantics: `[clerk, vercel]` means "load if workspace has clerk OR vercel." Omit the field for the 89%+ cross-cutting case.
- Lint with `bash scripts/validate-policy-tags.sh` after write (it fails on unknown tags — prevents typos that would silently filter everywhere).
- Full spec: `knowledge/public/hq-core/policies-spec.md` → "Applicability Tagging (`applies_to`)" section.

**Slug generation:** lowercase, hyphens, from rule keywords. Prefix: `{co}-` for company, `{repo}-` for repo, `hq-cmd-{name}-` for command, `hq-` for global.

### Fallback: Worker.yaml (worker-scoped learnings)

For worker-specific learnings, still inject into `workers/*/{id}/worker.yaml` instructions block:

```yaml
instructions: |
  ...existing instructions...

  ## Learnings
  - NEVER: {new rule}
```

### Legacy: CLAUDE.md Learned Rules (global promotion only)

Only used for **global promotion** of critical/user-correction rules (Step 6). Not the primary target.

```markdown
- **{NEVER|ALWAYS}**: {rule} <!-- {source} | {date} -->
```

## Step 5b: Create Insight File (insight content type only)

If Step 1.5 classified content as **insight**, skip Step 5 (policy creation) and create an insight file instead.

**Target directory by scope:**
- Global / repo-scoped → `workspace/insights/global/{slug}.md`
- Company-scoped → `companies/{co}/knowledge/insights/{slug}.md` (create `insights/` subdir if needed)
- Tool-specific → `workspace/insights/tools/{slug}.md`
- Conceptual/theoretical → `workspace/insights/concepts/{slug}.md`

**Insight file format** (per `knowledge/public/hq-core/insights-spec.md`):

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

**After writing:** skip Step 6 (global promotion — insights never go in CLAUDE.md). Proceed to Step 7 (event logging).

## Step 6: Evaluate Global Promotion

If the rule was injected into a scoped file (worker/command/knowledge), also add to `.claude/CLAUDE.md` `## Learned Rules` if ANY:
- `severity == critical`
- `source == user-correction` (explicit /learn --hard invocation)
- Rule triggered 3+ times (check event log)

### Cap Enforcement

`## Learned Rules` is capped at 20 rules.

1. Count existing rules in section
2. If >= 20: find the oldest rule (by date in comment), remove it from CLAUDE.md
   - The rule still lives in its source file — only the CLAUDE.md copy is removed
3. Append new rule

Format:
```markdown
- **{NEVER|ALWAYS}**: {rule} <!-- {source} | {date} -->
```

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
      "target_file": "workers/public/dev-team/frontend-dev/worker.yaml",
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

## Step 8: Reindex + Rebuild Policy Digest

```bash
qmd update 2>/dev/null || true
```

**If the learning created or updated a policy file** (content_type: rule, and Step 5 created or modified a file under `companies/{co}/policies/`, `repos/*/.claude/policies/`, or `.claude/policies/`), rebuild the policy digest so SessionStart hooks pick up the change on the next session:

```bash
bash scripts/build-policy-digest.sh
```

This is load-bearing for the Phase 2.4 SessionStart policy digest loop — skipping it causes new policies to silently fail to load in future sessions. The full rebuild is idempotent and fast (~15s over all scopes). If perf matters later, extend `build-policy-digest.sh` to accept a `--scope` arg.

**Stage the regenerated digest** so it lands with the policy change in the next commit:
```bash
# Only if inside a git repo and digests changed
git update-index --refresh >/dev/null 2>&1 || true
```

Insight-only runs (content_type: insight) skip the digest rebuild — insights don't affect the policy digest.

**Batch mode note:** In batch mode (Mode 4), the digest rebuild runs ONCE after all items are processed — not per-item. The single rebuild covers all policy files written during the batch.

## Step 9: Report

**For rules (content_type: rule):**
```
Learning captured:
  Rule: {rule}
  Target: {policy file path | worker.yaml path}
  Action: {created-policy | updated-policy | merged-into-policy | worker-yaml-injection}
  Global: {promoted|not promoted}
  Dedup: {new|merged|skipped}
  Event: workspace/learnings/learn-{timestamp}.json
```

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
- **Global cap is hard** — never exceed 20 rules in CLAUDE.md `## Learned Rules`
- **Reindex after every injection** — keeps qmd search current
- **Rebuild digest after policy write** — `bash scripts/build-policy-digest.sh` is required after any policy file create/update (Step 8). SessionStart hooks depend on it
- **Event log is always written** — `workspace/learnings/learn-{timestamp}.json` is non-optional
- **Preserve existing rules** — append only, never overwrite existing rules
- **User corrections always promote** — /learn --hard delegations go to both target file AND CLAUDE.md
- **Match existing style** — use the same rule format as existing rules in the target file
