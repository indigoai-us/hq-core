---
description: Upgrade HQ from the latest indigoai-us/hq release
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion
argument-hint: [--check | --from v{X.Y.Z} | v{target}]
visibility: public
---

# /update-hq - HQ Upgrade

Upgrade your HQ installation from the latest indigoai-us/hq release on GitHub.

**User's input:** $ARGUMENTS

## Argument Parsing

Parse `$ARGUMENTS` for:
- `--check` → set `DRY_RUN=true` (report only, no writes)
- `--from v{X.Y.Z}` → set `OVERRIDE_VERSION={X.Y.Z}` (skip auto-detection)
- `v{X.Y.Z}` (bare version) → set `TARGET_OVERRIDE={X.Y.Z}` (upgrade to specific version, not latest)

Multiple flags can combine: `/migrate --check --from v5.0.0 v5.3.0`

---

## Phase 1: Detect Current Version

### 1a. Check gh CLI
```bash
which gh
```
If missing: hard stop.
```
GitHub CLI required for /migrate.

Install: brew install gh
Then: gh auth login
```

Check auth:
```bash
gh auth status 2>&1
```
If not authenticated: hard stop with `"Run: gh auth login"`.

### 1b. Detect version

If `OVERRIDE_VERSION` is set, use it. Otherwise:

1. Read `CHANGELOG.md` from HQ root.
2. Scan for first heading matching `## v{X.Y.Z}` (regex: `/^## v(\d+\.\d+\.\d+)/`).
3. If found → `CURRENT_VERSION={match}`.
4. If CHANGELOG.md missing or no match, use structural markers:
   - `workers/dev-team/codex-*` dirs exist → `>= v5.3.0`
   - `workers/sample-worker/` exists → `>= v5.0.0`
   - `settings/pure-ralph.json` exists → `>= v3.0.0`
   - `workspace/content-ideas/` exists → `>= v2.0.0`
   - None → `unknown`
5. If `unknown`: ask user with AskUserQuestion — cannot proceed without a baseline.

Display:
```
Current HQ version: v{CURRENT_VERSION}
```

If structural fallback was used, note: `"(detected via structural markers — no CHANGELOG.md found)"`

---

## Phase 2: Fetch Target Version

If `TARGET_OVERRIDE` is set, use it. Otherwise:

```bash
gh api repos/indigoai-us/hq/releases/latest --jq '.tag_name' 2>/dev/null
```

If that fails (no releases):
```bash
gh api repos/indigoai-us/hq/tags --jq '.[0].name' 2>/dev/null
```

Set `TARGET_VERSION` from result (strip leading `v` for comparison, keep for display).

### Semver compare

Split both versions on `.`, compare major → minor → patch as integers.

If `CURRENT_VERSION >= TARGET_VERSION`:
```
Already up to date (v{CURRENT_VERSION}).
```
Stop.

### Show upgrade path

Fetch CHANGELOG.md from target:
```bash
gh api repos/indigoai-us/hq/contents/template/CHANGELOG.md?ref=v{TARGET_VERSION} --jq '.content' | base64 -d
```

Extract all version headings (`## v{X.Y.Z}`) between CURRENT and TARGET. Display:
```
Upgrade path: v{CURRENT} → v{intermediate1} → ... → v{TARGET}
```

---

## Phase 3: Parse Migration Data

Fetch MIGRATION.md from target:
```bash
gh api repos/indigoai-us/hq/contents/template/MIGRATION.md?ref=v{TARGET_VERSION} --jq '.content' | base64 -d
```

### Parse sections

Collect every `## Migrating to v{X}` section where X is between CURRENT (exclusive) and TARGET (inclusive).

Within each section, classify content by `### ` subheadings:

| Subheading pattern | Category |
|---|---|
| `New Commands`, `New Skills`, `New Knowledge`, `New File`, `New Worker Structure`, `New Directories`, `New Feature` | **new_files** |
| `Updated Commands`, `Updated Files`, `Updated Knowledge`, `Updated Workers`, `Updated Skills` | **updated_files** |
| `Removed` | **removed_files** |
| `Breaking Changes` | **breaking_changes** |
| `Migration Steps` | **migration_steps** (informational, shown but not auto-executed) |

### Extract file paths

From each bullet line, extract paths matching: `` - `{path}` `` (backtick-wrapped path after dash).

