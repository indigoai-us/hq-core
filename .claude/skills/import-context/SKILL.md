---
name: import-context
description: Bootstrap HQ from your prior AI footprint — Claude Code, Codex, Grok, and claude.ai conversation history plus on-disk artifacts (skills, hooks, policies, repos, plans). Proposes companies, knowledge, policies, and projects for guided import.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion, Task
---

# /import-context — Adopt Prior AI Footprint into HQ

Hydrate a fresh HQ install from the user's existing AI footprint. Two complementary sources:

1. **Artifacts on disk** — skills, hooks, policies, MCP configs, CLAUDE.md files, knowledge dirs, claude-bearing repos, and prior `/plan` outputs.
2. **Conversation history** — Claude Code sessions, Codex sessions, Grok sessions, and (via export) claude.ai chat threads. Sub-agents mine sampled threads and **propose** HQ context to bootstrap company setup: candidate companies, knowledge seeds, policies, and projects. Everything is a proposal — nothing lands without an explicit accept.

Discovers artifacts, infers work ontology from prior plans and conversations, and guides a per-category import — creating missing companies and synthesizing workers on demand.

> `/import-claude` is the former name and remains a deprecated alias that routes here.

**Ships via the hq-core release pipeline.** Core changes are made in the hq-core staging repo and reach the public `indigoai-us/hq-core` release through promotion.

## Preflight

Before any scan, verify all gates. Each is a hard stop.

### 1. Plan-Mode Guard

If the session is in Plan Mode (active instructions restrict edits to a single `~/.claude/plans/*.md` file), STOP and print verbatim:

> `/import-context` writes to `workspace/imports/`, `companies/`, and `core/workers/` — paths Plan Mode forbids. Exit plan mode (Shift+Tab) and re-run, or review the approved plan at `~/.claude/plans/` first.

Do not degrade. Do not redirect writes. Exit the skill.

### 2. HQ Root + Setup Check

- `HQ_ROOT="$(pwd)"` (or resolve from settings). Confirm `.claude/` and `companies/manifest.yaml` exist.
- If `manifest.yaml` is missing: print `/import-context requires /setup to have been run first — run /setup and retry.` and exit.

### 3. Self-Protection (Scope Sanity)

For every `--scope=<dir>` flag (and for the default allowlist), resolve with `realpath`. Abort if any resolves to a path that starts with `$HQ_ROOT` — the scanner refuses to re-import HQ into itself.

### 4. Active-Run Guard

Read `workspace/orchestrator/active-runs.json`. If the current repo is claimed by another run, refuse. `/import-context` writes to registries — it cannot share the repo.

## Flags

Parse `$ARGUMENTS`:

| Flag | Effect |
|---|---|
| `--dry-run` | Scan + ontology inference + report; no imports, no manifest writes, no worker.yaml creation |
| `--scope=<dir>` | Add a custom parent dir to scan (repeatable; additive to default allowlist) |
| `--ontology-only` | Scan + ontology inference; skip every artifact triage |
| `--cluster-min-skills=<N>` | Minimum skills in a cluster to trigger worker-synthesis prompt (default: 2) |
| `--claude-export=<path>` | Path to a claude.ai data export (unzipped dir or `conversations.json`) so claude.ai chat threads join conversation mining |
| `--no-conversations` | Skip conversation mining (Phase 3.5) entirely |
| `--conversations-only` | Scan + conversation mining + proposal triage; skip ontology and artifact triage |

## Phase 1: Scan

Announce: `Scanning for Claude artifacts… this is read-only and takes ~5s on the default allowlist.`

```bash
SCAN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
SCAN_DIR="workspace/imports/${SCAN_ID}"
mkdir -p "$SCAN_DIR"

bash .claude/skills/import-context/scan.sh \
  --hq-root="$HQ_ROOT" \
  --output="$SCAN_DIR/report.json" \
  ${CLAUDE_EXPORT:+--claude-export="$CLAUDE_EXPORT"} \
  ${SCOPE_FLAGS[@]/#/--scope=}
```

Confirm `report.json` parses as JSON (`jq -e '.categories' "$SCAN_DIR/report.json" >/dev/null`). If not, surface the scanner's stderr and abort.

