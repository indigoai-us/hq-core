---
description: Shared post-PRD finalize steps (5.5 through 8.5) used by /prd and /deep-plan.
---

# PRD Finalize — Shared Post-Generation Steps

Run these steps in order after the calling skill writes prd.json and README.md (its Step 5), then return to the caller's Step 9. `{co}` and `{name}` are the company slug and project slug resolved by the caller. Where a step differs by caller, the difference is stated inline.

## Step 5.5: Update Brainstorm (if exists)

If a `brainstorm.md` was detected in Step 3.5, update its YAML frontmatter:
- Set `status: "promoted"`
- Set `promoted_to: "companies/{co}/projects/{name}/prd.json"`

This marks the brainstorm as consumed. The file is preserved for reference.

## Step 5.6: Sync to Company Board

Read `companies/manifest.yaml` to find `metadata.company` → `board_path`.

If `board_path` exists, read `companies/{co}/board.json` and upsert a project entry:
- **Match**: find existing entry by `prd_path === "companies/{co}/projects/{name}/prd.json"` or title similarity
- **If found**: update `status` to `prd_created`, set `prd_path`, update `updated_at`
- **If not found**: append new entry:
  ```json
  {
    "id": "{co-prefix}-proj-{N+1}",
    "title": "{project name}",
    "description": "{1-sentence description}",
    "status": "prd_created",
    "scope": "company",
    "app": null,
    "initiative_id": null,
    "prd_path": "companies/{co}/projects/{name}/prd.json",
    "created_at": "{ISO8601}",
    "updated_at": "{ISO8601}"
  }
  ```
- Write updated `board.json` back to `board_path`
- If no `metadata.company` in prd.json or no board_path, skip silently

**Verify:** After upserting the board entry, re-read board.json and confirm the new project ID exists. If the write failed silently (file parse error, missing board, manifest lookup miss), log the error and retry once. Silent failure leaves projects invisible in the HQ app — the orphan scanner catches them with an "Unregistered" badge, but proper registration is required.

## Step 5.7: Register the canonical project in Work Mesh (/prd only)

/deep-plan skips this step.

Local `board.json` does not establish the server project. Registration is one script call. Do not GET, PUT, or POST the Work Mesh project by hand.

After Step 5.6, read the Board entry matched by
`prd_path === "companies/{co}/projects/{name}/prd.json"` and use its `id` as
`{board-project-id}` for this offer check:

```bash
bash core/scripts/work-mesh-project-registration-offer.sh --check {co} {board-project-id}
```

When the helper prints `offer`, ask once with `AskUserQuestion` and exactly
these choices: `Create the Work Mesh project now` and `Not now`. The prompt is
available only when the company is cloud-backed, registration is missing, and
the default-off `workmesh.offer-project-create-on-brainstorm` hq-flags key is
on. On acceptance, record it before running the registration command below:

```bash
bash core/scripts/work-mesh-project-registration-offer.sh --accept {co} {board-project-id}
```

On `Not now`, record the deferral with `--defer` and skip registration for
this invocation. A persisted `deferred` result skips registration for this
invocation. When the helper reports `deferred`, stop here and do not run
`register-project.sh`. It suppresses both the prompt and registration. An
`accepted` result retries registration without another prompt. Do not prompt again for an
accepted or deferred Board entry. For `off`, `local`, `registered`, or
`missing`, do not show a prompt and preserve the existing registration flow
below (including its existing failure handling).

```bash
bash core/scripts/register-project.sh {co} {name}
```

The script runs `hq mesh project ensure`, writes `threadId` and `channelId` onto the company `board.json` entry, re-reads that entry, and prints one line: `registered {co}/{name} thread=<threadId> channel=<channelId>`. That line is the verify line. If the script exits non-zero, or stdout is not that line, registration is incomplete. Say "registration incomplete" in the Step 9 report and do not continue as if the project is on the Board. Do not create a replacement project.

## Step 6: Register with Orchestrator

Read `workspace/orchestrator/state.json`. Append to `projects` array:

```json
{
  "name": "{name}",
  "state": "READY",
  "prdPath": "companies/{co}/projects/{name}/prd.json",
  "updatedAt": "{ISO8601}",
  "storiesComplete": 0,
  "storiesTotal": "{N}",
  "checkedOutFiles": []
}
```

If project already exists in state.json, update it instead of duplicating.

## Step 7: Optional Beads Setup

If the optional `bd` CLI is on PATH (`command -v bd`), you may run `bd init --project {name}`; otherwise skip this step.

Silent — just log success/failure.

## Step 7.5: Capture Learning (Auto-Learn)

Run the `learn` skill (or `/learn` in Claude Code) to register the new project in the learning system:

```json
{
  "source": "build-activity",
  "severity": "medium",
  "scope": "global",
  "rule": "Project {name} exists at companies/{co}/projects/{name}/ with {N} stories targeting {repoPath or 'no repo'}",
  "context": "Created via prd skill"
}
```

Also reindex: `qmd update 2>/dev/null || true`

**Update INDEX.md:** Regenerate `companies/{co}/projects/INDEX.md` per `core/knowledge/public/hq-core/index-md-spec.md`.

## Step 7.6: Doc Scout (read-only)

Check if the new project's scope reveals missing or stale docs. Scout only — no modifications (project hasn't been built yet).

1. **Repo README** (`{repoPath}/README.md` if `repoPath` set):
   - Does it exist? Is it boilerplate (`create-next-app`, default template)?
   - If repo is new or README is stale, note for post-implementation

2. **HQ knowledge** (`companies/{co}/knowledge/`):
   - `qmd search "{project topic}" -c {co} --json -n 3` — is this topic already covered?
   - If no coverage and project is non-trivial, note the gap

3. **External docs**: If company has a knowledge site (check INDEX.md references), note potential publishing need

**Do NOT create or modify docs** — project hasn't been implemented. Instead:
- Add a `postImplementation` array to prd.json `metadata` listing doc tasks:
  ```json
  "postImplementation": [
    "Update repo README with API docs",
    "Create {topic} architecture doc in companies/{co}/knowledge/"
  ]
  ```
- Include these notes in the Step 8 confirmation output so user sees them

## Step 7.7: Spawn Knowledge Pulse (Background)

If `{co}` is resolved and company has a knowledge directory (not `null` in manifest):

Use the background `Task` tool without worktree isolation so the child stays in this canonical HQ checkout.

```
Task({
  subagent_type: "general-purpose",
  description: "Pulse-garden {co} knowledge",
  run_in_background: true,
  prompt: "Run the knowledge-pulse skill at .claude/skills/knowledge-pulse/SKILL.md.
    company_slug: {co}
    knowledge_path: companies/{co}/knowledge/
    policies_path: companies/{co}/policies/
    caller: prd
    qmd_collection: {qmd_collections[0] from manifest, or omit if none}
    search_results_summary: {condensed list of qmd hits from Step 2, max 10 items — path + title per hit}
    discovered_facts: {new facts from interview answers — especially Batch 4a data model, 5a integrations, any architecture or capability info learned about the company}
    # when called from /deep-plan, use this line instead:
    discovered_facts: {new facts from interview answers — especially ARCHITECTURE-1 data model, operational integrations, any architecture or capability info learned about the company}
    doc_scout_gaps: {postImplementation items from Step 7.6, or 'none'}
    Read the skill file for full instructions."
})
```

Do NOT wait for the pulse to complete — continue immediately to Step 8.

**Skip if:** company has no knowledge directory.

## Step 8: Linear Sync (best-effort, when configured)

If `{co}` is `{product}`, attempt Linear sync. If credentials are unavailable or API fails, skip silently — Linear sync never blocks PRD creation.