For directory references (path ends with `/` or says "entire directory"), flag for directory listing later.

### Deduplicate

A file appearing in both v5.1.0 "Updated" and v5.4.0 "Updated" → keep once, fetch from TARGET only.

### Present summary

```
Upgrading v{CURRENT} → v{TARGET}

  New files:        {N}
  Updated files:    {M}
  Removed files:    {R}
  Breaking changes: {B}
```

If `DRY_RUN`: note `"(dry run — no changes will be made)"`

Ask to proceed (unless dry run, which always proceeds to analysis):
```
Proceed with migration? [Y/n]
```

---

## Phase 4: Pre-flight

**Skip entirely if `DRY_RUN=true`.**

### Repos directory validation

Check that `repos/public/` and `repos/private/` exist. These are required since v5.0.0 — all repos (code, knowledge, company projects) live here.

```bash
ls -d repos/public repos/private 2>/dev/null
```

If either is missing:
- If `DRY_RUN`: report `"Would create: repos/public/ and repos/private/"`.
- Otherwise: `mkdir -p repos/public repos/private`, increment `created`, report `"✓ Created repos/public/ and repos/private/ (required structure)"`.

### Git status check

Check git status:
```bash
git status --porcelain
```

If output is non-empty (uncommitted changes), use AskUserQuestion:

```
Your HQ has uncommitted changes. Before migrating:

1. Commit changes now (recommended)
2. Stash changes
3. Proceed anyway (risky — can't easily revert)
4. Abort migration
```

Actions:
- **Commit**: `git add -A && git commit -m "pre-migrate: save state before upgrade to v{TARGET}"`
- **Stash**: `git stash push -m "pre-migrate: before v{TARGET}"`
- **Proceed**: continue with warning
- **Abort**: stop

---

## Phase 5: Apply Migration

Process in order: **new files → updated files → breaking changes → removals**.

Track counters: `created=0, auto_updated=0, user_updated=0, skipped=0, deleted=0, failed=0`.
Track list: `skipped_files=[]` (for summary).

### 5a. New Files

For each path in `new_files`:

1. Check if file exists locally.
2. If exists → skip, increment `skipped`, note `"Already exists: {path}"`.
3. If not exists:
   - For directories: list contents first:
     ```bash
     gh api "repos/indigoai-us/hq/contents/template/{dir_path}?ref=v{TARGET}" --jq '.[].path'
     ```
     Then process each file in the directory.
   - Fetch content:
     ```bash
     gh api "repos/indigoai-us/hq/contents/template/{path}?ref=v{TARGET}" --jq '.content' | base64 -d
     ```
   - If `DRY_RUN`: report `"Would create: {path}"`. Do not write.
   - Otherwise: create parent dirs (`mkdir -p`), write file, increment `created`.
   - Report: `"✓ Created: {path}"`

If fetch fails for any file: report error, increment `failed`, continue.

### 5b. Updated Files

For each path in `updated_files`:

1. **Fetch upstream** content from TARGET tag (same gh api + base64 as above).
2. **Read local** file. If file doesn't exist locally:
   - Ask: `"{path} doesn't exist locally. Create from upstream? [Y/n]"`
   - If yes and not dry run: write it, increment `created`.
   - If no or dry run: skip.
   - Continue to next file.