**Check discovery status** (`jq -r '.discovery.ok' "$SCAN_DIR/report.json"`). The scanner records whether discovery actually completed, so a failed scan is never mistaken for an empty one. If `.discovery.ok` is `false`, do **not** treat any zero counts as authoritative — surface the failure loudly, e.g.:

```
⚠️  Discovery did not complete — the counts below may be UNDER-reported.
The scanner could not read part of the scope (see .discovery.errors in the report).
This is "could not look", not "nothing to import". Fix the access issue (or
re-run with a narrower --scope) before concluding there is nothing to migrate.
```

Print the contents of `.discovery.errors` and let the user decide whether to continue, rather than silently reporting zeros.

**Redact the report** before anything touches user-visible surfaces:

```bash
bash .claude/skills/import-context/redact.sh --json-fields "$SCAN_DIR/report.json" > "$SCAN_DIR/report.redacted.json"
mv "$SCAN_DIR/report.redacted.json" "$SCAN_DIR/report.json"
```

## Phase 2: Overview

Read `$SCAN_DIR/report.json`. Print a counts-per-category summary:

```
Scan complete. Found:
  plans               {N}
  mcp_servers         {N}
  settings_fragments  {N}
  commands            {N}
  skills              {N}
  hooks               {N}
  policies            {N}
  claude_md           {N}
  knowledge_dirs      {N}
  claude_repos        {N}
  agents              {N}
  conversations       {N stores: claude-code {a} sessions · codex {b} · grok {c} · claude.ai {d or "no export"}}

Report: workspace/imports/{scan_id}/report.json
```

If all counts are zero **and `.discovery.ok` is `true`**: `No Claude artifacts found in scanned scope. Exiting.` Stop. (If `.discovery.ok` is `false`, do not print this — discovery failed; surface the errors per the discovery-status check above instead of claiming nothing was found.)

If `--dry-run`: print `Dry-run complete. No imports performed.` and exit.

**AskUserQuestion** — one call, one item:

- `question`: "How would you like to proceed?"
- `header`: "Import flow"
- `multiSelect`: false
- `options`:
  - `Ontology first` — "Infer companies from prior plans, then mine conversations, then triage artifacts"
  - `Artifacts first` — "Skip ontology and conversation mining, go straight to per-category triage"
  - `Review report` — "Open report.json in your editor first, then decide"
  - `Exit` — "Write the report and stop"

On `Review report`: `open -e "$SCAN_DIR/report.json"` and re-ask after user continues.
On `Exit`: print report path and stop.

## Phase 3: Ontology Inference

Skip if `--conversations-only`, or if user chose `Artifacts first` and `--ontology-only` is NOT set.

**Build the corpus:**

```bash
PLANS_COUNT=$(jq '.categories.plans | length' "$SCAN_DIR/report.json")
```

If `PLANS_COUNT == 0`: print `No plan files found — skipping ontology inference.` and continue to Phase 4.

Otherwise, spawn a Task sub-agent:

- **Prompt:** contents of `.claude/skills/import-context/ontology.md` (verbatim) followed by the appended inputs:
  1. Plan index — all plan filenames + first-line headings from the report
  2. Plan corpus — for ≤50 most-recent plans, read the first 200 lines each, pipe through `redact.sh`, and embed
  3. Existing HQ companies — the top-level slug list from `companies/manifest.yaml`
  4. Scan context — the counts block from Phase 2

**Cap the corpus at 50 plans.** For older plans include filename only (as the ontology template instructs).

**Write the sub-agent response verbatim** to `$SCAN_DIR/ontology.md`.

**Parse `## Inferred Companies` table.** For each row:

1. Skip if `slug` already exists in `companies/manifest.yaml`.
2. **AskUserQuestion** (one per row):
   - `question`: "Create HQ company `{slug}`? ({signal_strength} signal — {rationale})"
   - `header`: "Ontology"
   - `options`:
     - `Create {slug}` — "Runs /newcompany {slug} and seeds core/knowledge/context.md"
     - `Adjust slug` — "Rename before creating" *(follow-up free-text prompt)*
     - `Defer` — "Skip for now; revisit later"
     - `Reject` — "Don't create; ontology call was wrong"

