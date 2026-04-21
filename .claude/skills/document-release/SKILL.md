---
name: document-release
description: Post-ship documentation sync — updates README, CLAUDE.md, architecture docs, and INDEX files to match what actually shipped. Use after merging a PR, completing a project, or deploying a release. Triggers on "update docs", "sync documentation", "docs are stale", "document what shipped".
allowed-tools: Read, Edit, Write, Grep, Glob, Bash(git:*), Bash(qmd:*), AskUserQuestion
---

# Post-Ship Documentation Sync

You are a technical writer performing a post-ship documentation audit. Your job: make every doc reflect what actually shipped — no more, no less.

**Critical rules:**
- **NEVER clobber CHANGELOG entries** — polish wording only, never regenerate or rewrite history
- **NEVER bump VERSION without asking**
- **Use Edit tool with exact matches** — never use Write to overwrite CHANGELOG or README
- **AUTO-UPDATE machine-consumed docs** (CLAUDE.md, architecture, INDEX.md) — factual accuracy matters more than voice
- **ASK before updating user-facing docs** (README.md) — voice and framing matter

## Headless Mode

If `$CLAUDE_HEADLESS=1` (set by `scripts/handoff-post.sh`), this skill runs non-interactively:

- **DO NOT call `AskUserQuestion`** — there is no user to answer
- **AUTO changes apply normally** — CLAUDE.md, architecture docs, INDEX.md, prd.json/board.json status flips
- **ASK changes are logged, not applied** — for each proposed README/setup-guide edit, print a block to stdout:
  ```
  PROPOSED ({file}): {one-line summary}
  ---
  {unified diff or before/after snippet}
  ---
  ```
  stdout is captured to `/tmp/handoff-docrelease.log`; the user reviews next session.
- **No prompts, no blocking** — if a decision would require user input, default to "skip + log" and continue
- **Scope gate still applies** — only run when `files_touched` includes `companies/` or `repos/` paths (enforced by caller)
- **Exit cleanly** — emit the final report to stdout so the log captures the summary

Shell check at the top of the run:
```bash
if [[ "${CLAUDE_HEADLESS:-0}" = "1" ]]; then
  echo "[document-release] headless mode — AskUserQuestion disabled, ASK changes will be logged"
fi
```

## Step 0: Company + Project Resolution

Same company anchor pattern as all HQ commands:
1. Check first word against `companies/manifest.yaml`
2. If matched: set `{co}`, load policies
3. Resolve project: find `companies/{co}/projects/{slug}/prd.json` or infer from recent git activity

If no project slug provided:
- Check recent git log for project-related commits
- Check `workspace/orchestrator/` for recently completed projects
- AskUserQuestion if still ambiguous

Announce: `Documenting release for: {project title} ({co})`

## Step 1: Diff Analysis

Determine what changed since the project started:

```bash
# If project has a known start commit or date
git log --oneline --since="{prd.createdAt}" -- {repo paths}
git diff {start_ref}..HEAD --stat -- {repo paths}

# If no clear start ref, use the PRD creation date
git log --oneline --since="{prd.metadata.createdAt}" -- {repo paths}
```

Identify and categorize:
- **New files** — may need doc mentions (new components, APIs, tools)
- **Removed files** — doc references to remove
- **Renamed/moved files** — doc references to update
- **Changed APIs** — function signatures, endpoints, env vars
- **New dependencies** — package.json/requirements changes
- **New env vars** — .env.example or setup doc updates needed
- **Config changes** — deployment, CI, infrastructure

Present summary:
```
Diff analysis:
- Files added: {N}
- Files removed: {N}
- APIs changed: {list}
- New env vars: {list}
- New dependencies: {list}
```

## Step 2: Doc Audit

Scan for all documentation files in scope. For each, classify the update strategy:

| File | Strategy | Rationale |
|---|---|---|
| `README.md` | **ASK** | User-facing, voice matters. Present proposed changes for approval |
| `CLAUDE.md` | **AUTO** | Machine-consumed, factual accuracy is critical |
| `.claude/CLAUDE.md` (repo-level) | **AUTO** | Machine-consumed |
| Architecture docs (`docs/*.md`, `ARCHITECTURE.md`) | **AUTO** | Must match code reality |
| `INDEX.md` files | **AUTO** | Structural, regenerable |
| `CHANGELOG.md` | **POLISH ONLY** | Never rewrite. Only fix typos, formatting, or broken links in existing entries |
| `prd.json` status | **AUTO** | Set to `"completed"` if all stories done |
| `board.json` status | **AUTO** | Set to `"completed"` |
| API docs (`openapi.yaml`, route comments) | **AUTO** | Must match implementation |
| Setup/install guides | **ASK** | User-facing, may affect onboarding |

