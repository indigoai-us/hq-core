---
name: knowledge-pulse
description: Lightweight background gardening pass for a company's knowledge base and policies. Spawned by startwork/brainstorm/plan after company resolution. Never run directly by users.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash(git:*), Bash(qmd:*), Bash(ls:*), Bash(date:*), Bash(scripts/build-policy-digest.sh:*), Bash(scripts/read-policy-frontmatter.sh:*)
---

# Knowledge Pulse — Background Gardening

Lightweight, idempotent gardening pass that runs as a background sub-agent spawned by `startwork`, `brainstorm`, or `plan`. Gardens both **knowledge docs** and **policies** for a single company.

**Never invoked directly.** Always spawned via `spawn_task` by a parent command.

## Input (via spawn prompt)

The parent command provides these values in the spawn prompt:

| Field | Required | Description |
|-------|----------|-------------|
| `company_slug` | Yes | Company slug from manifest |
| `knowledge_path` | Yes | Resolved path to `companies/{co}/knowledge/` |
| `policies_path` | Yes | Resolved path to `companies/{co}/policies/` |
| `caller` | Yes | `startwork`, `brainstorm`, or `plan` |
| `qmd_collection` | No | Company's qmd collection for scoped searches |
| `search_results_summary` | No | Condensed qmd hits from parent (brainstorm/plan only) |
| `discovered_facts` | No | New company facts from parent's research (brainstorm/plan only) |
| `doc_scout_gaps` | No | Post-implementation doc gaps (plan only) |

## Action Matrix

| Action | startwork | brainstorm | plan |
|--------|-----------|------------|-----|
| Knowledge INDEX.md refresh | Yes | Yes | Yes |
| Tag untagged knowledge docs | Yes | Yes | Yes |
| Flag stale knowledge (>60d) | Yes | Yes | Yes |
| company-info.md freshness | Yes | Yes | Yes |
| Contradiction detection | No | Yes | Yes |
| Policy frontmatter validation | Yes | Yes | Yes |
| Stale policy detection | Yes | Yes | Yes |
| Cross-scope conflict detection | No | Yes | Yes |
| Orphan policy detection | No | Yes | Yes |
| Rebuild policy digest | If changed | If changed | If changed |

## Process

### Step 0: Idempotency Check

Check for existing report at `workspace/reports/knowledge-pulse/{company_slug}-{YYYY-MM-DD}.md`.

- If exists from today: **skip entire pulse**. Print "Pulse already ran for {company_slug} today. Skipping." and exit.
- If not found: proceed.

### Step 1: Detect Knowledge Repo Type

Determine the knowledge directory pattern to choose the right commit strategy:

```bash
if [ -L "{knowledge_path}" ]; then
  repo_type="symlink"      # Pattern 2: symlink to repos/
elif [ -d "{knowledge_path}/.git" ]; then
  repo_type="embedded"     # Pattern 1: standalone .git inside knowledge/
else
  repo_type="inline"       # Pattern 3: tracked by HQ git
fi
```

**Commit rules:**
- `embedded`: commit changes inside the inner repo (`git -C {knowledge_path} add . && git -C {knowledge_path} commit`)
- `symlink`: resolve target, commit inside the target repo
- `inline`: **skip committing** — flag in report as "changes staged but not committed (inline HQ-tracked)"

### Step 2: Knowledge Garden

#### 2a. INDEX.md Refresh

1. Glob `{knowledge_path}/**/*.md` to get actual file list
2. Read `{knowledge_path}/INDEX.md` (if exists)
3. Compare: are there files not listed in INDEX, or INDEX entries pointing to missing files?
4. If drift detected: regenerate INDEX.md per the index-md-spec pattern (hierarchical, grouped by subdirectory)
5. Track: `index_refreshed = true/false`

#### 2b. Tag Untagged Docs

For each `.md` file in `{knowledge_path}/` (skip `INDEX.md`, `README.md`):