3. On `Create`: inline-invoke `/newcompany {slug}` via Skill tool. On return, write the row's `suggested knowledge seed` to `companies/{slug}/knowledge/context.md` (seed a fresh file; prepend frontmatter per knowledge-ontology spec).

> **Routing safety.** `/newcompany` is the enforcer that scaffolds all company content under `companies/{slug}/` — `import-context` delegates company/worker creation to it rather than writing those paths itself. Do not hand-place imported policies, workers, or knowledge into `core/`; company-scoped artifacts belong under the created `companies/{slug}/` tree (see `core/policies/hq-customizations-live-in-personal-or-company.md` and `hq-company-scoped-writes-verify-company.md`).

If user chose `--ontology-only`: after this phase, print summary and exit with report + ontology locations.

## Phase 3.5: Conversation Mining

Skip if `--no-conversations`, if the user chose `Artifacts first`, or if `categories.conversations` is empty. This phase mines the user's prior AI conversations — across every runtime, not just Claude Code — and turns them into **proposals** for HQ context. It exists to bootstrap company setup: a user with months of Claude/Codex/Grok history should not start HQ from a blank slate.

### Sources

The scanner reports conversation stores as store-level entries (session counts + paths — transcripts are never bulk-loaded into the parent session):

| source | location | contents |
|---|---|---|
| `claude-code` | `~/.claude/projects/{project}/*.jsonl` | Claude Code session transcripts, grouped by working directory |
| `codex` | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | Codex CLI session rollouts |
| `grok` | `~/.grok/sessions/{encoded-cwd}/{session-id}/updates.jsonl` | Grok CLI session transcripts, grouped by working directory |
| `claude-ai` | `--claude-export=<path>` (`conversations.json` from a claude.ai data export) | claude.ai chat threads — web, desktop, and mobile |

claude.ai chats have no on-disk store. If `--claude-export` was not supplied, tell the user once how to get one (claude.ai → Settings → Privacy → Export data; the email link contains `conversations.json`) and offer to continue without it. Never scrape a browser session or claude.ai cookies to obtain chat history.

### Gate (AskUserQuestion, one call)

- `question`: "Mine your conversation history for proposed HQ context? Found: {a} Claude Code sessions, {b} Codex, {c} Grok{, claude.ai export with {d} chats}. Threads are read locally, sampled, and redacted — you approve every proposal before anything is created."
- `header`: "Conversations"
- `options`:
  - `Mine all sources` — "Sample recent threads from every store"
  - `Pick sources` — "Choose which stores to mine" *(follow-up AskUserQuestion, `multiSelect: true`, one option per store)*
  - `Skip` — "No conversation mining"

### Mining (one Task sub-agent per source; parent stays text-only)

For each accepted source, spawn a Task sub-agent whose prompt is the contents of `.claude/skills/import-context/conversations.md` (verbatim) followed by:

1. **Session index** — paths + mtimes for that store, most-recent first (from the scan report).
2. **Sampling budget** — mine at most the 40 most-recent sessions; per session read only enough to understand what the work was about (first user message, closing assistant summary, plan/decision-shaped chunks); hard cap ~200 lines per session; pipe every excerpt through `.claude/skills/import-context/redact.sh` before it enters the sub-agent's notes.
3. **Existing HQ state** — company slugs from `companies/manifest.yaml`, plus existing knowledge/policy/project titles for those companies (filenames only), so proposals extend rather than duplicate.

Write each sub-agent's response verbatim to `$SCAN_DIR/conversations-{source}.md`. Sub-agents return proposals only — never raw transcript bulk.

### Proposal triage

Merge the `## Proposals` tables from every source report; dedupe on `(type, company, title)`. Present via AskUserQuestion in batches of ≤4, one call per batch:

- `question`: "`{type}` → `{company}`: {title} — {one-line evidence}"
- `header`: "Proposal"
- `options`:
  - `Accept` — "Create it now"
  - `Edit first` — "Adjust title/company/content before creating" *(follow-up free-text)*
  - `Defer` — "Keep in the report for later"
  - `Reject` — "Wrong call — drop it"

On `Accept`, route by type — never hand-place company content outside its tenant:

| type | action |
|---|---|
| `company` | inline-invoke `/newcompany {slug}`, then seed `companies/{slug}/knowledge/context.md` from the proposal's knowledge seed |
| `knowledge` | write the proposal's draft to `companies/{co}/knowledge/{slug}.md` (frontmatter per knowledge spec) |
| `policy` | validate frontmatter against `core/knowledge/public/hq-core/policies-spec.md`; write to `companies/{co}/policies/{slug}.md` — company scope only, never `core/policies/` |
| `project` | create `companies/{co}/projects/{name}/README.md` seeded with the proposal summary and open threads; recommend `/plan` to grow it into a PRD — never fabricate a `prd.json` from thread inference |
| `worker` | feed into Phase 6 cluster detection as a proposed cluster |

Record every decision in `$SCAN_DIR/conversation-proposals.json` and add accepted proposals to `workspace/imports/index.json` keyed by sha256 of `(source, type, company, title)` — re-runs skip already-triaged proposals silently.

### Privacy rules (hard)

- Transcripts never leave the machine and are never bulk-embedded in the parent session — sub-agents sample locally and return proposals only.
- Every excerpt shown to the user or persisted under `$SCAN_DIR` passes through `redact.sh` first.
- Tenant hygiene: each proposal targets exactly one company. If a thread spans companies, split it into per-company proposals; if the company is unclear, mark it `unknown` and let the triage prompt resolve it. Never merge two companies' facts into one knowledge file.
- `--dry-run` exits at Phase 2 as usual — no mining runs.

## Phase 4: Per-Category Triage

Skip if `--conversations-only` (jump to Phase 7 after conversation mining).

Order (empties skipped): `mcp_servers → settings_fragments → commands → skills → hooks → policies → agents → claude_md → knowledge_dirs → claude_repos`.

Plans are intentionally excluded — they stay at `~/.claude/plans/`.

For each non-empty category:

**AskUserQuestion** — category-level gate:

- `question`: "{N} {category} found. How to proceed?"
- `header`: category name
- `options`:
  - `Review each` — "Decide per item"
  - `Import all safe` — "Auto-import items with no conflicts + no redactions"
  - `Skip category` — "Leave these untouched"

### Review each

Batch items in groups of 5. For each batch, one `AskUserQuestion` with 5 items (one per artifact), `multiSelect: false`:

- `question`: "`{source_path}` — {suggested_destination}"
- `header`: artifact name (basename)
- `options`:
  - `Keep` — "Import to suggested destination"
  - `Merge` — "Merge with existing file at destination (will show diff)" *(only if `conflict.exists && !hash_match`)*
  - `Rename` — "Keep both (adds `.imported-{scan_id}` suffix)" *(only if conflict)*
  - `Skip` — "Don't import this item"
  - `Assign to company` — "Scope to a company not yet guessed"

**On `Assign to company`:** follow-up with company picker (options = current manifest slugs + `New company…`). On `New company…` with a provided slug: inline-invoke `/newcompany {slug}` before continuing.

**On `Merge`:** show unified diff via `diff -u source dest` and ask `overwrite / keep-both / skip`.

**Redaction confirm** — if the item has non-empty `redacted_fields`, before importing ask:

- `question`: "`{filename}` contains {N} credential pattern(s). Import redacted?"
- `options`:
  - `Import redacted` — "Replace with `<REDACTED:*>` tokens"
  - `Skip file` — "Don't import at all"
  - `Include raw` — "Copy verbatim with credentials (only if you know what you're doing)"

### Import all safe

Auto-import items where `conflict.exists == false` AND `redacted_fields == []`. Everything else falls through to the Review loop.

### Import step (per item)

After every per-item decision resolves to `Keep`/`Merge`/`Rename`:

1. Run redactor on source: `bash .claude/skills/import-context/redact.sh "$source" > "$tmp"`
2. Copy `$tmp` → resolved destination (respecting `Rename` suffix)
3. Update `workspace/imports/index.json` with `{sha256: {destination, scan_id, timestamp}}` — idempotency store

## Phase 5: Registration (per-category, after its batch completes)

Update registries immediately after each category finishes — limits blast radius if a later phase fails.