3. **Compare local to upstream.** If identical → skip. `"Already up to date: {path}"`. Continue.
4. **Special handling for `.claude/CLAUDE.md`** → go to section 5b-CLAUDE below.
5. **Special handling for `workers/registry.yaml`** → go to section 5b-REGISTRY below.
6. **Special handling for `.claude/settings.json`** → go to section 5b-SETTINGS below.
7. **Three-way merge for all other files:**
   - Fetch **base** content (from CURRENT version tag):
     ```bash
     gh api "repos/indigoai-us/hq/contents/template/{path}?ref=v{CURRENT}" --jq '.content' | base64 -d
     ```
   - If base fetch fails (file didn't exist in that version): treat as conflict, go to step 7b.
   - **7a. If local == base** (user never customized): auto-update.
     - If `DRY_RUN`: `"Would auto-update: {path} (no local customizations)"`. Skip write.
     - Otherwise: write upstream content, increment `auto_updated`. `"✓ Auto-updated: {path}"`
   - **7b. If local != base** (user customized): **CONFLICT**.
     - Show unified diff of upstream changes (base → upstream).
     - Show note that local file has been customized from the base version.
     - Use AskUserQuestion:
       ```
       {path} has local customizations AND upstream changes.

       1. Overwrite with upstream (lose your customizations)
       2. Skip (keep your version, merge manually later)
       3. Show full upstream file content
       ```
     - If overwrite and not dry run: write upstream, increment `user_updated`.
     - If skip: increment `skipped`, add to `skipped_files`.
     - If show: display full upstream content, then re-ask overwrite/skip.
     - If `DRY_RUN`: report `"Would prompt: {path} (has local customizations)"`.

### 5b-CLAUDE: CLAUDE.md Section-Level Merge

CLAUDE.md is the most customized file. Never auto-overwrite.

1. Parse both local and upstream CLAUDE.md into sections by `## ` headings.
   - Each section = heading text + all content until next `## ` heading or EOF.
2. Compare section lists:
   - **New sections** (in upstream, not in local): offer to append each individually.
     ```
     New section found in upstream CLAUDE.md:

     ## {Section Heading}
     {first ~10 lines of content...}

     Append this section to your CLAUDE.md? [Y/n]
     ```
     If yes and not dry run: append section to end of local CLAUDE.md.
   - **Changed sections** (heading exists in both, content differs): show diff of that section.
     ```
     Section "## {Heading}" has upstream changes.

     {unified diff of just this section}

     1. Replace this section with upstream version
     2. Skip (keep your version)
     3. Show full upstream section
     ```
   - **Removed sections** (in local, not in upstream): leave alone (user's custom sections).
   - **Identical sections**: skip silently.
3. If `DRY_RUN`: report which sections would be added/changed, write nothing.
4. Track: if ANY section was skipped, add `CLAUDE.md` to `skipped_files`.

### 5b-REGISTRY: registry.yaml Special Handling

Never auto-overwrite — user has custom workers.

1. Show diff between local and upstream.
2. Always ask via AskUserQuestion:
   ```
   workers/registry.yaml has upstream changes (new workers, version bump).
   Your local registry has custom workers that will be preserved.

   1. Show diff
   2. Overwrite (will lose custom worker entries)
   3. Skip (merge manually later)
   ```
3. If `DRY_RUN`: report `"Would prompt: workers/registry.yaml"`.
4. If skipped: add to `skipped_files`.

### 5b-SETTINGS: settings.json Special Handling

Never auto-overwrite — user has custom permissions and hooks.

1. Parse both local and upstream `.claude/settings.json` as JSON.
2. Compare by top-level key:
   - **`permissions`**: keep local (user's choice). Report if upstream differs.
   - **`hooks`**: merge by event type (`PreToolUse`, `PostToolUse`, `PreCompact`, etc.)
3. For each hook event type in upstream:
   - **New event type** (in upstream, not in local): offer to add.
     ```
     New hook event type found in upstream settings.json:

     "{EventType}": [
       { "matcher": "{matcher}", "hooks": [...] }
     ]

     Add this hook? [Y/n]
     ```
     If yes and not dry run: add the event type block to local hooks.
   - **Existing event type** (in both): compare individual matcher+command pairs.
     - New entries (matcher+command in upstream, not in local): offer to add.
     - Changed entries (same matcher, different command/timeout): show diff, ask overwrite/skip.
     - Local-only entries: keep (user's custom hooks).
   - **Local-only event type** (not in upstream): keep silently.
4. If any changes were made, show the resulting `settings.json` diff. Ask: `"Apply these settings changes? [Y/n]"`
5. If `DRY_RUN`: report what would change, no write.
6. If skipped: add `settings.json` to `skipped_files`.

### 5c. Breaking Changes

For each breaking change parsed from MIGRATION.md:

1. Display:
   ```
   ⚠ BREAKING CHANGE (v{version}):
   {description text from MIGRATION.md}
   ```

2. If the description mentions deleting a file:
   - Check if file exists locally.
   - If exists: `"Delete {path}? [Y/n]"`
   - If confirmed and not dry run: delete file, increment `deleted`.
   - If declined: note in summary.

3. If the description mentions renaming keys (e.g., `features` → `userStories`):
   - Scan local files for the old pattern using Grep.
   - Report matches: `"Found {N} files with old key '{old}'. These need manual update."`
   - Do NOT auto-edit (too risky).

4. For all other breaking changes: require acknowledgment.
   ```
   Acknowledge? [Y to continue / N to abort migration]
   ```
   If N: stop migration, write partial summary.

5. If `DRY_RUN`: display breaking changes but don't ask for acknowledgment.

### 5d. Removals

For each path in `removed_files`:

1. Check if file/directory exists locally.
2. If doesn't exist: skip silently.
3. If exists:
   ```
   The upstream repo removed {path} in v{version}.

   Delete locally? [Y = delete / N = keep your copy]
   ```
4. If yes and not dry run: delete, increment `deleted`.
5. If no: note in summary.
6. If `DRY_RUN`: report `"Would prompt to delete: {path}"`.

---

## Phase 6: Post-Migration

### 6a. Update CHANGELOG.md

Ask first:
```
Update your CHANGELOG.md with version entries from v{CURRENT} to v{TARGET}? [Y/n]
```

If yes and not dry run:
- Read local CHANGELOG.md.
- Prepend migration marker at top (after any existing header):
  ```markdown
  ## v{TARGET} (migrated {YYYY-MM-DD})

  Migrated from v{CURRENT} via `/migrate`.
  ```
- Fetch all changelog entries from the upstream CHANGELOG.md between CURRENT and TARGET.
- Append those entries after the migration marker.
- Write updated CHANGELOG.md.

### 6b. Write Migration Log

If not dry run, write to `workspace/migrate-v{TARGET}.md`:

```markdown
# Migration Log: v{CURRENT} → v{TARGET}

**Date:** {YYYY-MM-DD}

## Summary

| Action | Count |
|--------|-------|
| Created | {created} |
| Auto-updated | {auto_updated} |
| User-updated | {user_updated} |
| Skipped | {skipped} |
| Deleted | {deleted} |
| Failed | {failed} |

## Skipped Files (need manual merge)

{for each skipped file:}
- `{path}` — has local customizations, review upstream changes

## Failed Files (fetch errors)

{for each failed file:}
- `{path}` — {error reason}

## Breaking Changes Acknowledged

{list of breaking changes that were acknowledged}
```

### 6c. Update Search Index

```bash
qmd update 2>/dev/null || true
```

### 6d. Print Summary

```
Migration Complete: v{CURRENT} → v{TARGET}

  Created:        {created} new files
  Auto-updated:   {auto_updated} files (no local customizations)
  User-updated:   {user_updated} files (overwritten by choice)
  Skipped:        {skipped} files (kept local version)
  Deleted:        {deleted} files
  Failed:         {failed} files (fetch errors)

{if skipped > 0:}
Files needing manual merge:
  {list of skipped_files}

Migration log saved to: workspace/migrate-v{TARGET}.md

Next steps:
1. Review skipped files and manually merge upstream changes
2. Run `qmd update 2>/dev/null || true` to update search index
3. Test your workflows to verify nothing broke
```

If `DRY_RUN`, replace header with:
```
DRY RUN COMPLETE (no changes made)

  Would create:      {created}
  Would auto-update: {auto_updated}
  Would prompt:      {skipped} files with conflicts
  Would delete:      {deleted}
  Failed to fetch:   {failed}

Run `/migrate` without --check to apply.
```

---

## Rules

- **NEVER auto-overwrite CLAUDE.md** — always section-level merge with per-section approval
- **NEVER auto-overwrite registry.yaml** — user has custom workers, always ask
- **NEVER auto-overwrite settings.json** — merge hooks by event type, preserve user permissions and custom hooks
- **Always offer skip** — user can decline any individual file update
- **Idempotent** — content-based comparison, no external state. Running twice is safe
- **Network-safe** — report and skip on individual fetch failure, don't abort entire migration
- **gh CLI required** — hard stop if not installed or not authenticated
- **Three-way merge** — compare local vs base version, not just local vs upstream
- **New files first** — process new files before updates (no conflicts, quick wins)
- **Breaking changes require acknowledgment** — never silently apply
- **CHANGELOG is version source of truth** — update it last to reflect successful migration
- **Dry run must never write** — `--check` only reports, touches no files
- **One file at a time** — never batch-overwrite without showing what changed