1. Read first 10 lines — check for YAML frontmatter (`---` delimiters)
2. If **no frontmatter**: classify per `knowledge/public/hq-core/knowledge-ontology.yaml`:
   - `type`: infer from content (strategy/reference/guide/analysis/brand/overview)
   - `domain`: infer from content and subdirectory location
   - `status`: default `draft` for untagged docs
   - `tags`: extract 3-5 topic keywords from content
   - `relates_to`: leave empty (vector search for relations is expensive; skip in pulse)
3. Prepend YAML frontmatter block to the file
4. Track: `docs_tagged` count

**Cap:** Process at most 20 untagged files per pulse run. If more exist, note remainder in report.

#### 2c. Flag Stale Content

For each `.md` file in `{knowledge_path}/` (skip `INDEX.md`):

1. Check git last-modified date: `git log -1 --format="%ai" -- {file}` (run from knowledge repo root, not HQ root)
2. If >60 days since last commit:
   - If file has frontmatter with `status:` field: update to `status: stale`
   - If no frontmatter: skip (will be tagged in next pulse after 2b adds frontmatter)
3. Track: `stale_flagged` count, collect files >90 days for report

#### 2d. company-info.md Check

1. Check if `{knowledge_path}/company-info.md` exists
2. If exists: check git age via `git log -1 --format="%ai" -- company-info.md`
3. Track: `company_info_age_days` (or `null` if missing)
4. If >90 days stale: flag in report
5. If `discovered_facts` provided by parent: note in report as "Potential updates for human review" (do NOT auto-modify company-info.md — it's high-stakes)

#### 2e. Contradiction Detection (brainstorm/plan only)

**Skip if caller is `startwork`.**

If `search_results_summary` provided:

1. For each qmd hit path in the summary, read the file
2. Compare key facts (pricing, features, architecture claims) against other knowledge docs in the same domain
3. If contradictions found: log each as `{file_a, file_b, claim_a, claim_b}` in report
4. Track: `contradictions` count

**This is read-only** — contradictions are logged, never auto-resolved.

### Step 3: Policy Garden

#### 3a. Policy Frontmatter Validation

Glob `{policies_path}/*.md` (skip `example-policy.md`, `_digest.md`).

For each policy file:

1. Read first 20 lines — extract YAML frontmatter
2. Check required fields per policies-spec: `id`, `title`, `scope`, `trigger`, `enforcement`, `version`, `created`, `updated`, `public`
3. If missing required fields: log in report as "Policy {filename} missing fields: {list}"
4. Track: `policies_invalid` count

**Do NOT auto-fix policy frontmatter** — policy content is high-stakes. Report only.

#### 3b. Stale Policy Detection

For each policy file:

1. Read the `## Rule` section
2. Check for references to specific file paths — verify those paths still exist via `ls`
3. Check for references to repo names — verify against `companies/manifest.yaml` repos list
4. Check for references to worker names — verify against `workers/registry.yaml`
5. If broken references found: log as "Policy {filename} references missing {type}: {path/name}"
6. Track: `policies_stale_refs` count

#### 3c. Cross-Scope Conflict Detection (brainstorm/plan only)

**Skip if caller is `startwork`.**

1. Read company policies from `{policies_path}/`
2. Read global policies from `.claude/policies/` (frontmatter only — use `scripts/read-policy-frontmatter.sh`)
3. For each company policy: check if a global policy with similar `trigger` exists
4. If both are `enforcement: hard` with potentially conflicting rules: log as "Potential conflict: company {title} vs global {title}"
5. Track: `policy_conflicts` count

#### 3d. Orphan Policy Detection (brainstorm/plan only)

**Skip if caller is `startwork`.**

1. For each company policy with `scope: repo` in frontmatter: verify the referenced repo exists in manifest
2. For each policy referencing a specific worker: verify the worker exists in registry
3. If orphaned: log as "Orphan policy {filename}: references {type} {name} which no longer exists"
4. Track: `policies_orphaned` count

#### 3e. Rebuild Policy Digest

If **any** policy was modified in Steps 3a-3d (currently none are modified — all report-only), OR if `{policies_path}/_digest.md` does not exist:

```bash
bash scripts/build-policy-digest.sh
```

Track: `digest_rebuilt = true/false`

### Step 4: Commit Changes

**Knowledge changes** (INDEX.md refresh, tagging, stale flags):

- If `repo_type` is `embedded`:
  ```bash
  cd {knowledge_path}
  git add -A
  git diff --cached --quiet || git commit -m "pulse: auto-tag and index refresh ({date})"
  ```
- If `repo_type` is `symlink`:
  - Resolve symlink target: `readlink {knowledge_path}`
  - Commit inside the resolved target with same message
- If `repo_type` is `inline`:
  - Skip commit. Note in report: "Knowledge is HQ-tracked (inline). Changes staged but not committed to avoid race with parent command."

**Policy changes:** Currently all policy actions are report-only (no file modifications). If future versions add policy auto-fixes, commit to HQ git separately.

### Step 5: Write Pulse Report

Write to `workspace/reports/knowledge-pulse/{company_slug}-{YYYY-MM-DD}.md`:

```markdown
# Knowledge Pulse: {company_slug}
**Date:** {YYYY-MM-DD} | **Triggered by:** {caller} | **Repo type:** {repo_type}

## Knowledge Actions
- INDEX.md: {refreshed — N files added/removed | no drift detected}
- Tagged: {N} untagged docs {(M remaining, capped at 20) if applicable}
- Stale flags: {N} files marked stale (>60d)
- company-info.md: {fresh (Nd old) | stale (Nd old) — review needed | not found}
- Committed: {yes (hash) | skipped (inline repo)}

## Policy Health
- Validated: {N} policies, {M} with missing frontmatter fields
- Stale references: {N} policies reference missing paths/repos/workers
- Cross-scope conflicts: {N} potential conflicts {(skipped — startwork caller)}
- Orphan policies: {N} reference nonexistent repos/workers {(skipped — startwork caller)}
- Digest: {rebuilt | up to date | not needed}

## Contradictions Found
{table: file_a | file_b | conflicting claims — or "None" or "Skipped (startwork caller)"}

## Stale Files (>90d)
{table: file | last commit | age — or "None"}

## Invalid Policy Frontmatter
{table: file | missing fields — or "None"}

## Stale Policy References
{table: file | references | type | status — or "None"}

## Discovered Facts (for human review)
{list from parent's discovered_facts — or "None provided"}

## Doc Scout Gaps
{list from parent's doc_scout_gaps — or "None provided" or "N/A (not prd caller)"}
```

### Step 6: Append Health Metrics

Append one JSON line to `workspace/metrics/knowledge-health.jsonl`:

```json
{"timestamp":"{ISO8601}","company":"{company_slug}","caller":"{caller}","repo_type":"{repo_type}","index_refreshed":{bool},"docs_tagged":{N},"stale_flagged":{N},"company_info_age_days":{N|null},"contradictions":{N},"policies_validated":{N},"policies_invalid":{N},"policies_stale_refs":{N},"policy_conflicts":{N},"policies_orphaned":{N},"digest_rebuilt":{bool}}
```

## Rules

- **Idempotent** — one pulse per company per day. Second invocation skips entirely
- **Non-destructive** — never delete, archive, or move files. Only: add frontmatter, update status field, regenerate INDEX.md
- **Policy changes are report-only** — never auto-modify policy content. Frontmatter validation and stale detection produce reports, not fixes
- **company-info.md is hands-off** — only report age and discovered facts. Never auto-update
- **Cap tagging at 20 files** — prevents runaway in large knowledge bases
- **Respect repo type** — only commit to embedded/symlink repos. Never commit inline knowledge to avoid racing HQ git
- **Company isolation** — only garden the specified company's knowledge and policies. Never cross-company
- **Background execution** — this skill runs detached from the parent command. No user interaction, no AskUserQuestion, no plan mode
- **Fail gracefully** — if qmd is unavailable, skip contradiction detection. If git commands fail, skip stale detection. Always produce a report even if partial
- **No INDEX.md reads during startwork** — startwork's rule "NEVER read company knowledge dirs" applies to the main command, not this background agent. The pulse agent operates independently