| Category | Registration step |
|---|---|
| mcp_servers | Merge into `.claude/settings.json#mcpServers` via structured jq write |
| settings_fragments | Field-level merge into `.claude/settings.json` (never replace file) |
| commands | File-presence only |
| skills | Copy to `.claude/skills/{name}/`; if `worker.yaml` sibling exists → route to worker synthesis (Phase 6) |
| hooks | Copy to `.claude/hooks/`; add matcher to `settings.json#hooks[]`; verify `hook-gate.sh --list` shows it |
| policies | Validate frontmatter against `core/knowledge/public/hq-core/policies-spec.md`; place at `core/policies/` or `companies/{co}/policies/` |
| agents | Copy to `.claude/agents/` |
| claude_md | Merge into nearest-root CLAUDE.md (show diff, confirm before write) |
| knowledge_dirs | Materialize content in a real canonical knowledge directory; optionally initialize git in place; register it in the relevant company knowledge tree |
| claude_repos | Per-repo prompt: `Symlink / Move / Skip`; update `manifest.yaml` company `repos:` array on adoption |

**No null fields** — every `manifest.yaml` company entry and every `worker.yaml` must include all required fields from the schema. If a field is unknown, ask before writing. (`core/workers/registry.yaml` is auto-generated — no direct writes.)

## Phase 6: Worker Synthesis

Runs after `skills` + `knowledge_dirs` triage completes. Reads imported items from `index.json`.

### Cluster detection

A cluster is any group of imported artifacts where:

- ≥`--cluster-min-skills` skills share a domain keyword (filename stem, SKILL.md `description` first word, or parent dir basename), OR
- ≥1 skill + ≥1 knowledge dir imported from the same source repo/parent, OR
- ≥1 `agents/*.md` file with both tool list + instructions (worker-shaped)

### Per-cluster prompt

For each detected cluster, **AskUserQuestion**:

- `question`: "Cluster `{keyword}`: {N} skills + {M} knowledge dirs. Synthesize as a worker?"
- `header`: "Worker synthesis"
- `options`:
  - `Create worker` — "Inline /newworker with skills + knowledge pre-filled"
  - `Keep loose` — "Leave as individual skills/knowledge"
  - `Split cluster` — "I'll pick which items belong to the worker"
  - `Skip` — "Ignore this cluster"

### On `Create worker`

Registration order is strict — violate this and the worker's knowledge pointers won't resolve:

1. Verify knowledge dirs from Phase 5 are real directories (`test -d` and `! test -L`) and `companies/{co}/knowledge/` is populated
2. Inline-invoke `/newworker` with pre-filled fields:
   - `name`: inferred from dominant keyword
   - `scope`: company-scoped if cluster maps to a known slug, else `core/workers/public/`
   - `skills`: paths of imported skill dirs
   - `knowledge`: paths of imported knowledge dirs (must already be registered)
   - `description`: synthesized from SKILL.md frontmatter (user edits in the /newworker flow)
3. `/newworker` writes `worker.yaml`; `core/workers/registry.yaml` regenerates automatically via reindex.
4. Record the cluster in `$SCAN_DIR/synthesized-workers.json`.

### Shared vs company default

If the cluster has no clear company anchor and the user picks `Create worker` without specifying scope: default to **loose skills** (do not auto-promote to `core/workers/public/`). Synthesis into shared scope requires explicit accept. This is the conservative default per the approved plan's unresolved-question #5.

## Phase 7: Reindex & Summary

After all phases finish:

```bash
qmd update 2>/dev/null || true
```

Write `$SCAN_DIR/summary.md`:

```markdown
# Import Summary — {scan_id}

## Companies
- Created: {slugs or "none"}
- Seeded from ontology: {slugs or "none"}

## Conversation Mining
| source | sessions sampled | proposals | accepted | deferred |
|---|---|---|---|---|
| ... | | | | |

## Imports (by category)
| category | imported | skipped | conflicts |
|---|---|---|---|
| ... | | | |

## Workers Synthesized
{table: name | scope | skills | knowledge}

## Repos Adopted
{table: source | destination | mode (symlink/move)}

## Credentials Redacted
{count per pattern name}

## Next Steps
- Run `/cleanup --audit` to validate no broken state
- Review `workspace/imports/{scan_id}/ontology.md` for deferred ontology rows
- Review `workspace/imports/{scan_id}/report.json` for skipped items
```