1. Read `companies/{product}/settings/linear/credentials.json` and `config.json`
2. Validate `workspace: "{your-tenant}"` in config
3. Create Linear project linked to best-fit initiative, with `leadId` (default: owner from `agents-profile.md`) and `targetDate` (default: today+1d)
4. Create issue per story with `assigneeId` (resolved by team routing) and `dueDate` (matches project targetDate)
5. Store all IDs in prd.json: `metadata.linearProjectId`, `metadata.linearCredentials`, per-story `linearIssueId`, `linearAssigneeId`

No orphan issues — every issue must have a `projectId`. If project creation fails, skip issue creation.

## Step 8.5: Resolve Open Questions (Decision Mode)

**HARD BLOCK: PRD is NOT complete until this step finishes.**

Read `metadata.openQuestions[]` from the prd.json just written. **If empty**, skip this step entirely and proceed to Step 9.

**If non-empty:**

1. **Enter plan mode for the resolution.** Announce to the user: `"Open questions remain — entering decision mode."` Use **AskUserQuestion** (NOT free-text questions) so answers are structured and auditable. ToolSearch `select:AskUserQuestion` if it isn't loaded yet.
2. **Batch up to 4 questions per AskUserQuestion call.** For each question, infer **2–3 concrete candidate options** from:
   - The PRD's own metadata (`integrations`, `architectureNotes`, `authModel`, `dataModel`, `rolloutStrategy`, etc.)
   - Prior `metadata.decisions[]` already captured (if re-running)
   - Anchored company policies (e.g. `{company}-aws-credentials-safety` → "{company} aws_profile (<account-id>, <region>)")
   - Common-sense defaults ("existing cert" when signing, "existing pool" when auth)
3. **Always append a `"Defer — track as pre-flight story"` option LAST** to every question. Users must be able to opt out of answering any single question without abandoning decision mode entirely.
4. **Write results back to prd.json:**
   - **Answered:** append to `metadata.decisions[]` as `{question, answer, decidedAt: <today ISO date>, decidedBy: <owner name from agents-profile.md>}`. Remove from `metadata.openQuestions[]`.
   - **Deferred:** keep in `metadata.openQuestions[]` but annotate `{deferredAt, deferredReason}`. Generate a new user story `US-000` (or `US-00N` if taken) with:
     - `priority: 1`
     - `labels: ["investigation", "pre-flight"]`
     - `acceptanceCriteria`: `"Investigate <question>, write findings to companies/{co}/projects/{name}/references.md, unblock <dependent story ids>"`
     - `dependsOn`: minimal prerequisites (usually just US-001 or US-002)
     - `notes`: `"Blocks <dependent stories>. Created via /prd Step 8.5 decision-mode deferral."`
       When called from /deep-plan, the `notes` string is `"Blocks <dependent stories>. Created via /prd Step 8.5 decision-mode deferral."`
   - **Insert the new story at the top of `userStories[]`** and **prepend its id to the `dependsOn[]` of every dependent story** (inferred from the question text — e.g. "Affects US-009 scope" → add to US-009's deps).
5. **Re-derive README.md** from the updated prd.json so the human-readable view reflects the Decisions section + new investigation stories + updated dependencies.
6. **Re-sync orchestrator state** — update `workspace/orchestrator/state.json` for this project: `storiesTotal += <number of new investigation stories>`, bump `updatedAt`.
7. **Re-sync board.json** — bump `companies/{co}/board.json` entry's `updated_at` timestamp (no field changes needed; investigation stories ride under the same project).
8. **Append decision-mode results to journal:**

```bash
.claude/skills/_shared/journal.sh append "{project_dir}" decisions "Open question resolution: resolved {N} → metadata.decisions[]; deferred {M} → investigation stories; key decisions — {2-3 bullet summary}"
```

9. Only after Step 8.5 completes may Step 9 run.

**Rationale:** Open questions historically drifted into `metadata.openQuestions[]` and were forgotten. Forcing resolution at PRD creation (in plan mode, via AskUserQuestion) catches cost/timeline implications while context is rich, not in the executing agent's downstream session where context is thinner. The "Defer — track as pre-flight story" escape hatch preserves the option to punt without losing traceability.