**For each doc file found:**
1. Read current content
2. Cross-reference against the diff (Step 1)
3. Identify stale references (files/functions/APIs that no longer exist)
4. Identify missing references (new files/functions/APIs not yet documented)
5. Classify each needed change as AUTO or ASK

## Step 3: Apply Updates

### AUTO updates (apply directly)

Use Edit tool with exact string matches. Make minimal, targeted edits:

- Update file paths that changed
- Update function/class names that were renamed
- Update API endpoint documentation to match implementation
- Remove references to deleted code
- Add references to new significant code (new modules, services, APIs)
- Update CLAUDE.md sections that reference project structure
- Regenerate affected INDEX.md files
- Set prd.json `status` → `"completed"` (if all stories done)
- Set board.json `status` → `"completed"`

### ASK updates (present for approval)

**Interactive mode (default):** For each user-facing doc change, present via AskUserQuestion:

```
README.md update needed:

Current: {relevant section}
Proposed: {updated section}

A) Apply this change
B) Skip — I'll update manually
C) Modify — let me adjust the wording
```

**Headless mode (`$CLAUDE_HEADLESS=1`):** Do NOT call AskUserQuestion. Log the proposal to stdout and continue:

```
PROPOSED (README.md): {one-line summary}
---
--- before
{current snippet}
+++ after
{proposed snippet}
---
```

Counts as "logged, not applied" in the final report. User addresses these next session.

### CHANGELOG rules

- **NEVER regenerate** CHANGELOG entries
- **NEVER reorder** entries
- Only fix: typos, broken links, formatting inconsistencies
- If the project should have a CHANGELOG entry and doesn't: ASK the user, don't auto-generate

## Step 4: Cross-Doc Consistency Check

After all updates are applied, verify consistency:

1. **Internal links** — grep for `[...](path)` markdown links, verify targets exist
2. **Code references** — grep for backtick-quoted function/file names, verify they still exist in the codebase
3. **Env var references** — verify all documented env vars exist in `.env.example` or equivalent
4. **Import paths** — verify documented import examples match actual file locations
5. **Stale examples** — flag code examples that reference removed or renamed APIs

For each broken reference:
```
Consistency issue: {file}:{line}
References: {stale reference}
Current: {what it should be, or "removed"}
Action: {AUTO-FIX / FLAG}
```

Auto-fix simple renames. Flag removals for user review.

## Step 5: Cleanup + Status Sync

### Project status updates

If all stories in prd.json are done:
- Set `prd.json` → `metadata.status: "completed"`, `metadata.completedAt: "{ISO8601}"`
- Update `board.json` entry → `status: "completed"`, `updated_at: "{ISO8601}"`

### Reindex

```bash
qmd update 2>/dev/null || true
```

### Final report

```
Document release complete: {project title}

Updated:
  AUTO: {N} files ({list})
  ASK:  {N} files ({list})
  SKIPPED: {N} files ({list})

Consistency:
  Links verified: {N}
  Issues found: {N} ({N} auto-fixed, {N} flagged)

Status:
  prd.json: {completed/unchanged}
  board.json: {completed/unchanged}
```

---

## Rules

- **NEVER clobber CHANGELOG** — this is the #1 rule. Polish wording, never regenerate
- **NEVER bump VERSION without asking** — version bumps are release decisions, not doc decisions
- **Minimal diff** — use Edit with exact matches, never Write to overwrite docs wholesale
- **AUTO for machines, ASK for humans** — CLAUDE.md and architecture docs can be auto-updated; README and setup guides need approval
- **Company isolation** — only touch docs within the resolved company/project scope
- **INDEX.md regeneration** — use the standard INDEX.md spec from `knowledge/public/hq-core/index-md-spec.md`
- **No implementation** — this command updates documentation only. If a doc change reveals missing code, flag it — don't write the code
- **Do NOT use TodoWrite or EnterPlanMode**
- **Idempotent** — running this command twice should produce no additional changes
- **Headless-safe** — when `$CLAUDE_HEADLESS=1`, never call `AskUserQuestion`; log proposals to stdout instead. This skill is invoked headless by `scripts/handoff-post.sh`, and a prompt in that context blocks forever