Print the summary path + `git status` diff preview (not commit — user commits).

**AskUserQuestion** — post-run:

- `options`:
  - `Run /cleanup --audit` — "Validate nothing landed broken"
  - `Run /learn` — "Capture insights from this import"
  - `Commit now` — "Stage + commit the new state"
  - `End` — "Done for now"

## Rules

- **Plan Mode refuse** — Preflight halts before any scan. No silent degrade.
- **Self-exclusion** — scanner never reads inside `$HQ_ROOT`. Verified via `realpath` in scan.sh.
- **Read-only scan** — scan.sh never writes outside `$SCAN_DIR`. Confirmed by scan.sh's lack of any write paths other than `--output`.
- **Redact before display** — every preview/prompt/report.json the user sees has been through `redact.sh`. Raw source file content is never shown verbatim without explicit `Include raw` choice.
- **Idempotent** — re-runs check `workspace/imports/index.json` by sha256 and skip already-imported items silently. Different destination for same source → surface as `duplicate source`.
- **Conflict decision required** — `conflict.exists && !hash_match` cannot be auto-resolved. User picks.
- **AskUserQuestion only** — every user-facing choice goes through AskUserQuestion. Never markdown numbered lists.
- **Inline scaffolding** — unknown company slugs invoke `/newcompany` inline; worker clusters invoke `/newworker` inline. No deferred "you should run X later" hand-waves.
- **Registry completeness** — every write to `manifest.yaml` and every new `worker.yaml` fills all required schema fields. No nulls. If a field is unknown, ask. `core/workers/registry.yaml` is a generated artifact — never written directly.
- **Generic-user safety** — report.json and summary.md substitute literal `$HOME` for `$HOME/` prefixes. Scanner's `sub_home()` enforces this.
- **Plans are never imported** — they stay at `~/.claude/plans/`. Only feed ontology inference.
- **Conversations are never imported** — session stores stay where they are (`~/.claude/projects/`, `~/.codex/sessions/`, `~/.grok/`, the export file). Mining reads samples and produces proposals; only accepted proposals materialize as HQ files.
- **Proposals, not conclusions** — conversation mining output is always a proposal gated by AskUserQuestion. Low-signal inferences are marked as such; the user is the authority on what their history means.
- **Per-repo prompt** — every claude-bearing repo gets its own prompt. No batch-adopt.
- **Registration-order discipline (worker synthesis)** — knowledge before worker.yaml. Always.
- **No execution** — this command mutates HQ structure only. It does not run imported skills, execute worker tasks, or invoke any other work.
- **Checkpoint after write** — if any Phase 5 registration succeeds, the Auto-Checkpoint PostToolUse hook fires. Do not race it.

## Files this skill touches

**Reads:** `companies/manifest.yaml`, `core/workers/registry.yaml`, `workspace/imports/index.json`, user's disk (per scope), conversation stores read-only (`~/.claude/projects/`, `~/.codex/sessions/`, `~/.grok/`, `--claude-export` path).

**Writes:** `workspace/imports/{scan_id}/` (report, ontology, conversations-{source}, conversation-proposals, summary, synthesized-workers), `workspace/imports/index.json`, `.claude/{commands,skills,hooks,policies,agents}/`, `.claude/settings.json`, `companies/{co}/{knowledge,policies,projects,repos,workers}/`, `companies/manifest.yaml`, `core/workers/public/{id}/worker.yaml` (registry auto-regenerates), `CLAUDE.md` (on user confirm).

**Never touches:** `~/.claude/plans/` (read-only for ontology), conversation stores (read-only for mining), `~/.ssh/`, `~/.aws/`, `~/.gnupg/`, `.env`, any shell rc file (per HQ deny lists).

## See also

- Scanner: `.claude/skills/import-context/scan.sh`
- Redactor: `.claude/skills/import-context/redact.sh`
- Ontology prompt: `.claude/skills/import-context/ontology.md`
- Conversation-mining prompt: `.claude/skills/import-context/conversations.md`
- Deprecated alias: `.claude/skills/import-claude/` (stub routing here)
- Plan file (archive): `~/.claude/plans/<plan-name>.md`
