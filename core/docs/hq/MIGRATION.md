## Release: v14.2.2

### TL;DR

Patch release. Adds Claude-drafted note pre-fill to `/hq-share`: the skill inventories the shared paths, drafts a 1–2 sentence factual note, and confirms with you before minting. The accepted draft rides on the share-session URL as `?note=` and pre-populates the recipient-facing note textarea in the hq-console form — the sender just reviews and approves.

**No operator action required.** Run `/update-hq` to pick it up. No breaking changes, no config to set, no migration steps. Existing `/hq-share` invocations behave identically when the draft step doesn't fire (vault-only paths, headless contexts, or `--no-draft`).

Companion server-side change shipped via `indigoai-us/hq-console#126` — already live on `hq.{your-domain}.com`. The form-side `?note=` reader was deployed before this release, so old `/hq-share` invocations (no `?note=` param) keep their empty-textarea behavior.

### Changed

- **`.claude/skills/hq-share/SKILL.md`** — new Step 3.5 "Draft the note" inserts between scope-confirm and mint. Documents the inventory cap (~30 entries, ≤100 KB per file, text-only basenames), the confirm picker (Use as-is / Edit / Skip / Type-my-own), the always-edit guarantee for the sender, and the new `--no-draft` flag. Step 4 (Mint) now always passes `--no-open` and re-opens the browser itself so `?note=` can be appended without a CLI release. Rule #6 added: factual no-speculation drafting (no "urgent", no "you'll love this", skip the draft if the inventory produces nothing usable).

### New Flag

- `--no-draft` — skips Step 3.5 entirely. Useful when the sender wants to type the note from scratch without an agent-generated starting point. The textarea is still optional and editable in the browser; only the pre-fill is bypassed.

### Server-Side Companion (Already Live)

- `hq-console` `ShareSessionForm` reads `?note=` from `useSearchParams` on mount and seeds the note textarea. A small "drafted by Claude — edit freely" hint appears above the label while the draft is untouched; it disappears on the sender's first keystroke. `?note=` value is capped at 2000 chars (matches the existing soft-hint threshold for notification-preview truncation). Auto-grow `useEffect` ensures multi-line drafts render at natural height on first paint. Three new vitest cases cover prefill behavior, the 2000-char cap, and the absent-param path (no behavior change).

### How To Verify

```
# In any HQ session that picked up v14.2.2:
/hq-share companies/{co}/data/some-folder/

# You should see, after path confirmation:
# - A short Claude-drafted note for review
# - A picker: Use as-is / Edit / Skip
# - Browser opens with the textarea pre-filled and "drafted by Claude" hint visible
# - Editing the textarea clears the hint
```

If `?note=` doesn't appear on the URL, check that the skill ran Step 3.5 (it skips on `--no-draft`, headless contexts, or vault-only paths that aren't locally readable).

---

## Release: v14.2.1

### TL;DR

Consolidated promotion folding the open-PR backlog (#141, #146, #149, #151, #159, #160, #161, #162, #164, #165, #167) onto v14.2.0. The **only operator action** is to re-merge `.claude/CLAUDE.md` after `/update-hq` if you customized it (Charter rewrite: 332 → 145 lines, same rules, denser layout). `/update-hq` smart-merges section-by-section.

Highlights:
- Hard PreToolUse hook mechanically blocks bare `git`/`gh` mutations from the HQ root (sanctioned: prefix `HQ_ALLOW_HQ_ROOT_GIT=1`).
- Minted `/hq-share` / `/hq-secrets` / `/hq-files` secure-links now render as Markdown links at mint time.
- Claude Code's native file-based auto-memory ships disabled by default (`autoMemoryEnabled: false`); re-enable per-machine in `.claude/settings.local.json` if wanted.
- `/handoff` follow-ups (learning, document-release) run as visible Codex subagents instead of detached-headless.
- `/deploy` documents Cognito org-access policy modes; `/deploy` preferences separated from `~/.hq/config.json`.
- `/run-project` budget orchestration tightened; `/learn` captures silently (no mid-task confirmation).
- Stray `.claude/policies/` scope retired — `_digest.md` only emits in the three canonical scopes (`core/policies/`, `companies/*/policies/`, `repos/{public,private}/*/.claude/policies/`).

### New Files

- `.claude/hooks/block-hq-root-git-mutation.sh` — hard PreToolUse Bash hook (all profiles). Mechanically blocks bare `git`/`gh` mutations from the HQ root; sanctioned HQ-internal git work sets `HQ_ALLOW_HQ_ROOT_GIT=1` on the single command. Backstops hard policies `hq-root-never-push-remote` and `hq-git-discipline`. (Force-upstream during merge.)
- `core/policies/hq-hook-gate-three-profile-lists.md` — codifies the three hook profiles (`minimal` / `standard` / `strict`) routed through `.claude/hooks/hook-gate.sh`.
- `core/policies/hq-policy-enforcement-claims-verify-wiring.md` — when a policy claims hard enforcement, the corresponding wiring (`settings.json` hook entry + `hook-gate.sh` dispatch) must exist; reviewers verify before merge.
- `core/policies/hq-secure-link-render-as-markdown.md` — hard policy: `/hq-share`, `/hq-secrets`, `/hq-files` must render minted secure-links as Markdown links at mint time (folds PR #167).
- `core/policies/learn-auto-no-confirmation.md` — `/learn` captures silently; never prompts mid-task for confirmation.
- `core/scripts/tests/handoff-post-no-claude.test.sh` — regression test for `core/scripts/handoff-post.sh` ensuring the script no longer assumes a headless-Claude binary on `$PATH`. (Force-upstream during merge.)

### Updated Files

- `.claude/CLAUDE.md` — rewritten to the compressed Purpose / Rules / Map Charter (332 → 145 lines). Same rules, denser. **Section-level smart merge** — `/update-hq` walks each section and prompts where local content diverges from base. Operators who never customized CLAUDE.md see a clean auto-update. (Folds and supersedes #159, #141.)
- `.claude/settings.json` — adds `"autoMemoryEnabled": false` (HQ persistence supersedes Claude Code's native file-based auto-memory, which was duplicating learnings); wires the new HQ-root git-mutation guard hook into `PreToolUse → Bash`. Smart-merged per event type.
- `.claude/hooks/hook-gate.sh` — dispatches the new `block-hq-root-git-mutation.sh` hook. (Force-upstream during merge.)
- `.claude/audit/instructions.md` — references to the retired `.claude/policies/` scope removed.
- `.claude/audit/suppressions.yaml` — suppressions tied to the retired `.claude/policies/` scope removed.
- `core/policies/auto-deploy-on-create.md` — small clarification on the auto-deploy preflight handshake.
- `core/policies/hq-deploy-reinforcement.md` — documents Cognito org-access policy modes (`open` / `domain-allowlist` / `principal-allowlist`); separates `/deploy` preferences from `~/.hq/config.json`. (Folds #151+#162.)
- `core/policies/quiet-by-default-narration.md` — moved from `.claude/policies/` to the canonical `core/policies/` scope (see Removed for the old path).
- `core/policies/ralph-orchestrator-context-discipline.md` — `/run-project` budget orchestration tightened. (Folds #146.)
- `core/scripts/handoff-post.sh` — `/handoff` follow-ups (learning, document-release) now run as visible Codex subagents instead of detached headless; includes zsh unmatched-glob → `find` fix in pipeline-detect. (Force-upstream; folds #149+#160; supersedes #161.)
- `core/scripts/run-project.sh` — budget-orchestration alignment with the updated policy. (Force-upstream during merge.)

### Updated Skills

- `.claude/skills/deploy/SKILL.md` — Cognito org-access policy modes; `/deploy` preferences moved out of `~/.hq/config.json`. Example email addresses use RFC-2606 `@example.com` (audit remediation of `hq-audit-bot` findings #169 / iteration #171).
- `.claude/skills/document-release/SKILL.md` — invoked as a visible Codex subagent from `/handoff`.
- `.claude/skills/handoff/SKILL.md` — runs learning + document-release as visible Codex subagents; zsh unmatched-glob fix in pipeline-detect. (Folds #149+#160.)
- `.claude/skills/hq-files/SKILL.md` — minted secure-links rendered as Markdown links at mint time (folds #167).
- `.claude/skills/hq-secrets/SKILL.md` — same Markdown-link rendering for minted secure-links.
- `.claude/skills/hq-share/SKILL.md` — same Markdown-link rendering for minted secure-links.
- `.claude/skills/run-project/SKILL.md` — budget orchestration (frontmatter `argument-hint` + body). (Folds #146.)

### Removed

- `.claude/policies/quiet-by-default-narration.md` — relocated to `core/policies/quiet-by-default-narration.md` (canonical scope).
- `.claude/policies/_digest.md` — stale digest from the retired `.claude/policies/` scope. `core/scripts/build-policy-digest.sh` only emits `_digest.md` in three canonical scopes: `core/policies/`, `companies/*/policies/`, `repos/{public,private}/*/.claude/policies/`.
- `.claude/policies/` — now-empty directory removed.

### Migration Steps

1. Run `/update-hq` to apply this release.
2. If you customized `.claude/CLAUDE.md`, work through the section-level smart-merge prompts. Same rules as before, just denser layout — most sections collapse to identical or trivial three-way merges.
3. If you have HQ-internal git wrappers that ran bare `git` / `gh` mutations from the HQ root, prefix each call with `HQ_ALLOW_HQ_ROOT_GIT=1`. The new hard PreToolUse hook blocks unprefixed mutations regardless of profile.
4. If you preferred Claude Code's native file-based auto-memory, re-enable it per machine in `.claude/settings.local.json`: `{ "autoMemoryEnabled": true }`. The shipped default is now `false` because HQ's persistence (knowledge bases, policies, `/learn`, handoff/thread state) was being duplicated.

### What does NOT need migrating

- No slash-command names or skill paths change — `/<name>` invocations resolve at the same surface as before.
- New policies auto-load via SessionStart; no manual wiring required.
- `companies/`, `personal/`, `repos/`, and `workspace/` are not touched.
- `hq-cmd-handoff-defer-heavy-post-script` was marked `public:false` and never promoted out of staging — there is nothing to remove from your install. Its discipline is now enforced by the updated `/handoff` SKILL plus the new `core/scripts/tests/handoff-post-no-claude.test.sh` regression test.

## Release: v14.2.0

### TL;DR

**Read this before running `/update-hq`.** This release is more invasive than a normal patch — `core/`, `.claude/`, `.codex/`, and `.agents/` are replaced wholesale (and so is `.obsidian/`, if you carry one). The updater overwrites every file in those trees that exists in hq-core, as-is. Any local customization you made in place will be lost if you don't move it into the `personal/` overlay first. See **Step 1** (snapshot to `~/.hq/backups/`) and **Step 2** (move customizations to `personal/`) below before you run `/update-hq`.

If you have made **no** customizations to those trees, `/update-hq` still does the heavy lifting — the shipped hooks rewire themselves and most operators are done. Either way, the HQ root layout was reduced and the command/skill surface was consolidated; operators with local scripts, bookmarks, shortcuts, sync conflicts, or documentation links should also review the path and reference changes below.

After update, your visible HQ root should be reduced to the stable operating directories:

- `AGENTS.md` — symlink into `.claude/CLAUDE.md`; do not replace it with a regular file
- `companies/` — operator-owned tenants (not touched by update)
- `core/` — release-shipped, replaced wholesale
- `personal/` — operator-owned overlay (not touched by update)
- `repos/` — operator-owned code checkouts (not touched by update)
- `workspace/` — operator-owned session and orchestrator state (not touched by update)

Hidden runtime directories — `.claude/`, `.codex/`, `.agents/`, `.github/`, and `.obsidian/` (if present) — also exist at the root and **are** replaced wholesale by the update.

**Note on the root `MIGRATION.md` symlink:** this release ships a one-time symlink `MIGRATION.md` → `core/docs/hq/MIGRATION.md` at the HQ root so operators can find the migration note in its old location. It is a discoverability shim for this release only and will be removed in the next release. Update any bookmarks or scripts that reference `MIGRATION.md` at the root to point at `core/docs/hq/MIGRATION.md` instead.


### Step 1 — Snapshot your HQ to `~/.hq/backups/` before anything else

Before any of the moves, deletes, or `/update-hq` runs below, copy your entire HQ root to a timestamped backup directory. This release is invasive (`core/`, `.claude/`, `.codex/`, `.agents/`, `.obsidian/` are all replaced wholesale), and a snapshot is your only recourse if something operator-specific was missed in the move-to-`personal/` step.

```bash
# Run from the HQ root.
HQ_ROOT="$(pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="${HOME}/.hq/backups/pre-update-${STAMP}"

mkdir -p "${HOME}/.hq/backups"
rsync -a --exclude='.git/' "${HQ_ROOT}/" "${DEST}/"

echo "Snapshot at ${DEST}"
```

The exclude of `.git/` keeps the snapshot small; the working tree is what matters here. Inspect `${DEST}` and confirm it has the trees you care about (`core/`, `.claude/`, `.codex/`, `.agents/`, `.obsidian/`, `companies/`, `personal/`, `repos/`, `workspace/`) before proceeding.

**Retention.** Keep the snapshot for at least 7 days after `/update-hq`. A future hq-core release will ship a cleanup helper that prunes `~/.hq/backups/pre-update-*` directories older than 7 days; until then, deleting them is a manual decision. If you find operator content was lost during the update, recover it from the snapshot and move it into `personal/` so it survives subsequent updates.

### Step 2 — Save operator customizations to `personal/` before `/update-hq`

**This release replaces `core/`, `.claude/`, `.codex/`, `.agents/`, and `.obsidian/` wholesale.** Every file in those trees that ships with hq-core — skills, hooks, policies, scripts, docs, default settings, Codex prompts, Obsidian vault config — is overwritten by the updater. The rule is simple: **whatever file exists in the upstream hq-core release is copied into your install as-is, replacing whatever you had at that path.**

`repos/` and `workspace/` are **not** touched by the update — they are pure operator-owned trees. Neither is `companies/` or `personal/`. If your operator-only content lives under any of those four, nothing to do.

For operator-only content currently inside the wholesale-replaced trees, move it into the `personal/` overlay before running `/update-hq`. The overlay is operator-owned and `master-sync.sh` symlinks `personal/<type>/<entry>` back into `core/<type>/<entry>` after the update, so the customization continues to surface in the same place it did before.

What to move and where:

| Operator-owned content currently in… | Move to… |
| --- | --- |
| `core/policies/<name>.md` you authored (does not exist upstream) | `personal/policies/<name>.md` |
| `core/knowledge/<name>/` you authored (does not exist upstream) | `personal/knowledge/<name>/` |
| `core/workers/<name>/` you authored (does not exist upstream) | `personal/workers/<name>/` |
| `core/settings/<name>` you authored (does not exist upstream) | `personal/settings/<name>` |
| `.claude/skills/<name>/` you authored (does not exist upstream) | `personal/skills/<name>/` |
| `.claude/hooks/<event>/<hook>.sh` you authored | `personal/hooks/<event>/<hook>.sh` |
| Hand-tweaked `.codex/` files (config, output-style, etc.) | back up before update; re-apply by hand if you need a custom Codex config |
| Hand-tweaked `.agents/` symlinks | back up; the upstream version restores the canonical symlinks |
| Hand-tweaked `.obsidian/` vault config | back up the JSON files you care about and re-apply after update |
| Anything at the HQ root that is operator-only (notes, drafts, scratch dirs) | `personal/` (pick a subdirectory that matches the content type) |

Rules of thumb for telling release content from operator content:

- If a file is identical to its upstream copy on `indigoai-us/hq-core` `main`, it is release content — leave it where it is, the updater will refresh it cleanly.
- If a file exists on `indigoai-us/hq-core` `main` but you have edited it locally, decide whether you actually need the local divergence. `master-sync.sh` only places a `personal/<type>/<entry>` symlink into `core/<type>/<entry>` when nothing already exists at the link target (collision rule: "skip if non-symlink"). That means a `personal/policies/foo.md` copy does **not** override a release-shipped `core/policies/foo.md` — `/update-hq` will land the upstream copy and the personal copy will sit unused. If you genuinely need the local divergence, either accept the upstream version this release and re-apply your edit on top (`personal/` cannot help), or maintain a private fork patch outside HQ.
- If a file does **not** exist on `indigoai-us/hq-core` `main` at all, it is operator-only. Move it to `personal/` (or to `companies/`, `repos/`, `workspace/` if that is its rightful home) so it survives.

After running `/update-hq`:

- `core/`, `.claude/`, `.codex/`, `.agents/`, and `.obsidian/` should be identical to upstream plus the symlinks from `personal/`. Anything operator-only that you did not move first will be gone from the working tree (recoverable from `git` history, but disruptive).
- `AGENTS.md` at the HQ root should still be a symlink to `.claude/CLAUDE.md`. If `/update-hq` somehow left a regular file there, recreate the symlink: `rm AGENTS.md && ln -s .claude/CLAUDE.md AGENTS.md`.
- Run `bash core/scripts/codex-skill-bridge.sh status` to confirm skills are wired.
- Run `git status` from the HQ root and inspect anything still dirty in `core/`, `.claude/`, `.codex/`, or `.agents/` — that's a sign the move was incomplete.

### Step 3 — Run the replacement (and bypass the hooks)

The canonical path is the slash command:

```text
/update-hq
```

It fetches the latest `indigoai-us/hq-core` release, snapshots the diff, and writes every release-tracked file into your install. The skill knows to set `HQ_BYPASS_CORE_PROTECT=1` for its own Edit/Write/Bash calls, so the in-session hooks (`block-core-writes`, `block-core-writes-bash`, `protect-core`) do not reject the wholesale-replace writes.

If you would rather run the replacement by hand (or `/update-hq` hits a hook block and you need to finish the job manually), use the rsync block below. The `HQ_BYPASS_CORE_PROTECT=1` prefix is **required** when running from inside Claude Code or Codex because the in-session hooks otherwise block writes to `core/` and `.claude/hooks/`. If you run from a plain terminal that has no Claude Code session attached, the hooks do not fire at all and the prefix is a no-op — leave it in either way.

```bash
# Run from the HQ root. Adjust the version tag if you want a specific release.
set -euo pipefail

TAG="$(gh api repos/indigoai-us/hq-core/releases/latest --jq '.tag_name')"
WORK="$(mktemp -d)"

gh release download "$TAG" -R indigoai-us/hq-core -p '*.tar.gz' -D "$WORK"
tar -xzf "$WORK"/*.tar.gz -C "$WORK"
SRC="$(find "$WORK" -maxdepth 2 -type d -name 'hq-core-*' | head -1)"
[ -d "$SRC" ] || { echo "Could not locate extracted release root under $WORK"; exit 1; }

# Wholesale-replace each tree. --delete drops files that no longer exist
# upstream (this is how the deletes from "Also delete" land automatically
# for paths inside these trees; paths outside still need the manual rm
# block in the previous section).
HQ_BYPASS_CORE_PROTECT=1 rsync -a --delete "$SRC/core/"     ./core/
HQ_BYPASS_CORE_PROTECT=1 rsync -a --delete "$SRC/.claude/"  ./.claude/
HQ_BYPASS_CORE_PROTECT=1 rsync -a --delete "$SRC/.codex/"   ./.codex/
HQ_BYPASS_CORE_PROTECT=1 rsync -a --delete "$SRC/.agents/"  ./.agents/

# .obsidian/ is replaced only if the release ships one; back up first if you
# have local vault state you care about (see Step 2).
if [ -d "$SRC/.obsidian" ]; then
  HQ_BYPASS_CORE_PROTECT=1 rsync -a --delete "$SRC/.obsidian/" ./.obsidian/
fi

# Refresh the shipped root entries (symlinks, AGENTS.md, ignore files).
HQ_BYPASS_CORE_PROTECT=1 rsync -a "$SRC/AGENTS.md" "$SRC/MIGRATION.md" ./
HQ_BYPASS_CORE_PROTECT=1 rsync -a \
  "$SRC/.claudeignore" "$SRC/.gitattributes" "$SRC/.gitignore" \
  "$SRC/.hqignore" "$SRC/.ignore" \
  ./

rm -rf "$WORK"
```

After the rsync block, run **Step 4** (rm commands for paths outside the wholesale-replaced trees) and **Step 5** (rm commands for old root copies of files that the wholesale-replace also lands at their new `core/docs/hq/` location).

If a hook still blocks a write despite the `HQ_BYPASS_CORE_PROTECT=1` prefix, run the command from a plain terminal outside Claude Code/Codex — there is no in-session hook to fire. Do not delete the hook file to "fix" the block; the hook is the safety net.

### Step 4 — Files /update-hq deletes for you (reference)

`/update-hq` walks the `removed_files` list from the release migration data and prompts to delete each path that exists locally but is gone in the new release (Phase 5d). You do **not** need to run the `rm` blocks below by hand — they are documented here so you can see exactly what was retired and confirm the prompts during the run. If you skipped a prompt or are running outside `/update-hq` and need to mop up manually, the `rm` blocks are copy-pasteable. Either way, accept the deletes — the upstream is the source of truth for what ships.

**Commands consolidated into skills (60 files).** Every `.claude/commands/*.md` file shipped under `core/` is gone — slash invocations now resolve through `.claude/skills/<name>/SKILL.md` alone.

```bash
rm -rf .claude/commands
```

For reference, the deleted command files were:

```
accept           document-release  hq-share          newworker         retro
adr              execute-task      hq-sync           onboard           review
architect        finish-estimate   hq-whoami         out-of-scope      review-plan
ascii-graphic    garden            idea              personal-interview run
brainstorm       goals             import-claude    plan              run-pipeline
calibration-report handoff         investigate       prd               run-project
checkpoint       harness-audit     journal           promote           search
cleanup          hq-bug            land              quality-gate      setup
convert-codex    hq-login          land-batch        recover-session   startwork
decision-queue   hq-logout         learn             resolve-conflicts strategize
deep-plan        hq-share          newcompany                          sync-registry
designate-team                                                         tdd
diagnose                                                               track-estimate
discover                                                               tutorial
                                                                       update-hq
```

(Each is now reachable as `.claude/skills/<same-name>/SKILL.md`.)

**Skill scaffolding directories (3 entries).** The `_template`, `core`, and `personal` subdirectories under `.claude/skills/` are gone — skills now sit directly under `.claude/skills/<name>/`.

```bash
rm -rf .claude/skills/_template .claude/skills/core .claude/skills/personal
```

**HQ-Modules system (1 file).** The module loader and its manifest are gone — module-style rules are now expressed as policies under `personal/policies/` or as workers under `personal/workers/` (which `master-sync.sh` symlinks into `core/` for you, so they surface where the rest of the system expects them).

```bash
# HQ_BYPASS_CORE_PROTECT=1 is required when running these from inside
# Claude Code or Codex — block-core-writes-bash.sh otherwise rejects any
# rm/rmdir/cp/mv/rsync/sed -i/ln that names a `core/` path. The prefix is
# a no-op when run from a plain terminal.
HQ_BYPASS_CORE_PROTECT=1 rm -f core/modules/modules.yaml
# Then prune the directory if it is now empty:
HQ_BYPASS_CORE_PROTECT=1 rmdir core/modules 2>/dev/null || true
```

**Codex prompts directory (1 entry).** The legacy `.codex/prompts/` directory is gone — Codex now reads skill files directly via the `.agents/skills` bridge.

```bash
rm -rf .codex/prompts
```

**Privacy-and-CI artifacts no longer shipped (3 paths).** These three paths are not in the wholesale-replaced trees and are no longer part of the hq-core release, so you have to delete them by hand:

```bash
rm -rf .leak-scan
rm -f .github/workflows/pr-checks.yml
rm -f .github/workflows/audit.yml

# Then prune any directories left empty by the deletes above.
find .github/workflows -type d -empty -delete
```

Why each is gone:

- `.leak-scan/` — scan tooling and snapshots. Leak-scanning moved out-of-tree; it now runs against the staging buffer rather than as a release artifact.
- `.github/workflows/pr-checks.yml` — the leak-scan CI driver. Without `.leak-scan/`, the workflow has nothing to drive.
- `.github/workflows/audit.yml` — the PR audit workflow template. Enrolled repos now receive an equivalent workflow from `hq-pr-review-installer` instead of carrying it inline.

If you forked any of these workflows or wrote scripts that call `.leak-scan/scan.sh` directly, port them to your fork's own CI before deleting; the upstream copies will not return.

### Step 5 — Clean up moved root files and stale references

The wholesale replace lands the new copies at the new locations, but it does **not** delete the old copies at their old root locations. After `/update-hq`, run these moves and deletes from the HQ root:

```bash
# Root-facing HQ documentation moved under core/docs/hq/
rm -f CHANGELOG.md LICENSE README.md RELEASE-NOTES-v14.0.0.md USER-GUIDE.md

# Personal/HQ project scaffolding moved from root projects/ to personal/projects/
# If projects/ still has real subdirectories at this point, move them first:
if [ -d projects ] && [ "$(ls -A projects 2>/dev/null)" ]; then
  mkdir -p personal/projects
  # rsync -a (with trailing slashes) is dotfile-safe — `mv projects/*`
  # would silently skip hidden entries and the rm below would nuke them.
  rsync -a projects/ personal/projects/
fi
rm -rf projects

# Root data/ moved to personal/data/. Preserve any local content
# before pruning the old root copy.
if [ -d data ] && [ "$(ls -A data 2>/dev/null)" ]; then
  mkdir -p personal/data
  # rsync -a (with trailing slashes) is dotfile-safe — `mv data/*` would
  # silently skip hidden entries and the rm below would nuke them.
  rsync -a data/ personal/data/
fi
rm -rf data

# Root core.yaml; canonical location is core/core.yaml
rm -f core.yaml
```

Files moved (canonical relocation table):

| Old path | New path |
| --- | --- |
| `CHANGELOG.md` | `core/docs/hq/CHANGELOG.md` |
| `LICENSE` | `core/docs/hq/LICENSE` |
| `README.md` | `core/docs/hq/README.md` |
| `RELEASE-NOTES-v14.0.0.md` | `core/docs/hq/RELEASE-NOTES-v14.0.0.md` |
| `USER-GUIDE.md` | `core/docs/hq/USER-GUIDE.md` |
| root `projects/` | `personal/projects/` |
| root `data/` | `personal/data/` |
| root `core.yaml` | `core/core.yaml` |

### What changed

#### Layout and shipped-doc moves

- **Root-facing HQ documentation moved under `core/docs/hq/`.** `README.md`, `USER-GUIDE.md`, `CHANGELOG.md`, `LICENSE`, `MIGRATION.md`, and `RELEASE-NOTES-v14.0.0.md` now live in `core/docs/hq/`. `core/core.yaml` was updated so its locked documentation paths point at the new location.
- **`MIGRATION.md` symlinked at root (#143).** The canonical file remains `core/docs/hq/MIGRATION.md`; a root-level `MIGRATION.md` symlink is provided for discoverability. Edit the file at `core/docs/hq/MIGRATION.md`; the root symlink follows automatically.
- **Personal/HQ project scaffolding moved from root `projects/` to `personal/projects/`.** Personal/HQ projects should now live under `personal/projects/`. If a stale root `projects/` directory reappears after sync, inspect it before deletion (see **Project and journal notes** below).
- **Root `data/` moved to `personal/data/`.** Runtime journal/data placeholders move from root `data/` to `personal/data/`; project-scoped journals continue to live with their projects.
- **Root `core.yaml` removed.** The canonical metadata file is `core/core.yaml`.

#### Commands, skills, and modules

- **Commands consolidated into skills (#147).** Every `.claude/commands/*.md` shipped under `core/` has been removed in favor of `.claude/skills/<name>/SKILL.md` as the single source of truth. Both Claude Code and Codex now read the same skill file (Codex via `.agents/skills`). If you maintained local references to `.claude/commands/<name>.md`, update them to point at the skill path instead. User-personal skills under `personal/skills/<skill>/` continue to surface as flat slash commands via `master-sync.sh`.
- **HQ-Modules manifest system removed (#140).** `core/modules/modules.yaml` and the module loader have been deleted. The locked path list in `core/core.yaml` no longer references `core/modules/`. If you authored a custom module manifest, migrate its rules into a policy under `personal/policies/` or a worker under `personal/workers/` — `master-sync.sh` will symlink them into `core/` on the next run.
- **`core/workers/registry.yaml` is now a generated artifact (#145).** It is produced from each `core/workers/**/worker.yaml` by `core/scripts/generate-workers-registry.sh` on every `master-sync` run. Do not hand-edit it. Hand edits will be flagged in review (the file has moved from `locked` to `reviewable` in `core/core.yaml`). To add or change a worker, edit the source `worker.yaml`; the registry regenerates on the next sync.

#### Hooks, policies, and session helpers

- **Local HQ autocommit (#139).** A new PostToolUse hook `.claude/hooks/hq-autocommit.sh` quietly autosaves edits made by Claude Code or Codex to HQ-tracked files, so the user does not see dirty HQ state. It deliberately skips `repos/`, embedded/symlinked knowledge repos, and repo-specific work; those keep normal commit discipline. The companion policy lives at `core/policies/hq-local-autocommit.md`.
- **Native session project capture.** Added `.claude/hooks/auto-session-project.sh`, `.claude/hooks/native-plan-project-sync.sh`, `core/scripts/session-project.sh`, and their tests. Session state is written under `.claude/state/`; project artifacts land under `personal/projects/` unless a company-scoped project is selected. Session identifiers are sanitized before becoming filenames.
- **Single-company auto-startwork.** Added `.claude/hooks/auto-startwork.sh` and tests. When the manifest has exactly one company, the session enters that company's context without prompting.
- **After-turn suggestion handling.** Added under `core/hooks/Stop/50-after-turn-suggestions.sh`. If you maintain custom lifecycle hook allowlists, add `core/hooks/Stop/` to the set of expected shipped hook paths.
- **Context-threshold checkpoint requirement (#129).** `.claude/hooks/context-warning-50.sh` prints a one-shot banner at ~50% of the context window, and `.claude/hooks/auto-checkpoint-precompact.sh` fires immediately before autocompact runs. When either banner appears, run `/checkpoint` immediately — it is a mandatory directive, not a user-choice prompt. Trigger table: `core/knowledge/public/hq-core/auto-checkpoint-spec.md`.
- **qmd-first HQ search policy (#131).** Added `core/policies/hq-qmd-first-for-hq-search.md`. Agents must use `qmd` for HQ search across content, indexed repos, projects, workers, policies, and knowledge, and only fall back to `Grep` or shell search when `qmd` is unavailable or the task is exact pattern matching in already-scoped code.

#### Codex parity and Cavebro

- **Cavebro output style bridged to Codex (#133).** `.codex/output-style.md` is now generated from the active Claude Code output style so Codex chat voice matches Claude Code. Coverage check: `bash core/scripts/codex-skill-bridge.sh status`.
- **Codex `run-project` phase orchestration fix (#130).** Phase boundaries are now respected when `run-project` is executed under Codex; workers no longer collapse multiple phases into a single invocation.

#### Updater and lock list

- **`update-hq` dispatch-script corruption fix (#128).** A bug that could brick a session by corrupting `.claude/scripts/*` during `/update-hq` was fixed. Recommended: run `/update-hq` once to land the fixed updater before the next major upgrade.
- **`companies/manifest.yaml` dropped from `locked` list.** It is no longer in `core/core.yaml`'s `locked` block; it is operator-owned and must be reviewable rather than locked. No action needed unless you wrote tooling that asserted on the old locked-path list.

#### Privacy gates

- **Public release privacy gates restored or widened.** Private tenant slug scan, `/Users/` absolute-path tripwire over `core/scripts`, and session-marker path hardening were re-applied.

### What does NOT need migrating

- No `.claude/settings.json` manual edits — all hook wiring ships in the updated `settings.json`.
- No backfill scripts to run.
- No company-level changes required.
- The commands→skills consolidation is transparent to slash invocations: `/<name>` continues to work; the source file just moved.

### References to update in local customizations

If you have local scripts, docs, bookmarks, or shortcuts outside the shipped HQ files, update these references:

| Old reference | New reference |
| --- | --- |
| `README.md` | `core/docs/hq/README.md` |
| `USER-GUIDE.md` | `core/docs/hq/USER-GUIDE.md` |
| `MIGRATION.md` | `core/docs/hq/MIGRATION.md` |
| `CHANGELOG.md` | `core/docs/hq/CHANGELOG.md` |
| `LICENSE` | `core/docs/hq/LICENSE` |
| `RELEASE-NOTES-v14.0.0.md` | `core/docs/hq/RELEASE-NOTES-v14.0.0.md` |
| `projects/` | `personal/projects/` |
| `core.yaml` | `core/core.yaml` |
| `.claude/commands/<name>.md` | `.claude/skills/<name>/SKILL.md` |
| `core/modules/modules.yaml` | (removed — migrate to a policy or worker) |
| Hand-edited `core/workers/registry.yaml` | Edit the source `core/workers/**/worker.yaml`; regenerate via `core/scripts/generate-workers-registry.sh` |

Also check for hardcoded root documentation paths in:

- local shell aliases
- editor bookmarks
- project READMEs
- sync conflict resolutions
- custom hooks or worker instructions
- dashboards that link into HQ docs

### Hook and runtime notes

No manual `.claude/settings.json` edits should be required. The updated settings file wires the shipped hooks.

The native-session helpers write session state under `.claude/state/` and project artifacts under `personal/projects/` unless a company-scoped project is selected. Session identifiers are sanitized before becoming filenames.

The after-turn suggestion hook lives at `core/hooks/Stop/50-after-turn-suggestions.sh`. If you maintain custom lifecycle hook allowlists, add `core/hooks/Stop/` to the set of expected shipped hook paths.

### Project and journal notes

Personal/HQ projects should now live under `personal/projects/`. If a stale root `projects/` directory reappears after sync, inspect it before deletion:

- If it only contains `.gitkeep`, delete it.
- If it contains real project folders, move them into `personal/projects/`.
- If it contains company work, move that work into the relevant `companies/{company}/projects/` directory instead.

Root `data/` is no longer a canonical journal/data location. Preserve any real local content before deleting it; otherwise remove the stale directory.

### Sync and multi-machine cleanup

This migration matters for HQ Sync because a file move can look like "delete old path + add new path" to a second machine that has not yet received the same cleanup. The safe sequence is:

1. Update one machine and let it commit the moved paths plus deletions.
2. Run HQ Sync from that machine so the cloud receives the new layout.
3. Run HQ Sync on the other machine. If stale root files reappear as conflicts, keep the cleaned layout and archive/delete the legacy root copies.

If `/update-hq` cannot remove stale root paths automatically, run this from the HQ root after confirming no personal content lives there:

```bash
rm -rf data projects
rm -f CHANGELOG.md CONTRIBUTING.md GEMINI.md INDEX.md LICENSE MIGRATION.md README.md RELEASE-NOTES-v14.0.0.md USER-GUIDE.md core.yaml setup.sh
```

Do not remove `AGENTS.md`, `.claude/`, `.agents/`, `.codex/`, `companies/`, `core/`, `personal/`, `repos/`, or `workspace/`.

### Verification

After `/update-hq` and any sync cleanup, run these checks from the HQ root:

```bash
# Shipped-doc moves
test -f core/docs/hq/README.md
test -f core/docs/hq/MIGRATION.md
test -f core/core.yaml
test -d personal/projects
test -L MIGRATION.md                 # root symlink points at core/docs/hq/MIGRATION.md
test -L AGENTS.md                    # root symlink points at .claude/CLAUDE.md
[ "$(readlink AGENTS.md)" = ".claude/CLAUDE.md" ] || echo "AGENTS.md symlink target unexpected" >&2
test ! -e USER-GUIDE.md
test ! -e projects/.gitkeep
test ! -e data                       # root data/ moved to personal/data/

# Commands and modules consolidation
test ! -d .claude/commands           # commands consolidated into skills
test ! -e core/modules/modules.yaml  # modules system removed

# New shipped artifacts
test -x core/scripts/generate-workers-registry.sh
test -f core/policies/hq-local-autocommit.md
test -f core/policies/hq-qmd-first-for-hq-search.md
test -f .codex/output-style.md
```

If any `test ! -e ...` command fails, inspect the path before deleting it. Keep real local content; remove only stale shipped placeholders or moved documentation copies.

---

## Migrating to v14.1.0 — 2026-05-13

### TL;DR

**No manual migration required.** `/update-hq` pulls all new files and you're done. This release promotes beta.1 to stable with additional commands, skills, and a major policy cleanup.

### What changed since v14.1.0-beta.1

- **6 new commands** — `accept`, `decision-queue`, `hq-share`, `journal`, `onboard`, `promote`. All wired in `.claude/settings.json` already.
- **4 new hooks** — `block-unsafe-package-install.sh` (supply-chain safety), `journal-due.sh`, `journal-precompact.sh`, `load-journal-index-on-start.sh`. Already wired.
- **13 Codex skill bridges** — New `SKILL.md` + `agents/openai.yaml` for `accept`, `adr`, `architect`, `calibration-report`, `decision-queue`, `diagnose`, `finish-estimate`, `hq-bug`, `hq-share`, `onboard`, `out-of-scope`, `promote`, `track-estimate`.
- **Session journal system** — `session-journal.sh` script, `session-journal-spec.md` knowledge doc, and 3 lifecycle hooks.
- **`quiet-by-default-narration.md` policy** — Silences routine ops (install, lint, build, test, fmt).
- **Product description reframed** — "personal OS" → "team AI OS" across CLAUDE.md and core docs.
- **`companies/personal/` removed** — Personal namespace moved to root `personal/`.
- **165 policies removed** — Public policy set slimmed to ~35 core guardrails. If you had custom references to removed policy filenames, update them.
- **`manifest.yaml` format fix** — Block YAML form prevents `HQ_INDIGO_MCP=1` append from corrupting inline flow.
- **Codex pets** — Indigo Gem mascot at `.codex/pets/indigo-gem/`.

### What does NOT need migrating

- No `.claude/settings.json` manual edits — all hook wiring ships in the updated settings.json.
- No backfill scripts to run.
- No company-level changes required.
- The 165 removed policies were all session-scoped or overly specific — core guardrails are retained.

### Compatibility

- All changes are additive over beta.1. Existing HQ installations on beta.1 or v14.0.x continue to work without modification.
- The personal namespace move is transparent — `personal/` at root replaces `companies/personal/`.
- Codex skill bridges are purely additive — no behavior change for Claude Code users.

---

## Migrating to v14.1.0-beta.1 — 2026-05-12

### TL;DR

**No manual migration required.** `/update-hq` pulls all new files and you're done. The `scripts/` → `core/scripts/` relocation is handled transparently — existing references in CLAUDE.md and hook-gate already point to the new paths.

### What changed

- **Scripts relocated** from root `scripts/` to `core/scripts/`. All internal references (CLAUDE.md, hooks, codex bridge) already point to `core/scripts/`. If you have custom hooks or scripts referencing `scripts/compute-checksums.sh` or similar, update the path to `core/scripts/compute-checksums.sh`.
- **27 new policies** added to `core/policies/`. Auto-loaded by SessionStart — no settings.json edits needed.
- **Journal subsystem** — New shared skill at `.claude/skills/_shared/journal.sh`, auto-capture hook at `.claude/hooks/journal-autocapture.sh`, and spec at `core/knowledge/public/hq-core/journal-spec.md`. All wired in `.claude/settings.json` already.
- **Core-write protection** — Two new hooks (`block-core-writes.sh`, `block-core-writes-bash.sh`) prevent direct edits to `core/`. Already wired in settings.json.
- **Precompact thrashing detector** — New hook at `.claude/hooks/precompact-thrashing-detector.sh`. Already wired.
- **Context warning threshold** — Lowered from 60% to 50%. File renamed from `context-warning-60.sh` to `context-warning-50.sh`. Already wired.
- **Personal pack scaffold** — New `personal/` directory with empty `.gitkeep` stubs. No action needed.
- **Obsidian config** — `.obsidian/` directory added. Ignored by git if not using Obsidian.
- **8 INDEX rebuild scripts** — New scripts at `core/scripts/rebuild-*.sh`. Available immediately.
- **Paper designer worker** — New worker added to `core/workers/public/dev-team/`.

### What does NOT need migrating

- No `.claude/settings.json` manual edits — all hook wiring ships in the updated settings.json.
- No backfill scripts to run.
- No company-level changes required.
- Existing custom scripts referencing `scripts/` paths will still work if you haven't overridden `core/scripts/` — but update references when convenient.

### Compatibility

- All changes are additive. Existing HQ installations continue to work without modification.
- The `personal/` directory is new scaffold — it contains only `.gitkeep` files and imposes no behavior until populated.
- Obsidian config (`.obsidian/`) is optional — users without Obsidian can safely ignore or delete it.

---

## Migrating to v14.0.1 — 2026-05-11

### TL;DR

**No manual migration required.** `/update-hq` pulls four files and you're done. Verify the new `journal.sh attach` verb works with a quick smoke test if you want.

### What changed

- **New hard-enforcement policy** at `core/policies/journal-project-scoped-writes.md`. Auto-loaded by SessionStart for `brainstorm`, `deep-plan`, `prd`, `plan`, `startwork`, `handoff`, `checkpoint`.
- **New `attach` subcommand** in `.claude/skills/_shared/journal.sh`. Existing `open`/`append`/`close`/`path` verbs are unchanged — `attach` is additive.
- **Overflow spill** in `.claude/hooks/journal-autocapture.sh`. Triggered when an Agent result, WebFetch body, or WebSearch payload exceeds 1024 bytes. Previously these were truncated to ~200 chars and the rest was lost; now the full content lives at `{project_dir}/journal/attachments/{ts}-{tool}-{hash6}.txt` and the inline digest references it via a `(full: ...)` suffix.
- **Spec update** at `core/knowledge/public/hq-core/journal-spec.md` documents the new `## Reference material` section.

### Smoke test (optional, ~30 seconds)

If you want to confirm the helper roundtrips correctly after pulling:

```bash
# Inside a project dir with an active journal:
echo "scratch content for verification" | \
  .claude/skills/_shared/journal.sh attach research --ext md

# Expected output: absolute path to the new file.
ls research/                # should contain {ts}-research-{hash6}.md
grep -A1 'Findings' journal/*-*.md | tail -3
                            # should show a "- {iso} attached: research/..." bullet
```

### What does NOT need migrating

- No `.claude/settings.json` edits.
- No backfill — historical journals continue to work; the new `attach` verb and overflow spill only affect captures going forward.
- No changes to the seven calling skills (`brainstorm`, `deep-plan`, `prd`, `plan`, `startwork`, `handoff`, `checkpoint`) — they pick up the new behavior transparently when they invoke `journal.sh`.

### Compatibility

- `journal.sh` retains its fail-soft contract: malformed inputs print one-line warnings to stderr and exit 0 — the journal subsystem will never block a calling skill.
- The runtime pointer at `.claude/state/active-journal` remains the only journal artifact outside `{project_dir}/`, and the new policy explicitly exempts it (it's a session-runtime pointer, not journal content).

---

## Migrating to v12.4.0 — 2026-05-02

### Headline

Two manual steps after `/update-hq` lands the new files: wire the mirror hook into `.claude/settings.json`, then run the backfill script once. About 60 seconds total.

### What changed

- **Per-company workspace mirror is live.** A new PostToolUse(Write|Edit) hook automatically hardlinks each `workspace/threads/T-*.json` into `companies/{co}/workspace/sessions/{thread-id}.json` and appends a row to `companies/{co}/workspace/index.jsonl` whenever the thread file has `metadata.company`. Threads with no `metadata.company` (HQ-infra-only sessions) are silently skipped.
- **Canonical session store unchanged.** `workspace/threads/` remains the source of truth. The mirror is purely additive — hardlinks share inodes with the canonical thread file, so disk overhead is zero.
- **Auto-checkpoint exclusion extended** to skip `companies/*/workspace/(sessions/|index.jsonl|.gitignore)` writes — prevents the mirror from triggering its own checkpoint loop.

### Step 1 — Wire the hook in `.claude/settings.json`

Add this single hook entry to **both** the `PostToolUse` `Write` and `PostToolUse` `Edit` matcher blocks in `.claude/settings.json`:

```json
{ "type": "command", "command": ".claude/hooks/hook-gate.sh mirror-thread-to-company .claude/hooks/mirror-thread-to-company.sh", "timeout": 5 }
```

Append it to the `hooks` array of each existing block — do **not** replace what's already there. After the edit, each block should look like:

```json
{
  "matcher": "Write",
  "hooks": [
    { "type": "command", "command": ".claude/hooks/hook-gate.sh auto-checkpoint-trigger .claude/hooks/auto-checkpoint-trigger.sh", "timeout": 5 },
    { "type": "command", "command": ".claude/hooks/hook-gate.sh mirror-thread-to-company .claude/hooks/mirror-thread-to-company.sh", "timeout": 5 }
  ]
}
```

(The same shape applies to the `"matcher": "Edit"` block.)

If you have no `PostToolUse` hooks configured at all (rare — a harness-audit warning), create both `Write` and `Edit` blocks using the shape above with just the `mirror-thread-to-company` entry as the only hook in the array. You can omit the `auto-checkpoint-trigger` line if you don't already have it configured elsewhere.

### Step 2 — Backfill existing threads

After updating, run the one-time backfill so historical sessions appear inside their companies:

```bash
bash core/scripts/backfill-workspace-mirror.sh
```

The script is idempotent — safe to re-run if interrupted. It only mirrors threads that have `metadata.company` set; threads without it are correctly skipped (HQ-infra sessions). Expect output similar to:

```
Backfill complete:
  Total threads:   {N}
  Mirrored:        {M}
  Skipped (no co): {N-M}
```

### Step 3 — (Optional) Verify

```bash
ls -d companies/*/workspace 2>/dev/null
wc -l companies/*/workspace/index.jsonl 2>/dev/null
```

Each company you have ever logged work for should now have its own `workspace/` directory with an `index.jsonl` audit log and a `sessions/` directory of hardlinked thread snapshots.

### Cloud durability

If you sync via `/hq-sync` or the AppBar HQ Sync menubar, the new `companies/{co}/workspace/` paths are picked up automatically — the existing `@indigoai-us/hq-cloud` sync layer is permissive by default (gitignore-style deny list) and `workspace/` is not in any default-ignored pattern. No server-side change required.

### Conflict semantics for `index.jsonl`

`index.jsonl` is append-only. If the same thread updates from two machines while offline, both sides may have rows the other lacks. Standard `hq-sync --on-conflict keep` will produce a `.conflict-*` sidecar handled by `/resolve-conflicts`. The dedup tuple is `(thread_id, ts, kind)` — manual reconciliation should union both sides, not pick a winner.

---

## Migrating to v12.3.0 — 2026-05-02

### Headline

No migration steps required — all changes are backward-compatible.

### What changed

- **Codex policy + hook bridges** are additive — they install symlinks/adapters in `.codex/` without touching anything in `.claude/`. Operators who use Claude Code only see no change.
- **`/deploy` Phase A speed refactor** keeps the same external interface; only internal sub-agent fan-out was replaced with inline parallel scripts.
- **`CLAUDE.md` charter restructure + `AGENTS.md` symlink** preserve all instruction content. The symlink unifies Claude + Codex on the same source. Operators who customized `AGENTS.md` directly should reapply their customizations to `.claude/CLAUDE.md` (the symlink target) — note that `AGENTS.md` is now a regular symlink and writes go through to `CLAUDE.md`.
- **Policy enforcement rebalance** moves ~140 policies from `hard` to `soft`. Soft-enforcement policies note deviations rather than blocking. If your workflows depended on a specific policy blocking on violation, check `core/policies/_digest.md` and re-promote any that you want to remain hard via `/learn --hard`.

### Optional: pick up the new commands

Three new slash commands ship with v12.3.0. They auto-register on next session start. If you want a quick tour:

- `/discover <repo-url-or-path>` — pull a repo into HQ and synthesize knowledge
- `/land-batch` — triage and merge multiple open PRs
- `/sync-registry [company]` — regenerate a company's resource-registry index

### Optional: enable Codex bridges

If you use OpenAI Codex alongside Claude Code:

```bash
bash core/scripts/codex-skill-bridge.sh install            # symlinks .claude/skills → .codex/, .agents/
bash core/scripts/codex-skill-bridge.sh install-policies   # NEW in v12.3.0 — symlinks core/policies/
```

The hook bridge (`.codex/hooks/hq-codex-hook-adapter.sh`) is install-time only — no runtime opt-in needed once the file is present. Codex sessions automatically route hooks through the existing `hook-gate.sh`.

## Migrating to v12.2.0 — 2026-04-30

### Headline

Codex parity. Existing Claude Code users on v12.1.x can stay where they are — nothing breaks. Operators who also want to invoke HQ from OpenAI Codex run one command and gain a parallel Codex entrypoint tree.

Fully additive. No breaking changes. No file deletions. No policy enforcement weakened.

### New Files (added at HQ root)

- `AGENTS.md` — Codex orientation doc (mirrors `CLAUDE.md` for Claude Code).
- `.codex/config.toml` — Codex sandbox + model settings.
- `.codex/claude` — symlink to `.claude/`.
- `.codex/prompts` — symlink to `.claude/commands/`.
- `.agents/skills` — symlink to `.claude/skills/`.

### New Commands

- `/convert-codex` — One-command repair for older Claude-first HQ roots. Dry-run by default. Adds the new entrypoints listed above plus missing `agents/openai.yaml` metadata for shipped skills.

### New Skills (Codex adapters)

18 new `SKILL.md` adapters in `.claude/skills/{name}/`, each pointing back to its sibling `.claude/commands/{name}.md` as source of truth. Plus 30 new `agents/openai.yaml` metadata files. No duplication of command bodies — adapters delegate.

### Changed Files

- 4 policy files have path renames (`repos/public/hq/template/` → `repos/private/hq-core-staging/`). Enforcement unchanged.
- `_digest.md` regenerated.
- `core/core.yaml` version + checksums updated.

### Migration Steps

**For Claude Code-only users:** No action required. Update HQ via `hq update` (or your usual flow) when convenient. Nothing in your day-to-day Claude Code workflow changes.

**For users who also want Codex:**
```bash
cd <your HQ root>
bash core/scripts/convert-codex.sh --dry-run   # preview
bash core/scripts/convert-codex.sh --apply     # add Codex entrypoints
```

The script is create-only. It will skip any path that already exists and report blocked items so you can review before approving more invasive changes.

### Companion package upgrades

None. `@indigoai-us/hq-cli` and `@indigoai-us/hq-cloud` are unaffected.

---

## Migrating to v12.1.1 — 2026-04-29

### Headline

Hotfix that finishes the dev→prod Cognito cutover. Two file-level changes to existing operators' HQ trees, plus one new global policy. Fully additive on top of v12.1.0 — no breaking changes.

### Changed Commands

- `.claude/commands/designate-team.md` — env-echo default flipped from `hq-vault-dev` to `vault-indigo-hq-prod` (single-line change, line 119). Behavior of `hq cloud provision company` is unchanged; only the on-screen sanity-check banner now reflects the canonical post-cutover pool.

### New Policies

- `core/policies/prefer-systemic-fix-over-user-bandaid.md` — hard, global. New rule: bug fixes ship as systemic patches, not per-user env exports. See CHANGELOG for the banned/required framings.

### Companion package upgrades (recommended same-day)

- `@indigoai-us/hq-cloud@5.9.0` — adds stale-pool detection so pre-cutover dev tokens stop producing 401s against the prod vault API. No action required from operators; cached tokens with mismatched `client_id` claim are silently re-authed on next CLI invocation.
- `@indigoai-us/hq-cli@5.7.1` — `bun install -g @indigoai-us/hq-cli@5.7.1` to pick up hq-cloud@5.9.0.
- `create-hq@10.12.0` — only matters for new HQs created after 2026-04-29; existing HQs are unaffected.

### Verification

- `cat .claude/commands/designate-team.md | grep "Cognito domain"` should print no `hq-vault-dev` substring.
- `ls core/policies/prefer-systemic-fix-over-user-bandaid.md` should exist after `/update-hq`.
- `bash core/scripts/build-policy-digest.sh` regenerates `core/policies/_digest.md` with 105+ policies, hard-enforcement section now contains a `prefer-systemic-fix-over-user-bandaid` line.

---

## Migrating to v12.1.0 — 2026-04-28

### Headline

Iteration release on top of the v12.0.0 hq-core split. All changes are additive — new commands, a new skill, a `/plan` refactor that splits the heavy interview path into a separate `/deep-plan`, and a batch of new policies that consolidate scattered git/bash/vercel rules into discipline-pack policies. No locked-file structural changes; existing HQ instances upgrade cleanly with no breaking changes.

### New Commands

- `.claude/commands/deep-plan.md`
- `.claude/commands/designate-team.md`
- `.claude/commands/hq-login.md`
- `.claude/commands/hq-logout.md`
- `.claude/commands/hq-sync.md`
- `.claude/commands/hq-whoami.md`
- `.claude/commands/import-claude.md`
- `.claude/commands/resolve-conflicts.md`

### New Skills

- `.claude/skills/deep-plan/`
- `.claude/skills/designate-team/`
- `.claude/skills/hq-login/`
- `.claude/skills/hq-logout/`
- `.claude/skills/hq-secrets/`
- `.claude/skills/hq-whoami/`
- `.claude/skills/import-claude/`

### New File

- `.claude/stack.yaml`
- `core/policies/hq-bash-discipline.md`
- `core/policies/hq-bash-no-gnu-coreutils-date-timeout.md`
- `core/policies/hq-classifier-own-labels-single-source.md`
- `core/policies/hq-cli-version-read-from-package-json.md`
- `core/policies/hq-cmd-handoff-no-discovery-rerun.md`
- `core/policies/hq-cmd-publish-kit-python-yaml-free.md`
- `core/policies/hq-cmd-publish-kit-rerun-diff-on-scope-narrow.md`
- `core/policies/hq-cmd-run-project-ralph-hard-pause-procedure.md`
- `core/policies/hq-cmd-stage-kit-settings-json-direct-edit.md`
- `core/policies/hq-compiled-ts-rebuild-after-src-edits.md`
- `core/policies/hq-cross-repo-privilege-tier-surface-scope.md`
- `core/policies/hq-destructive-scripts-default-dry-run.md`
- `core/policies/hq-git-diff-three-dot-for-pr-review.md`
- `core/policies/hq-git-discipline.md`
- `core/policies/hq-git-large-diff-audit-before-panic.md`
- `core/policies/hq-git-merge-ff-only-trunk.md`
- `core/policies/hq-git-squash-merge-branch-ahead-expected.md`
- `core/policies/hq-git-staged-deletion-verify-blob-before-reset.md`
- `core/policies/hq-github-app-over-pat-for-bot-repo-creation.md`
- `core/policies/hq-migration-independent-grep-verify.md`
- `core/policies/hq-nextjs-host-redirect-requires-domain-attachment.md`
- `core/policies/hq-no-parent-import-from-child-component.md`
- `core/policies/hq-nodejs-promisify-scrypt-options-wrap-manual.md`
- `core/policies/hq-oidc-access-denied-diagnose-via-cloudtrail.md`
- `core/policies/hq-oidc-migration-plan-both-subject-shapes.md`
- `core/policies/hq-orthogonal-filters-over-overlapping-presets.md`
- `core/policies/hq-plan-combined-story-edit-locality.md`
- `core/policies/hq-prd-verify-passes-vs-artifact-registry.md`
- `core/policies/hq-pre-push-gate-probes-prod-not-localhost.md`
- `core/policies/hq-publish-pipeline-two-stop.md`
- `core/policies/hq-session-resume-git-status-reverify.md`
- `core/policies/hq-settings-local-for-personal-allows.md`
- `core/policies/hq-slack-verify-scopes-beyond-auth-test.md`
- `core/policies/hq-static-regression-anchor-forbidden-pattern.md`
- `core/policies/hq-vercel-discipline.md`
- `core/policies/hq-vercel-wildcard-single-subdomain-level.md`
- `core/policies/hq-zsh-status-readonly-loop-var.md`
- `core/policies/no-headless-browser-in-vercel-lambda.md`
- `core/policies/no-relative-symlinks-from-worktree.md`
- `core/policies/no-shared-skill-extraction-touching-5-files.md`
- `core/policies/publish-kit-source-is-strict-allowlist.md`

### Updated Files

- `.claude/CLAUDE.md`
- `.claude/commands/plan.md`
- `.claude/commands/update-hq.md`
- `.claude/hooks/load-policies-for-session.sh`
- `core/policies/_digest.md`
- `core/policies/ascii-art-character-verify.md`
- `core/policies/blog-post-x-draft.md`
- `core/policies/deconflict-postbridge-schedule.md`
- `core/policies/distributed-join-partial-failure-diagnosis.md`
- `core/policies/dual-codex-review-pattern.md`
- `core/policies/dual-repo-prd-routing.md`
- `core/policies/email-humanize.md`
- `core/policies/git-stash-build-artifacts-conflict.md`
- `core/policies/hq-cmd-handoff-must-complete.md`
- `core/policies/hq-cmd-run-project-pid-tracking.md`
- `core/policies/hq-cmd-run-project-process-cleanup.md`
- `core/policies/hq-figma-token-account-scope.md`
- `core/policies/hq-nested-repo-git-status-check.md`
- `core/policies/hq-permissions-fan-out-edit-write-multiedit.md`
- `core/policies/hq-swarm-pr-branch.md`
- `core/policies/hq-swarm-rust-hub-files.md`
- `core/policies/hq-tmux-plan-approval-dance.md`
- `core/policies/idb-install.md`
- `core/policies/linear-scan-check-existing-prds.md`
- `core/policies/no-threaded-posts.md`
- `core/policies/npm-subpackage-hydration.md`
- `core/policies/og-image-twitter-cache.md`
- `core/policies/orchestrator-competing-processes.md`
- `core/policies/orchestrator-lockfile-sync.md`
- `core/policies/post-bridge-media-upload.md`
- `core/policies/post-bridge-media-workflow.md`
- `core/policies/post-bridge-unicode-payload.md`
- `core/policies/prd-content-sources.md`
- `core/policies/prd-files-match-acs-for-swarm.md`
- `core/policies/prd-json-schema.md`
- `core/policies/prd-json-validation-post-task.md`
- `core/policies/prd-no-execute.md`
- `core/policies/prd-no-implement.md`
- `core/policies/prd-story-sizing.md`
- `core/policies/prd-userstories-key.md`
- `core/policies/preview-start-launch-registry-is-global.md`
- `core/policies/regression-gate-lint-fix.md`
- `core/policies/reskin-separate-orchestration-from-visual.md`
- `core/policies/run-project-conflict-marker-guard.md`
- `core/policies/run-project-dry-run-branch-leak.md`
- `core/policies/run-project-file-locks-stale.md`
- `core/policies/run-project-local-keyword.md`
- `core/policies/run-project-monitor-spawn-keystroke-race.md`
- `core/policies/run-project-name-matches-dir.md`
- `core/policies/run-project-no-permissions-required.md`
- `core/policies/run-project-progress-txt-no-commit-misleading.md`
- `core/policies/run-project-repo-bootstrap.md`
- `core/policies/run-project-sigkill-retry.md`
- `core/policies/run-project-swarm-branch-validation.md`
- `core/policies/run-project-swarm-merge-conflict-tombstone.md`
- `core/policies/run-project-verification-story-false-negative.md`
- `core/policies/run-project-worktree-heal-orphan.md`
- `core/policies/session-data-for-product-accuracy.md`
- `core/policies/swarm-orphan-recovery.md`
- `core/policies/swarm-post-execution-review.md`
- `core/policies/vercel-domain-transfer-reissues-verification.md`
- `core/policies/verify-routes-after-parallel-execution.md`
- `.claude/skills/plan/SKILL.md`
- `CHANGELOG.md`
- `MIGRATION.md`
- `README.md`
- `core/core.yaml`

### Removed

- `core/policies/git-add-explicit-paths-no-drift.md`
- `core/policies/git-branch-verify.md`

_Both removed policies had their rules consolidated into `core/policies/hq-git-discipline.md` (in the New File list above)._

### Migration Steps

After update, the new commands become available immediately:

- **Identity:** `/hq-login`, `/hq-logout`, `/hq-whoami`
- **Sync:** `/hq-sync`, `/resolve-conflicts`
- **Onboarding / planning:** `/import-claude`, `/deep-plan`
- **Team provisioning:** `/designate-team`

The `hq-secrets` skill auto-loads on next session start; the new `## Secrets` block in `.claude/CLAUDE.md` is offered via section-level merge.

`/plan` is now lightweight; the previous heavy interview + research path moved to `/deep-plan`. Existing call sites continue to work — choose the depth that fits.

### Optional `hq` CLI dependency

`/designate-team` and `/hq-sync` delegate to the `@indigoai-us/hq-cli` binary (`hq …`). If you don't already have it on `PATH`:

```bash
npm install -g @indigoai-us/hq-cli
hq whoami    # verify
```

If the binary is missing, both commands surface a clear error pointing at install instructions — no silent fallback.

### Breaking Changes

None.

---

# Migration — v11.x → v12.0.0

## What changed

The HQ scaffold seed split off into its own repository: `indigoai-us/hq-core`. The monorepo at `indigoai-us/hq` stays alive as the home of the publish pipeline, `create-hq`, `hq-cli`, and `hq-pack-*` package sources. `indigoai-us/hq-core` is the canonical scaffold source-of-truth starting with v12.0.0.

Rich content that previously shipped inline with the template moved to four opt-in npm packages:

| Removed from hq-core | New home |
|---|---|
| `core/knowledge/public/design-styles/` | `@indigoai-us/hq-pack-design-styles` |
| `core/knowledge/public/design-quality/` | `@indigoai-us/hq-pack-design-quality` |
| `core/knowledge/public/gemini-cli/` + 6 `core/workers/public/gemini-*/` | `@indigoai-us/hq-pack-gemini` |
| `core/workers/public/gstack-team/` + `core/scripts/gstack-bridge.sh` | `@indigoai-us/hq-pack-gstack` |
| `core/workers/public/impeccable-designer/` (deprecated) | — use `dev-team/frontend-dev` + `hq-pack-design-styles` |
| `core/workers/public/sample-worker/`, `core/knowledge/public/impeccable/` | — deleted |

## Upgrading an existing HQ instance

### Fresh install
```bash
npx create-hq my-hq          # prompts to install recommended packs
npx create-hq my-hq --full   # installs all recommended packs unconditionally
npx create-hq my-hq --minimal # skip the pack prompt
```

### Existing v11.x instance
```bash
cd ~/Documents/HQ    # or wherever your HQ lives
/update-hq           # pulls latest hq-core; upgrades packs; prompts for any newly-recommended packs
```

`/update-hq` is non-destructive: pack install failures surface as warnings, not fatal errors. Re-run `/setup --resume` to retry.

### Manual reinstall of a specific pack
```bash
hq install @indigoai-us/hq-pack-gstack                      # npm
hq install https://github.com/{org}/pack-foo#{commit-sha}   # git (pins to SHA)
hq install ./local-pack                                     # local path
```

## Compatibility notes

- **Hooks shipped by a pack** (`contributes.hooks`) auto-run on tool events. `hq install` surfaces this and prompts for confirmation — or pass `--allow-hooks` for non-interactive installs.
- **Publish pipeline** (`/publish-kit`, `/stage-kit`) retargeted from `repos/public/hq/template/` to `repos/public/hq-core/` as part of the split. Same commands, new target.

## Migrating to 11.2.0 — 2026-04-18

**Non-breaking for HQ consumers.** The only behavior changes land in publish-kit itself: the release walker is now a strict allowlist, and the publish target is rebuilt from scratch on every full release. No action required for anyone consuming the template.

If you maintain a downstream publish-kit or a fork that mirrors HQ, read below.

### Step 1 — Review the new allowlist

The walker now refuses to emit anything outside `core/policies/publish-kit-source-is-strict-allowlist.md` (ALLOW_ROOTS, REMAPS, STARTER_SCAFFOLDS, NEVER_TRAVERSE). If your fork publishes paths that aren't on the allowlist, add them to the policy and the walker explicitly — silent drift is no longer possible.

### Step 2 — Expect deletions on first 11.2.0 publish

Because the target is now rebuilt from scratch (Stage R = `rm -rf template/`), the first 11.2.0 publish will register as a very large diff against the prior release: every file that was leaked by earlier permissive walks (owner-private commands, deprecated skills, company-scoped policies, private knowledge) is removed. This is expected and not a regression — it is the root-cause fix for the leak class.

### Step 3 — `Stage R` semantics

On every full release:
1. **Stage R — Rebuild Target:** `rm -rf template/` then `mkdir -p template/`.
2. **Stage E — Emit:** walk the allowlist and write each file into the empty `template/`.

Incremental publishes (single-file corrections) still bypass Stage R. The assertion in Step 0.5 of `.claude/commands/publish-kit.md` is the gate.

### Step 4 — `/prd` is now `/plan`

The `prd/` skill was renamed to `plan/`, and the command `/prd` was removed. Update any muscle memory, CI hooks, or prompt templates: use `/plan`.

---

# Migration Guide

Instructions for updating existing HQ installations to new versions.

---

## Migrating to v11.1.0 (from v11.0.0)

### Headline

qmd sub-collection refactor + design system knowledge sync. Non-breaking — run `core/scripts/setup.sh` to create new collections.

### Step 1 — Re-run core/scripts/setup.sh for qmd sub-collections

The monolithic `hq` qmd collection is now split into 4 focused collections. Re-run setup to create them:

```bash
bash core/scripts/setup.sh
```

This creates `hq-infra`, `hq-workers`, `hq-knowledge`, and `hq-projects` collections with scoped include paths. Your existing `hq` collection is not removed — you can delete it manually with `qmd collection remove hq` if desired.

### Step 2 — Rename `.impeccable.md` → `design.md` (if applicable)

If any of your repos have an `.impeccable.md` file, rename it:

```bash
# In each repo that has one:
mv .impeccable.md design.md
```

The `style:` field is now `style-pack:` in the Design Direction section. Workers auto-resolve via `core/knowledge/design-styles/registry.yaml`.

### Step 3 — Verify knowledge bases synced

New knowledge bases were added. Verify they exist:

```bash
ls core/knowledge/design-styles/registry.yaml
ls core/knowledge/design-quality/
ls core/knowledge/hq-core/design-md-spec.md
ls core/knowledge/hq-core/insights-spec.md
```

### Step 4 — (Optional) Clean removed policies

Seven company-specific policies were removed. If you added custom rules to any of these files, back them up first. Otherwise they should already be gone from the update:

- `hq-paper-mcp-sequential-agents.md`
- `hq-slack-channel-indigo-workspace.md`
- `indigo-hq-app-release.md`
- `indigo-signals-mcp-queries.md`
- `paper-flex-column-reorder.md`
- `paper-text-width.md`
- `paper-text-wrapping.md`

---

## Migrating to v10.8.0 (from v10.7.1)

### Headline

Design worker consolidation: 6 design workers → 2 (`frontend-designer` + `ux-auditor`). Style pack system. Configurable models.

### Step 1 — Create ux-auditor and move audit skills

```bash
mkdir -p core/workers/ux-auditor/skills
# From impeccable-designer (directory-based)
for skill in audit critique harden normalize; do
  mv "core/workers/impeccable-designer/skills/$skill" "core/workers/ux-auditor/skills/$skill"
done
# From gemini-ux-auditor (flat files)
for skill in ux-audit.md flow-review.md copy-review.md competitive-scan.md; do
  mv "core/workers/gemini-ux-auditor/skills/$skill" "core/workers/ux-auditor/skills/$skill"
done
# From gemini-designer (flat files)
for skill in design-audit.md design-system-check.md visual-diff.md; do
  mv "core/workers/gemini-designer/skills/$skill" "core/workers/ux-auditor/skills/$skill"
done
```

### Step 2 — Move build/refine skills to frontend-designer

```bash
mkdir -p core/workers/frontend-designer/skills
# From impeccable-designer (18 directory-based skills)
for skill in adapt animate arrange bolder clarify colorize consolidate delight distill extract frontend-design onboard optimize overdrive polish quieter teach-impeccable typeset; do
  mv "core/workers/impeccable-designer/skills/$skill" "core/workers/frontend-designer/skills/$skill"
done
# From gemini-stylist (4 flat files)
for skill in add-animation.md responsive-polish.md dark-mode.md css-refactor.md; do
  mv "core/workers/gemini-stylist/skills/$skill" "core/workers/frontend-designer/skills/$skill"
done
# From gemini-frontend (4 flat files)
for skill in build-component.md style-component.md responsive-check.md a11y-audit.md; do
  mv "core/workers/gemini-frontend/skills/$skill" "core/workers/frontend-designer/skills/$skill"
done
# From gemini-designer (1 flat file)
mv "core/workers/gemini-designer/skills/design-tokens.md" "core/workers/frontend-designer/skills/design-tokens.md"
```

### Step 3 — Copy new worker.yamls

Copy `core/workers/frontend-designer/worker.yaml` and `core/workers/ux-auditor/worker.yaml` from the release. These contain the merged skill blocks, instructions, and model configuration.

### Step 4 — Delete absorbed workers

```bash
rm -rf core/workers/impeccable-designer/
rm -rf core/workers/gemini-designer/
rm -rf core/workers/gemini-stylist/
rm -rf core/workers/gemini-frontend/
rm -rf core/workers/gemini-ux-auditor/
```

### Step 5 — Update registry.yaml

- Remove entries for: impeccable-designer, gemini-designer, gemini-stylist, gemini-frontend, gemini-ux-auditor
- Add entry for: ux-auditor
- Update frontend-designer description
- Update Standalone Workers count (11→9) and Gemini Team count (6→2)
- Bump version to 10.8.0

### Step 6 — Update invocations

Old commands → new equivalents:

| Old | New |
|-----|-----|
| `/run impeccable-designer audit` | `/run ux-auditor audit` |
| `/run impeccable-designer critique` | `/run ux-auditor critique` |
| `/run impeccable-designer harden` | `/run ux-auditor harden` |
| `/run impeccable-designer normalize` | `/run ux-auditor normalize` |
| `/run impeccable-designer {any other skill}` | `/run frontend-designer {skill}` |
| `/run gemini-stylist {skill}` | `/run frontend-designer {skill}` |
| `/run gemini-frontend {skill}` | `/run frontend-designer {skill}` |
| `/run gemini-designer design-tokens` | `/run frontend-designer design-tokens` |
| `/run gemini-designer {audit skills}` | `/run ux-auditor {skill}` |
| `/run gemini-ux-auditor {skill}` | `/run ux-auditor {skill}` |

### Step 7 — (Optional) Add style to .impeccable.md

If your project has an `.impeccable.md`, add a `style:` field to enable automatic style pack loading:

```markdown
## Style
style: american-industrial
```

Or re-run `teach-impeccable` to go through the style selection flow.

### Step 8 — Verify

```bash
ls core/workers/frontend-designer/skills/ | wc -l  # 27
ls core/workers/ux-auditor/skills/ | wc -l          # 11
# Ensure no stale references
grep -r "impeccable-designer\|gemini-designer\|gemini-stylist\|gemini-frontend\|gemini-ux-auditor" core/workers/ --include="*.yaml" | grep -v CHANGELOG
```

---

## Migrating to v10.7.1 (from v10.7.0)

### Headline

Core cleanup — 22 design skills moved from `.claude/skills/` to `core/workers/impeccable-designer/skills/`, 2 niche commands removed, `social-graphic` moved to `social-strategist`.

### Step 1 — Remove deleted commands

```bash
rm -f .claude/commands/pr.md .claude/commands/hq-growth-dashboard.md
```

### Step 2 — Move design skills to impeccable-designer

```bash
mkdir -p core/workers/impeccable-designer/skills
for skill in adapt animate arrange audit bolder clarify colorize consolidate critique delight distill extract frontend-design harden normalize onboard optimize overdrive polish quieter teach-impeccable typeset; do
  mv ".claude/skills/$skill" "core/workers/impeccable-designer/skills/$skill"
done
```

### Step 3 — Move social-graphic to social-strategist

```bash
mkdir -p core/workers/social-strategist/skills
mv .claude/skills/social-graphic core/workers/social-strategist/skills/social-graphic
```

### Step 4 — Update worker.yamls

Copy the updated `core/workers/impeccable-designer/worker.yaml` and `core/workers/social-strategist/worker.yaml` from the release, or manually add the new `skills:` blocks.

### Step 5 — Verify

```bash
ls .claude/commands/*.md | wc -l    # Should be 36
ls .claude/skills/ | wc -l          # Should be ~18 (core skills only)
ls core/workers/impeccable-designer/skills/ | wc -l  # Should be 22
```

---

## Migrating to v10.7.0 (from v10.6.0)

### Headline

This release ships the **HQ Performance Audit** — a ~50% reduction in session-start
context burn via pre-built policy digests, plus 8 commands consolidated to the new
**Archetype A** shape (thin delegator stub + canonical `SKILL.md`).

### Step 1 — Pull and verify scaffolding

```bash
git pull
ls .claude/hooks/load-policies-for-session.sh
ls core/policies/_digest.md
ls core/scripts/build-policy-digest.sh core/scripts/git-hooks/pre-commit
```

If any of those four are missing, your pull is incomplete — re-run.

### Step 2 — Wire the auto-rebuild pre-commit hook

The new `core/scripts/git-hooks/pre-commit` rebuilds `_digest.md` whenever you commit
policy changes. Install it:

```bash
chmod +x core/scripts/git-hooks/pre-commit
ln -sf ../../scripts/git-hooks/pre-commit .git/hooks/pre-commit
```

If you already have a `.git/hooks/pre-commit` wrapper, append a call to
`core/scripts/git-hooks/pre-commit` rather than overwriting.

### Step 3 — Verify the SessionStart hook fires

Start a fresh Claude Code session in the repo. Look for a `<policy-digest>` block
in the first system reminder. If you don't see it:

```bash
grep -A1 SessionStart .claude/settings.json
```

You should see the `load-policies-for-session.sh` entry. If missing, your
`settings.json` needs the SessionStart block — copy from `template/.claude/settings.json`.

### Step 4 — Port any local edits to the 7 consolidated commands

These commands now delegate to `SKILL.md`. If you had local customizations in any
of them, your edits will be **overwritten** when you sync the template:

| Command | Canonical home |
|---|---|
| `prd` | `.claude/skills/prd/SKILL.md` |
| `handoff` | `.claude/skills/handoff/SKILL.md` |
| `learn` | `.claude/skills/learn/SKILL.md` |
| `execute-task` | `.claude/skills/execute-task/SKILL.md` |
| `search` | `.claude/skills/search/SKILL.md` |
| `startwork` | `.claude/skills/startwork/SKILL.md` |
| `brainstorm` | `.claude/skills/brainstorm/SKILL.md` |

For each, diff the old `.md` against the new SKILL.md, port your customizations
into the SKILL, and let the stub remain as a thin delegator.

### Step 5 — Optional: rebuild your digests

If you've modified policies locally, regenerate `_digest.md`:

```bash
bash core/scripts/build-policy-digest.sh
```

The pre-commit hook from Step 2 will keep this in sync going forward.

### What you get after migrating

- **−50% session-start context** on most cwds (HQ root, personal, code-repo)
- **Faster orientation** — the policy digest lands in the first turn instead of
  burning a tool round-trip
- **Auto-maintained digests** — no manual rebuild required after the pre-commit
  hook is installed

---

## Migrating to v10.6.0 (from v10.5.0)

### Updated Commands (21)

Diff and merge updated commands:
```bash
diff -rq template/.claude/commands/ your-hq/.claude/commands/
```

Key commands to review: `audit`, `checkpoint`, `cleanup`, `garden`, `handoff`, `harness-audit`, `hq-growth-dashboard`, `learn`, `newworker`, `pr`, `prd`, `reanchor`, `recover-session`, `remember`, `run-pipeline`, `run-project`, `run`, `search-reindex`, `search`, `startwork`, `understand-project`

### Updated Skills (11)

Diff and merge updated skills:
```bash
diff -rq template/.claude/skills/ your-hq/.claude/skills/
```

Updated: `ascii-graphic`, `colorize`, `consolidate`, `execute-task`, `handoff`, `land`, `prd`, `run-project`, `run`, `search`, `social-graphic`

### New Hook

Copy the new MCP cleanup hook:
```bash
cp template/.claude/hooks/cleanup-mcp-processes.sh your-hq/.claude/hooks/
chmod +x your-hq/.claude/hooks/cleanup-mcp-processes.sh
```

Then add the Stop hook entry to your `.claude/settings.json` hooks section:
```json
{
  "type": "command",
  "command": ".claude/hooks/hook-gate.sh cleanup-mcp-processes .claude/hooks/cleanup-mcp-processes.sh",
  "timeout": 5
}
```

### Updated Policies

Sync 154 scope-filtered policies:
```bash
diff -rq template/core/policies/ your-hq/core/policies/
```

### Breaking Changes
- (none this release)

---

## Migrating to v10.5.0 (from v10.4.0)

### New Command

Copy the new command:
```bash
cp template/.claude/commands/run-pipeline.md your-hq/.claude/commands/
```

### New Skill

Copy the new skill directory:
```bash
cp -r template/.claude/skills/land-batch/ your-hq/.claude/skills/land-batch/
```

### Updated Commands (18)

Diff and merge updated commands:
```bash
diff -rq template/.claude/commands/ your-hq/.claude/commands/
```

### Updated Skills (13)

Diff and merge updated skills:
```bash
diff -rq template/.claude/skills/ your-hq/.claude/skills/
```

### New Policies (8)

Copy new policies:
```bash
for p in hq-bugfix-requires-tests hq-data-collection-isolation hq-github-review-thread-resolution hq-no-test-shortcuts hq-no-worktree-for-repo-work paper-text-wrapping; do
  cp template/core/policies/${p}.md your-hq/core/policies/
done
```

### Updated Hooks (11)

```bash
cp template/.claude/hooks/*.sh your-hq/.claude/hooks/
chmod +x your-hq/.claude/hooks/*.sh
```

### Updated Settings

Add `PATH` to your `.claude/settings.json` env block:
```json
"PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
```

### Knowledge Bases

Rsync updated knowledge:
```bash
rsync -av template/knowledge/ your-hq/knowledge/ --exclude='.git/'
```

### Breaking Changes
- (none)

---

## Migrating to v10.4.0 (from v10.3.0)

### New Skills (9 Codex-ready skills)

Copy these skill directories:

```bash
for s in brainstorm execute-task handoff learn prd run run-project search startwork; do
  cp -r template/.claude/skills/$s/ your-hq/.claude/skills/$s/
done
```

Each includes `SKILL.md` + `agents/openai.yaml` for dual Claude Code / Codex discovery.

### Updated Scripts

```bash
cp template/scripts/codex-skill-bridge.sh your-hq/scripts/codex-skill-bridge.sh
chmod +x your-hq/scripts/codex-skill-bridge.sh
```

### Updated CLAUDE.md

The Skills section now includes Codex dual-format documentation. Merge the new section from `template/.claude/CLAUDE.md` into your CLAUDE.md.

### Updated Denylist

If you use `/publish-kit`, update your `scrub-denylist.yaml` with the new `exceptions` section:

```yaml
exceptions:
  "indigoai-us": "indigoai-us"
  "@indigoai-us": "@indigoai-us"
  "indigoai-us/hq": "indigoai-us/hq"
```

### Updated Policies

154 policies synced. Run a diff to merge new/changed policies:
```bash
diff -rq template/core/policies/ your-hq/core/policies/
```

### Breaking Changes
- (none)

---

## Migrating to v10.3.0 (from v10.2.0)

Minor release. No breaking changes.

### New Skill

Copy the `land` skill directory:

```bash
cp -r template/.claude/skills/land/ your-hq/.claude/skills/land/
```

### New Policies

Copy these 12 policies from `template/core/policies/`:

```bash
for p in hq-alert-baseline-calibration hq-announce-before-irreversible hq-confirm-creative-direction hq-fix-root-cause-not-symptoms hq-never-swallow-errors hq-no-production-testing hq-post-parallel-build-verify hq-pr-single-concern prd-files-match-acs-for-swarm run-project-name-matches-dir run-project-sigkill-retry scrub-hook-no-denylist-in-template; do
  cp "template/core/policies/${p}.md" "your-hq/core/policies/${p}.md"
done
```

### Updated Commands

Review and merge changes to:
- `.claude/commands/run-project.md` (new `--inline` execution mode)
- `.claude/commands/update-hq.md` (rewritten for indigoai-us/hq)
- `.claude/commands/hq-growth-dashboard.md` (updated repo references)

### Breaking Changes
- (none this release)

---

## Migrating to v10.2.0 (from v10.1.0)

Minor release. No breaking changes.

### New: Codex App Skill Discovery

All 30 HQ skills now include `agents/openai.yaml` for Codex UI rendering. To add them:

```bash
# Copy agents/openai.yaml into each skill dir
for d in starter-kit/.claude/skills/*/agents/; do
  skill=$(basename "$(dirname "$d")")
  mkdir -p "your-hq/.claude/skills/${skill}/agents"
  cp "${d}openai.yaml" "your-hq/.claude/skills/${skill}/agents/openai.yaml"
done
```

Or regenerate from your own SKILL.md files:

```bash
cp starter-kit/scripts/generate-openai-yaml.sh your-hq/scripts/
bash your-hq/scripts/generate-openai-yaml.sh
```

### Updated: Codex Skill Bridge

Copy the updated bridge script:

```bash
cp starter-kit/scripts/codex-skill-bridge.sh your-hq/scripts/codex-skill-bridge.sh
chmod +x your-hq/scripts/codex-skill-bridge.sh
bash your-hq/scripts/codex-skill-bridge.sh install
```

This adds the `.agents/skills/` discovery paths that Codex now prefers over `.codex/skills/`.

### Updated Files

Run `/update-hq` or manually merge changes to:
- Multiple commands, policies, hooks, and knowledge bases
- `CLAUDE.md`, `USER-GUIDE.md`

---

## Migrating to v10.1.0 (from v10.0.0)

Minor release. No breaking changes.

### New: Getting Started Education Kit

Copy the new knowledge directory to your HQ:

```bash
cp -R starter-kit/knowledge/public/getting-started/ your-hq/knowledge/public/getting-started/
```

This adds 3 onboarding guides (quick-start-guide, cheatsheet, learning-path) that `/setup` now references.

### Updated: `/setup` Command

Copy the updated setup command:

```bash
cp starter-kit/.claude/commands/setup.md your-hq/.claude/commands/setup.md
```

The setup flow now includes a welcome phase, educational bridges, and auto-opens the quick-start-guide after completion.

### New Policies

Copy these 4 new policies:

```bash
for p in bun-overrides chunked-reads clipboard-file-protocol deconflict-postbridge-schedule; do
  cp "starter-kit/core/policies/${p}.md" "your-hq/core/policies/${p}.md"
done
```

### Updated Files

Run `/update-hq` or manually merge changes to:
- Multiple commands, policies, workers, and knowledge bases
- `CLAUDE.md`, `USER-GUIDE.md`, `modules.yaml`

---

## Migrating to v10.0.0 (from v9.0.0)

Minor release. No breaking changes.

### New: Obsidian Vault
Copy `.obsidian/` to your HQ root. Open in Obsidian — works out of the box. See `core/knowledge/public/hq-core/obsidian-setup.md` for details.

Add to your `.gitignore`:
```
.obsidian/workspace.json
.obsidian/workspace-mobile.json
.obsidian/plugins/
.obsidian/themes/
.obsidian/community-plugins.json
```

### New Command
- `/hq-growth-dashboard` — copy `.claude/commands/hq-growth-dashboard.md`

### New Hook
- `protect-core.sh` — copy `.claude/hooks/protect-core.sh`, `chmod +x`

### Updated Files
Run `/update-hq` or manually merge changes to:
- 16 commands, 4 skills, 30+ policies, 4 hooks, 5 workers
- `CLAUDE.md`, `USER-GUIDE.md`, `modules.yaml`

### Removed
- Delete `core/policies/qa-screenshot-isolation.md` (replaced by `image-context-isolation.md`)

---

## Migrating to v9.0.0 (from v8.x)

This is a major release. Three new directories are introduced.

### New: Skills (`.claude/skills/`)

Copy the entire `.claude/skills/` directory from the starter-kit. This adds 30 design, code quality, and workflow skills that power commands like `/polish`, `/investigate`, `/audit`, etc.

```bash
cp -R starter-kit/.claude/skills/ your-hq/.claude/skills/
```

### New: Policies (`core/policies/`)

Copy the entire `core/policies/` directory. These are 89 structured workflow rules covering git safety, Vercel gotchas, Supabase patterns, orchestrator guardrails, and more.

```bash
cp -R starter-kit/core/policies/ your-hq/core/policies/
```

### New: Infrastructure Files

Copy these files to your HQ root:

| File | Purpose |
|------|---------|
| `.ignore` | Ripgrep config — blocks `repos/`, `node_modules/` from Grep |
| `core/settings/orchestrator.yaml` | Swarm/file-locking config for `/run-project` |
| `USER-GUIDE.md` | Command reference + worker guide |
| `core/scripts/codex-skill-bridge.sh` | Codex ↔ Claude skill bridge |
| `core/scripts/audit-log.sh` | Structured audit log utility |
| `core/scripts/resize-screenshot.sh` | Screenshot resize (used by hook) |

### Updated Files

Review and merge changes to all existing commands, workers, and knowledge. The easiest approach:

```bash
# From your HQ root, with starter-kit cloned alongside:
rsync -avL --ignore-existing starter-kit/.claude/commands/ .claude/commands/
rsync -avL --ignore-existing starter-kit/workers/public/ core/workers/public/
rsync -avL --ignore-existing starter-kit/knowledge/ core/knowledge/public/
```

### Breaking Changes
- None — all additions are backward-compatible

---

## Migrating to v8.2.0 (from v8.1.x)

### New Commands
Copy these files from starter-kit to your HQ:
- `.claude/commands/document-release.md`
- `.claude/commands/investigate.md`
- `.claude/commands/retro.md`

### New Hook
Copy to your HQ:
- `.claude/hooks/block-inline-story-impl.sh` — run `chmod +x` after copying

### Updated Commands
Review and merge changes to these 19 commands:
- `audit.md`, `brainstorm.md`, `cleanup.md`, `execute-task.md`, `garden.md`
- `harness-audit.md`, `model-route.md`, `prd.md`, `reanchor.md`, `recover-session.md`
- `remember.md`, `review-plan.md`, `run-project.md`, `run.md`, `search-reindex.md`
- `search.md`, `startwork.md`, `update-hq.md`, `review.md`, `understand-project.md`

### Updated Hooks
Replace these hooks (run `chmod +x` after copying):
- `.claude/hooks/auto-checkpoint-trigger.sh`
- `.claude/hooks/hook-gate.sh`
- `.claude/hooks/observe-patterns.sh`

### Updated Scripts
Replace:
- `.claude/scripts/run-project.sh` — adds story test runner + codex model hints

### New Workers
Copy these directories to `core/workers/`:
- `core/workers/impeccable-designer/`
- `core/workers/paper-designer/`

Update `core/workers/registry.yaml` — version bumped to v10.0 with 45 public workers.

### New Knowledge
Copy these to `core/knowledge/`:
- `core/knowledge/impeccable/` (new knowledge base)
- `core/knowledge/design-styles/formulas/` (new subtree)
- `core/knowledge/agent-browser/tauri-testing.md`
- `core/knowledge/hq/handoff-templates.md`
- `core/knowledge/hq/knowledge-taxonomy.md`

### Removed
- Delete `.claude/commands/imessage.md` if present (personal command, removed from starter-kit)

### PII Scrub
This release scrubbed all company-specific references. If you forked from an earlier version, review your files for any {PRODUCT}/{Product}/{company} references and replace with generic placeholders.

### Breaking Changes
- None

---

## Migrating to v8.1.1 (from v8.1.0)

### New directories (create manually)
Existing installs need to create these directories:
```bash
mkdir -p repos/public repos/private
mkdir -p companies/_template/policies
mkdir -p settings data modules scripts
mkdir -p workspace/learnings workspace/reports
```

### New files
Copy from starter-kit to your HQ:
- `companies/_template/policies/example-policy.md`
- `companies/manifest.yaml` (if you don't already have one)
- `.ignore` (ripgrep ignore — prevents Grep from scanning repos/)
- `.claude/commands/review.md`
- `.claude/commands/review-plan.md`
- `.claude/skills/review/` (entire directory)
- `.claude/skills/review-plan/` (entire directory)

### Updated hooks
Replace these files:
- `.claude/hooks/auto-checkpoint-trigger.sh`

### No breaking changes

---

## Migrating to v8.1.0 (from v8.0.x)

### Updated run-project.sh (full replace)
Major upgrade: 3-layer passes detection, swarm retry tracking, per-story branch isolation, project reanchor, codex autofix, macOS timeout fallback.
```bash
cp starter-kit/.claude/scripts/run-project.sh .claude/scripts/run-project.sh
# or if you keep it at core/scripts/run-project.sh:
cp starter-kit/.claude/scripts/run-project.sh scripts/run-project.sh
chmod +x .claude/scripts/run-project.sh  # or scripts/run-project.sh
```

### Updated Commands (15 files)
```bash
for f in run-project prd audit cleanup garden model-route reanchor recover-session remember run search search-reindex startwork update-hq; do
  cp starter-kit/.claude/commands/$f.md .claude/commands/
done
```

### Updated CLAUDE.md
Three changes to merge:
1. **Token table** — `MAX_THINKING_TOKENS` → `31999`, new `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING` row
2. **Linear rules 11 & 12** — Default assignee by team + no-orphan-issues
```bash
diff .claude/CLAUDE.md starter-kit/.claude/CLAUDE.md
```

### `/prd` — Behavioral Change
`/prd` now uses a 7-batch question flow (was 4-batch). The interview is more thorough with separate batches for Users/Current State, Data/Architecture, Integrations, and Quality/Shipping. No schema changes — existing prd.json files are fully compatible.

### Migration Steps
1. Replace `run-project.sh` and `chmod +x`
2. Copy 15 updated commands
3. Merge 3 CLAUDE.md changes (token table, Linear rules)
4. Run `/search-reindex`

### Breaking Changes
- (none)

---

## Migrating to v8.0.0 (from v7.0.0)

### Updated Commands (9 files)
These commands now include policy loading. Copy from starter-kit to your HQ:
```bash
for f in audit handoff harness-audit learn model-route prd run-project run startwork; do
  cp starter-kit/.claude/commands/$f.md .claude/commands/
done
```

### New Command (1 file)
```bash
cp starter-kit/.claude/commands/strategize.md .claude/commands/
```

### Updated CLAUDE.md
The Policies section now includes a **Standard Policy Loading Protocol**. Review and merge:
```bash
diff .claude/CLAUDE.md starter-kit/.claude/CLAUDE.md
```
Key addition: 5-step protocol for commands to load company → repo → global policies, plus list of implementing commands.

### Updated run-project.sh
Major upgrade: swarm mode (parallel story execution), worktree isolation, signal trapping, headless doc sweep, budget caps removed. Copy:
```bash
cp starter-kit/.claude/scripts/run-project.sh .claude/scripts/run-project.sh
# or if you keep it at core/scripts/run-project.sh:
cp starter-kit/.claude/scripts/run-project.sh scripts/run-project.sh
chmod +x core/scripts/run-project.sh
```

### Updated execute-task.md
Self-owned lock skip for swarm mode + single-writer pattern (orchestrator writes `passes`). Already included in the 9-file copy above.

### New: orchestrator.yaml
Swarm configuration. Copy to your settings dir:
```bash
cp starter-kit/settings/orchestrator.yaml core/settings/orchestrator.yaml
```

### `/learn` — Breaking Behavioral Change
`/learn` now creates **policy files** (structured markdown with YAML frontmatter) as its primary output instead of injecting rules into `worker.yaml` or `CLAUDE.md`. Existing learned rules in worker.yaml files still work but new learnings will be written as policy files in:
- `companies/{co}/policies/` (company scope)
- `repos/{repo}/.claude/policies/` (repo scope)
- `core/policies/` (global/command scope)

No action needed — old rules remain valid. New rules will be policy files.

---

## Migrating to v7.0.0 (from v6.5.1)

### New Hooks (3 files)
Copy to `.claude/hooks/` and make executable:
```bash
cp starter-kit/.claude/hooks/hook-gate.sh .claude/hooks/
cp starter-kit/.claude/hooks/detect-secrets.sh .claude/hooks/
cp starter-kit/.claude/hooks/observe-patterns.sh .claude/hooks/
chmod +x .claude/hooks/hook-gate.sh .claude/hooks/detect-secrets.sh .claude/hooks/observe-patterns.sh
```

### Settings.json — Hook Rewiring (BREAKING)
Your `.claude/settings.json` hooks are rewired through `hook-gate.sh`. This is a **breaking change** if you have custom hooks.

**Before (v6.5.1):**
```json
{ "matcher": "Glob", "hooks": [{ "type": "command", "command": ".claude/hooks/block-hq-glob.sh" }] }
```

**After (v7.0.0):**
```json
{ "matcher": "Glob", "hooks": [{ "type": "command", "command": ".claude/hooks/hook-gate.sh block-hq-glob .claude/hooks/block-hq-glob.sh" }] }
```

Copy the full `settings.json` from starter-kit, or manually rewire each hook through `hook-gate.sh`. Two new hooks added:
- PreToolUse Bash → `hook-gate.sh detect-secrets .claude/hooks/detect-secrets.sh`
- Stop → `hook-gate.sh observe-patterns .claude/hooks/observe-patterns.sh`

### New Script
```bash
mkdir -p core/scripts/
cp starter-kit/scripts/audit-log.sh core/scripts/
chmod +x core/scripts/audit-log.sh
```

### Updated Script
Replace `.claude/scripts/run-project.sh` with the full v7.0.0 version (1390 lines). Includes audit log integration and `--tmux` mode.

### New Commands (9 files)
Copy to `.claude/commands/`:
- `audit.md`, `brainstorm.md`, `dashboard.md`, `goals.md`, `harness-audit.md`, `idea.md`, `model-route.md`, `quality-gate.md`, `tdd.md`

### Updated Commands (3 files)
Review and merge:
- `execute-task.md` — Checkout guard (section 2.6) prevents concurrent story execution
- `prd.md` — Brainstorm detection (steps 3.5 + 5.5)
- `run-project.md` — Worked example, `--tmux` flag

### New Workers (4 dirs)
Copy to `core/workers/`:
- `accessibility-auditor/` — WCAG 2.2 AA auditing
- `exec-summary/` — McKinsey SCQA executive summaries
- `performance-benchmarker/` — Core Web Vitals + k6 load testing
- `dev-team/reality-checker/` — Final quality gate

### Registry Update
Replace `core/workers/registry.yaml`. Version 8.0 → 9.0. If you have custom workers, merge them into the `# Add your workers below` section.

### Removed Workers
Delete these directories if present (were private/company-specific, leaked in v6.0.0):
- `core/workers/pr-shared/`, `pr-strategist/`, `pr-writer/`, `pr-outreach/`, `pr-monitor/`, `pr-coordinator/`

### Knowledge Cleanup
- Delete `core/knowledge/hq/` if present (duplicate of `core/knowledge/hq-core/`)
- Copy `core/knowledge/hq-core/handoff-templates.md` from starter-kit

### CLAUDE.md Updates

**New sections to add:**
1. **Token Optimization** (after Context Diet) — Env var cost controls
2. **Hook Profiles** (after Token Optimization) — Runtime hook configuration

**Sections to update:**
- **Workers** — Add accessibility-auditor, exec-summary, performance-benchmarker, reality-checker. Remove pr-team. Dev Team 16→17
- **Commands count** — Update to 35+

### Migration Steps
1. Copy 3 new hooks and `chmod +x`
2. Update `settings.json` (hook-gate rewiring)
3. Copy `core/scripts/audit-log.sh` and `chmod +x`
4. Replace `.claude/scripts/run-project.sh`
5. Copy 9 new commands
6. Merge 3 updated commands
7. Copy 4 new worker directories
8. Delete 6 PR team worker directories
9. Update `core/workers/registry.yaml` (merge custom workers)
10. Delete `core/knowledge/hq/` duplicate
11. Merge CLAUDE.md sections (Token Optimization, Hook Profiles)
12. Run `/search-reindex`

### Breaking Changes
- `settings.json` hooks now route through `hook-gate.sh` — direct hook commands no longer work without the gate
- PR team workers removed — if you use them, keep your local copies
- `core/knowledge/hq/` deleted — use `core/knowledge/hq-core/` instead

---

## Migrating to v6.5.1 (from v6.5.0)

### New Files
- `.claude/hooks/block-hq-grep.sh` — Grep safety hook
- `.claude/hooks/warn-cross-company-settings.sh` — Cross-company settings warning
- `core/workers/dev-team/context-manager/` — Context management worker (4 skills)

### Updated Files
- `.claude/CLAUDE.md` — New LSP section
- `.claude/settings.json` — Added Grep and Read PreToolUse hooks
- `README.md` — LSP setup in prerequisites

### CLAUDE.md Updates

**New section to add (after Search):**
- **LSP** — When `ENABLE_LSP_TOOL=1` is set, prefer LSP tools over Grep for code navigation

### Settings.json Updates
Add these to your `PreToolUse` hooks array:
```json
{
  "matcher": "Grep",
  "hooks": [{ "type": "command", "command": ".claude/hooks/block-hq-grep.sh", "timeout": 5 }]
},
{
  "matcher": "Read",
  "hooks": [{ "type": "command", "command": ".claude/hooks/warn-cross-company-settings.sh", "timeout": 5 }]
}
```

### Removed Commands
- `/checkemail` — Moved to private (requires personal Gmail config)
- `/email` — Moved to private (requires personal Gmail config)

If you use these commands, keep your local copies. They are no longer part of the public starter kit.

### Breaking Changes
- (none)

---

## Migrating to v6.5.0 (from v6.4.0)

### New Workers
Copy these directories from starter-kit to your HQ `core/workers/public/`:
- `core/workers/gemini-coder/` — Gemini CLI code generation
- `core/workers/gemini-reviewer/` — Gemini CLI code review
- `core/workers/gemini-frontend/` — Gemini CLI frontend generation
- `core/workers/knowledge-tagger/` — Knowledge document classification
- `core/workers/site-builder/` — Local business website builder

Update `core/workers/registry.yaml` to include the new entries.

### New Knowledge Bases
Copy from starter-kit to your HQ `core/knowledge/public/`:
- `core/knowledge/gemini-cli/` — Gemini CLI integration docs

### Updated Commands
Review and merge changes to:
- `.claude/commands/execute-task.md` — Refined codex-reviewer, back-pressure handling
- `.claude/commands/prd.md` — Company Anchor (Step 0), Beads sync (Step 7)
- `.claude/commands/run-project.md` — Externalized to bash script, CLI flags
- `.claude/commands/handoff.md` — Knowledge update step (0b)
- `.claude/commands/learn.md` — Target-file injection, cap enforcement, global promotion
- `.claude/commands/startwork.md` — Company knowledge loading, Vercel context
- `.claude/commands/checkemail.md` — Email-triage app integration
- `.claude/commands/email.md` — 4-phase triage, Linear/PRD creation


### CLAUDE.md Updates

**New sections to add:**
1. **Skills** (after Company Isolation) — `.claude/skills/` tree with Codex bridge
2. **Policies (Learned Rules)** (before Core Principles) — Policy file directories and precedence

**Sections to update:**
- **Company Isolation** — Add manifest infrastructure routing fields, 3-step operation protocol, credential access reference
- **Workers** — Update counts for social-team (5), pr-team (6), gardener-team (3), gemini-team (3), knowledge-tagger, site-builder
- **Search rules** — Add PRD/worker/company discovery rows, Glob blocking rule
- **Knowledge Repos** — Add embedded git repo pattern, `Reading/searching` note
- **Knowledge Bases** — Add: agent-browser, curious-minds, gemini-cli, pr, context-needs, project-context
- **Infrastructure-First** — Update `/prd` path to company-scoped
- **Commands count** — Update to 35+

### Breaking Changes
- `/run-project` now delegates to `core/scripts/run-project.sh`. If you don't have this script, the command falls back to in-session execution.

---

## Migrating to v6.4.0 (from v6.3.0)

### New Commands
Copy these files from starter-kit to your HQ:
- `.claude/commands/imessage.md` — Send iMessage to contacts

### Updated Commands
Review and merge changes to:
- `.claude/commands/execute-task.md` — File lock acquisition (5.5), policy loading (5.6), dynamic lock expansion (6d.5), lock release on failure (8.0), iMessage notify (7c.5), Linear comments (7a.6), company-scoped project resolution
- `.claude/commands/prd.md` — Company-scoped projects (`companies/{co}/projects/`), `files` field in story schema, board sync (5.5), mandatory creation rule, STOP after creation
- `.claude/commands/run-project.md` — Company-scoped resolution, board sync (4.5), file lock conflict check (5a.1), Linear comments (5a.6), policy re-read in auto-reanchor
- `.claude/commands/newworker.md` — Company-scoped worker paths
- `.claude/commands/checkpoint.md` — Embedded repo support in knowledge state capture

### CLAUDE.md Updates

**Policies section** — Replace with three-directory structure:
```
Before executing tasks, load applicable policies from all three directories:
1. companies/{co}/policies/ — company-scoped rules
2. repos/{repo}/.claude/policies/ — repo-scoped rules
3. core/policies/ — cross-cutting + command-scoped rules
Precedence: company > repo > command > global
```

**Learning System section** — Update to reflect policy-file-based approach (learnings → policy files, not inline injection).

**Knowledge Repos section** — Distinguish embedded company repos from symlinked shared repos.

**Commands count** — Update "23 commands" → "24 commands".

### Breaking Changes
- `/prd` now creates projects at `companies/{co}/projects/{name}/` instead of `projects/{name}/`. Root `projects/` is fallback for personal/HQ-only projects.
- `/prd` now requires `/handoff` after creation — no implementation in same session.

---

## Migrating to v6.3.0 (from v6.2.0)

### New Files
- `.claude/hooks/block-hq-glob.sh` — Glob safety hook (blocks Glob from HQ root to prevent timeouts)
- `companies/_template/policies/example-policy.md` — Policy template for `/newcompany` scaffolding

### Updated Files
- `.claude/CLAUDE.md` — 2 new sections (Policies, File Locking) + expanded Company Isolation + 4 new learned rules
- `.claude/settings.json` — New PreToolUse hook for Glob safety
- `.claude/commands/update-hq.md` — settings.json merge logic (5b-SETTINGS), template directory handling

### New CLAUDE.md Sections
Add these sections to your `.claude/CLAUDE.md`:

1. **Policies** (after Company Isolation) — Company-scoped standing rules with hard/soft enforcement
2. **File Locking** (after Sub-Agent Rules) — Concurrent edit prevention for multi-agent projects

### New Company Isolation Rules
Add to your `## Company Isolation` section:
- `NEVER use Linear credentials from a different company's settings`
- `Before any Linear API call, validate: config.json workspace field matches expected company`

### New Learned Rules
Add to your `## Learned Rules` section:
- `pre-deploy domain check` — Always check live URL and domain ownership before deploying to custom domains
- `EAS build env vars` — EAS production builds don't inherit local .env; set EXPO_PUBLIC_* via CLI
- `Vercel env var trailing newlines` — Use printf not echo when piping to vercel env add
- `model routing` — Workers declare execution.model in worker.yaml; stories can override via model_hint

### Glob Safety Hook
1. Copy `.claude/hooks/block-hq-glob.sh` to your HQ
2. Make executable: `chmod +x .claude/hooks/block-hq-glob.sh`
3. Add to your `.claude/settings.json` under `hooks`:
   ```json
   "PreToolUse": [
     {
       "matcher": "Glob",
       "hooks": [
         {
           "type": "command",
           "command": ".claude/hooks/block-hq-glob.sh",
           "timeout": 5
         }
       ]
     }
   ]
   ```

### Migration Steps
1. Copy `.claude/hooks/block-hq-glob.sh` and make executable
2. Merge PreToolUse section into your `.claude/settings.json` (or let `/update-hq` handle it — v6.3.0 adds JSON-aware settings merge)
3. Merge 2 new CLAUDE.md sections: Policies, File Locking
4. Add 2 new Company Isolation rules
5. Add 4 new learned rules to your Learned Rules section
6. Copy `companies/_template/policies/example-policy.md` for policy scaffolding
7. Update `.claude/commands/update-hq.md` for safe settings.json migration in future upgrades
8. Run `/search-reindex`

### Breaking Changes
- (none)

---

## Migrating to v6.2.0 (from v6.1.0)

### Updated Files
Merge changes to:
- `.claude/CLAUDE.md` — 5 new behavioral sections + 6 new learned rules

### New CLAUDE.md Sections
Add these sections to your `.claude/CLAUDE.md`:

1. **Session Handoffs** (after Context Diet) — Handoff workflow rules
2. **Corrections & Accuracy** (after Session Handoffs) — User correction handling
3. **Sub-Agent Rules** (after Workers) — Multi-agent commit coordination
4. **Git Workflow Rules** (before Project Repos - Commit Rules) — Git hygiene
5. **Vercel Deployments** (after Project Repos - Commit Rules) — Deploy safety

### New Learned Rules
Add to your `## Learned Rules` section:
- `vercel custom domain deploy safety` — Never deploy to production custom domains without confirmation
- `Task() sub-agents lack MCP` — Sub-agents can't use MCP tools, use CLI instead
- `Shopify 2026 auth` — Ephemeral tokens via client_credentials grant
- `vercel preview SSO` — `--public` doesn't bypass SSO; use local testing
- `Vercel domain team move` — API for moving domains between Vercel teams
- `Vercel framework detection` — `framework: null` causes 404s on all routes

### Migration Steps
1. Merge 5 new sections from starter-kit `.claude/CLAUDE.md` into yours
2. Add 6 new learned rules to your `## Learned Rules` section
3. Update `<!-- Max -->` comment to 25
4. Run `/search-reindex`

### Breaking Changes
- (none)

---

## Migrating to v6.1.0 (from v6.0.0)

### Prerequisites
- Codex CLI installed: `npm install -g @openai/codex` (or `brew install codex`)
- Codex authenticated: `codex login`
- If Codex CLI is not available, the pipeline degrades gracefully (warns and skips Codex phases)

### Updated Commands
Replace in `.claude/commands/`:
- `execute-task.md` — New inline Codex review step + pre-flight check

### Updated Workers
Replace these directories in `core/workers/dev-team/`:
- `codex-reviewer/` — Skills rewritten from MCP to CLI
- `codex-coder/` — Skills rewritten from MCP to CLI
- `codex-debugger/` — Skills rewritten from MCP to CLI
- `codex-engine/package.json` — Updated description only

### Breaking Changes
- **MCP server no longer used by pipeline** — If you had custom integrations calling the codex-engine MCP server from within worker phases, those will need to switch to `codex review` / `codex exec` CLI calls. The MCP server still works for standalone use via `/run`.

---

## Migrating to v6.0.0 (from v5.5.x)

### New Commands
Copy to `.claude/commands/`:
- `garden.md` — Multi-worker HQ content audit & cleanup
- `startwork.md` — Lightweight session entry
- `newcompany.md` — Scaffold new company infrastructure
- `{custom-command}.md` — Student onboarding pipeline

### Updated Commands
Review and merge changes to all existing commands — 22 commands were refreshed. Key ones:
- `execute-task.md` — Worker pipeline updates
- `run-project.md` — Orchestration improvements
- `cleanup.md` — New audit checks
- `prd.md` — Enhanced discovery flow

### New Worker Teams
Copy these directories to `core/workers/`:
- `core/workers/dev-team/` — Full 16-worker development team (architect, backend-dev, frontend-dev, database-dev, QA, etc.)
- `core/workers/content-brand/`, `content-sales/`, `content-product/`, `content-legal/`, `content-shared/` — Content pipeline
- `core/workers/social-shared/`, `social-strategist/`, `social-reviewer/`, `social-publisher/`, `social-verifier/` — Social pipeline
- `core/workers/pr-shared/`, `pr-strategist/`, `pr-writer/`, `pr-outreach/`, `pr-monitor/`, `pr-coordinator/` — PR pipeline
- `core/workers/gardener-team/` — Content audit team (garden-scout, garden-auditor, garden-curator)
- `core/workers/frontend-designer/`, `qa-tester/`, `security-scanner/`, `pretty-mermaid/` — Standalone workers

### Registry Update
Replace `core/workers/registry.yaml` with the new v7.0 version. If you have custom workers, merge them into the `# Add your workers below` section at the bottom.

### Knowledge Updates
Copy updated knowledge directories:
- `core/knowledge/agent-browser/` (new)
- `core/knowledge/pr/` (new)
- `core/knowledge/curious-minds/` (new)
- All existing knowledge dirs refreshed

### CLAUDE.md Update
Review and merge `.claude/CLAUDE.md` — significant additions including gardener team, learned rules system, company isolation rules.

### Breaking Changes
- Registry version 6.0 → 7.0. Worker paths restructured. Custom workers need manual merge.
- Dev team workers re-included (were removed in v5.0.0). If you built custom equivalents, check for conflicts.

---

## Migrating to v5.5.1 (from v5.5.0)

### Updated Commands
Review and merge changes to:
- `.claude/commands/setup.md` — repos directory now created as first step in Phase 2
- `.claude/commands/update-hq.md` — repos validation added to pre-flight checks

### New Directories
If missing, create:
```bash
mkdir -p repos/public repos/private
```
These are required for all code, knowledge, and project repos.

### Breaking Changes
- (none)

---

## Migrating to v5.5.0 (from v5.4.0)

### New Command
Copy to `.claude/commands/`:
- `recover-session.md` — Recover dead sessions that hit context limits

### Renamed Command
- `.claude/commands/migrate.md` → `.claude/commands/update-hq.md` — Same functionality, friendlier name

### Updated Files
- `.claude/CLAUDE.md` — Merge the new "Communication" commands section, add `/recover-session` to Session Management, replace `/migrate` with `/update-hq` in System table

### Migration Steps
1. Copy `.claude/commands/recover-session.md`
2. Rename `.claude/commands/migrate.md` to `.claude/commands/update-hq.md` (or copy fresh from starter-kit)
3. Update your `.claude/CLAUDE.md` command count and tables
4. Run `/search-reindex`

### Breaking Changes
- `/migrate` renamed to `/update-hq` — if you have scripts or docs referencing `/migrate`, update them

---

## Migrating to v5.4.0 (from v5.3.0)

### New Commands
Copy these files from starter-kit to your HQ:
- `.claude/commands/checkemail.md` — Inbox cleanup with auto-archive + triage
- `.claude/commands/decide.md` — Batch decision UI for human-in-the-loop workflows
- `.claude/commands/email.md` — Multi-account Gmail management

### Updated Commands
Review and merge changes to these 12 commands:
- `.claude/commands/run-project.md` — **Important:** Anti-plan directive added to sub-agent prompt
- `.claude/commands/execute-task.md` — **Important:** Anti-plan rule added to Rules section
- `.claude/commands/checkpoint.md`, `cleanup.md`, `handoff.md`, `metrics.md`, `newworker.md`, `reanchor.md`, `remember.md`, `run.md`, `search.md`, `search-reindex.md`

### New Knowledge
Copy the new knowledge files:
- `core/knowledge/hq-core/quick-reference.md`
- `core/knowledge/hq-core/starter-kit-compatibility-contract.md`
- `core/knowledge/hq-core/desktop-claude-code-integration.md`
- `core/knowledge/hq-core/desktop-company-isolation.md`
- `core/knowledge/hq-core/hq-structure-detection.md`
- `core/knowledge/hq-core/hq-desktop/` (entire directory — 12 spec files for HQ Desktop)

### Updated Knowledge
Review and merge:
- `core/knowledge/hq-core/index-md-spec.md`
- `core/knowledge/hq-core/thread-schema.md`
- `core/knowledge/workers/skill-schema.md`
- `core/knowledge/workers/state-machine.md`
- `core/knowledge/workers/README.md`
- `core/knowledge/projects/README.md`

### Updated Workers
- `core/workers/dev-team/codex-coder/worker.yaml`
- `core/workers/dev-team/codex-debugger/worker.yaml` + `skills/debug-issue.md`
- `core/workers/dev-team/codex-reviewer/worker.yaml` + `skills/apply-best-practices.md` + `skills/improve-code.md`

### Breaking Changes
- (none this release)

---

## Migrating to v5.2.0 (from v5.1.0)

### What Changed
`/setup` now checks for GitHub CLI and Vercel CLI, and scaffolds knowledge as symlinked git repos instead of plain directories. README expanded with prerequisites and knowledge repo guide.

### Updated Files
Copy from starter kit:
- `.claude/commands/setup.md` — Rewritten with CLI checks (gh, vercel) and knowledge repo scaffolding
- `.claude/CLAUDE.md` — Knowledge Repos section expanded with step-by-step commands
- `README.md` — Prerequisites table, Knowledge Repos section, updated directory tree

### For Existing HQ Users
If your knowledge is already in plain directories (not symlinked repos), no action needed — everything still works. To adopt the repo pattern for an existing knowledge base:

1. Move: `mv knowledge/{name} repos/public/knowledge-{name}`
2. Init: `cd repos/public/knowledge-{name} && git init && git add . && git commit -m "init" && cd -`
3. Symlink: `ln -s ../../repos/public/knowledge-{name} knowledge/{name}`

### CLI Tools
If you don't have them yet:
- `brew install gh && gh auth login` (GitHub CLI — for PRs, repo management)
- `npm install -g vercel && vercel login` (Vercel — for deployments, optional)

### Migration Steps
1. Copy updated `setup.md`, `CLAUDE.md`, `README.md`
2. Optionally install `gh` and `vercel` CLIs
3. Optionally convert knowledge directories to symlinked repos (instructions above)
4. Run `/search-reindex`

### Breaking Changes
- (none — all changes are additive)

---

## Migrating to v5.1.0 (from v5.0.0)

### What Changed
Context Diet: lazy-loading rules reduce context burn at session start. Commands updated to write recent threads to a dedicated file instead of bloating INDEX.md.

### Updated Files
Copy from starter kit:
- `.claude/CLAUDE.md` — Merge the new "Context Diet" section (after Key Files) into yours
- `.claude/commands/checkpoint.md` — Step 7 now writes to `workspace/threads/recent.md`
- `.claude/commands/handoff.md` — Step 4 now writes to `workspace/threads/recent.md`
- `.claude/commands/reanchor.md` — New "When to Use" section

Updated knowledge:
- `core/knowledge/Ralph/11-team-training-guide.md`
- `core/knowledge/hq-core/index-md-spec.md`
- `core/knowledge/hq-core/thread-schema.md`
- `core/knowledge/workers/README.md`, `skill-schema.md`, `state-machine.md`, `templates/base-worker.yaml`
- `core/knowledge/projects/README.md`

### New File
Create `workspace/threads/recent.md` — this is where `/checkpoint` and `/handoff` now write the recent threads table.

### Optional: Slim INDEX.md
If your INDEX.md is large (200+ lines), consider trimming it to just the directory map and navigation table. Move workers, commands, companies tables out (they're already in CLAUDE.md). Move recent threads list to `workspace/threads/recent.md`.

### Migration Steps
1. Merge Context Diet section from starter kit's `.claude/CLAUDE.md` into yours
2. Copy updated `checkpoint.md`, `handoff.md`, `reanchor.md`
3. Create `workspace/threads/recent.md` (can be empty — next checkpoint/handoff populates it)
4. Copy updated knowledge files
5. Run `/search-reindex`

### Breaking Changes
- (none — all changes are additive)

---

## Migrating to v5.0.0 (from v4.0.0)

### What Changed
Major restructure: bundled workers removed (build your own), simplified setup, new `/personal-interview` command. Commands updated with Linear integration, enhanced search, and codebase exploration.

### New Command
Copy to `.claude/commands/`:
- `personal-interview.md` — Deep interview to populate profile + voice style

### New Worker Structure
- `core/workers/sample-worker/` — Example worker to copy and customize
- `core/workers/registry.yaml` — Now contains only the sample worker + commented template

### Removed (from starter kit)
These directories are deleted in v5.0.0. **If you use them, keep your existing copies**:
- `core/workers/dev-team/` (12 workers)
- `core/workers/content-brand/`, `content-sales/`, `content-product/`, `content-legal/`, `content-shared/`
- `core/workers/security-scanner/`
- `starter-projects/` (personal-assistant, social-media, code-worker)

### Updated Files
Copy from starter kit:
- `.claude/commands/setup.md` — Rewritten (simplified to 3 phases)
- `.claude/commands/execute-task.md` — Linear sync, qmd codebase exploration
- `.claude/commands/handoff.md` — Auto-commit HQ changes
- `.claude/commands/prd.md` — Target repo scanning
- `.claude/commands/run-project.md` — Linear sync
- `.claude/commands/search.md` — Company auto-detection
- `.claude/commands/search-reindex.md` — Multi-collection docs
- `.claude/commands/cleanup.md` — Genericized INDEX paths
- `.claude/commands/reanchor.md` — Genericized company paths
- `.claude/CLAUDE.md` — Merge carefully: new structure, 18 commands, sample-worker
- `core/workers/registry.yaml` — v5.0

Updated knowledge:
- `core/knowledge/Ralph/11-team-training-guide.md`
- `core/knowledge/hq-core/index-md-spec.md`
- `core/knowledge/projects/README.md`
- `core/knowledge/workers/README.md`, `skill-schema.md`

### Migration Steps
1. Copy `.claude/commands/personal-interview.md` (new)
2. Copy updated commands (setup, execute-task, handoff, prd, run-project, search, search-reindex, cleanup, reanchor)
3. Copy `core/workers/sample-worker/` directory (new example worker)
4. Merge `.claude/CLAUDE.md` — update structure tree, commands table, workers section
5. **If using bundled workers**: keep your existing `core/workers/dev-team/`, `core/workers/content-*/` directories — they still work
6. **If NOT using bundled workers**: delete old worker directories, copy new `core/workers/registry.yaml`
7. Copy updated knowledge files
8. Delete `starter-projects/` if present
9. Run `/search-reindex`

### Breaking Changes
- All bundled workers removed from starter kit. Existing copies in your HQ still work.
- `/setup` no longer offers starter project selection. Use `/prd` + `/newworker`.
- `core/workers/registry.yaml` format unchanged but contents stripped to sample-worker only.

---

## Migrating to v4.0.0 (from v3.3.0)

### What Changed
Major architecture upgrade: INDEX.md navigation system, knowledge repos (independent git repos), automated learning pipeline (`/learn`), and significant command updates.

### New Command
Copy to `.claude/commands/`:
- `learn.md` — Automated learning pipeline (captures learnings, injects rules into source files, deduplicates)

### New Knowledge Files
Copy to `core/knowledge/`:
- `Ralph/11-team-training-guide.md` — Team training guide
- `hq-core/checkpoint-schema.json` — Checkpoint data format
- `hq-core/index-md-spec.md` — INDEX.md specification

### Updated Files
All 13 existing public commands have been refreshed. Copy from starter kit:
- `.claude/commands/*.md` (all public commands)
- `.claude/CLAUDE.md` (major rewrite — merge carefully with your customizations)
- `core/workers/registry.yaml` (v4.0)

Updated workers:
- `core/workers/dev-team/code-reviewer/skills/review-pr.md`
- `core/workers/dev-team/frontend-dev/worker.yaml`
- `core/workers/dev-team/qa-tester/worker.yaml`
- `core/workers/dev-team/task-executor/skills/validate-completion.md`

Updated knowledge:
- `core/knowledge/hq-core/thread-schema.md`
- `core/knowledge/workers/README.md`
- `core/knowledge/workers/skill-schema.md`
- `core/knowledge/workers/state-machine.md`
- `core/knowledge/projects/README.md`

### Removed
- `core/knowledge/pure-ralph/` — Delete this directory. Pure Ralph patterns have been merged into the Ralph methodology core.

### New Features to Adopt

**INDEX.md System:** Create INDEX.md files at key directories. See `core/knowledge/hq-core/index-md-spec.md` for spec. Commands like `/checkpoint`, `/handoff`, `/prd` auto-update them.

**Knowledge Repos (Optional):** Knowledge folders can be independent git repos symlinked into HQ. See "Knowledge Repos" section in CLAUDE.md.

**Learning System:** `/learn` and `/remember` now inject rules directly into source files. Add a `## Learned Rules` section to your CLAUDE.md and `## Rules` sections to your commands.

### Migration Steps
1. Copy `.claude/commands/learn.md` (new command)
2. Copy all updated `.claude/commands/*.md`
3. Merge `.claude/CLAUDE.md` — add INDEX.md System, Knowledge Repos, Learning System, Auto-Learn, and Search rules sections
4. Copy `core/workers/registry.yaml`
5. Copy new knowledge files (`Ralph/11-team-training-guide.md`, `hq-core/checkpoint-schema.json`, `hq-core/index-md-spec.md`)
6. Copy updated knowledge and worker files
7. Delete `core/knowledge/pure-ralph/`
8. Run `/search-reindex`
9. Run `/cleanup --reindex` to generate INDEX.md files

### Breaking Changes
- `core/knowledge/pure-ralph/` removed — if you reference it, update to `core/knowledge/Ralph/`

---

## Migrating to v3.3.0 (from v3.2.0)

### What Changed
Commands split into public (16) and private (15). Only generic, reusable commands ship in the starter kit now. Content, design, and company-specific commands are private.

### New Feature: Auto-Handoff
Claude auto-runs `/handoff` at 70% context usage. This is in `.claude/CLAUDE.md` — copy the "Auto-Handoff (Context Limit)" section to yours.

### Removed Commands (now private)
If you use any of these, keep your existing copies — they just won't be in future starter kit releases:
- Content: `contentidea`, `suggestposts`, `scheduleposts`, `preview-post`, `post-now`, `humanize`
- Design: `generateimage`, `svg`, `style-american-industrial`, `design-iterate`
- System: `publish-kit`, `pure-ralph`, `hq-sync`

### Migration Steps
1. Copy `.claude/CLAUDE.md` from starter kit (or merge the Auto-Handoff section into yours)
2. Copy refreshed `.claude/commands/*.md` for the 16 public commands
3. Copy `core/workers/registry.yaml`
4. Run `/search-reindex`

### Breaking Changes
- (none — removed commands still work if you keep your local copies)

---

## Migrating to v3.2.0 (from v3.1.0)

### New Skills
Copy this file to `.claude/commands/`:
- `remember.md` — Capture learnings when things don't work right

### Updated Files
All 28 existing commands have been refreshed. Copy from starter kit to your HQ:
- `.claude/commands/*.md` (all public commands)
- `.claude/CLAUDE.md`
- `core/workers/registry.yaml`

### Breaking Changes
- (none)

### Migration Steps
1. Copy `.claude/commands/remember.md` to your HQ
2. Optionally update other commands by copying from starter kit
3. Run `/search-reindex` to include new command in search

---

## Migrating to v3.1.0 (from v3.0.0)

### Breaking Changes
- **`/newproject` removed** -- Merged into `/prd`. Delete `.claude/commands/newproject.md` from your HQ.
- **prd.json now required** -- `/run-project` and `/execute-task` require `projects/{name}/prd.json` with a `userStories` array. README.md is no longer accepted as a fallback.
- **`features` key deprecated** -- If your prd.json files use `"features"` instead of `"userStories"`, rename the key. Also rename `"acceptance_criteria"` to `"acceptanceCriteria"` (camelCase).

### Updated Skills
Replace these files in `.claude/commands/`:
- `prd.md` -- **Major rewrite.** Now outputs both `prd.json` (source of truth) and `README.md` (derived). Includes orchestrator registration, beads sync, and execution choice.
- `run-project.md` -- Strict prd.json validation on load. Hard stop if missing.
- `execute-task.md` -- Same strict validation.
- `newworker.md` -- `/newproject` references updated to `/prd`
- `nexttask.md` -- `/newproject` reference updated to `/prd`

### Migration Steps
1. Delete `.claude/commands/newproject.md`
2. Copy updated `prd.md`, `run-project.md`, `execute-task.md`, `newworker.md`, `nexttask.md`
3. If you have prd.json files using `"features"`, rename to `"userStories"` and `"acceptance_criteria"` to `"acceptanceCriteria"`
4. If you have projects with only README.md (no prd.json), run `/prd {project}` to generate the JSON

---

## Migrating to v3.0.0 (from v2.1.0)

### New Skills
Copy these files to your `.claude/commands/`:
- `humanize.md` - Remove AI writing patterns from drafts
- `pure-ralph.md` - External terminal orchestrator for autonomous PRD execution
- `svg.md` - Generate minimalist abstract white line SVG graphics
- `search-reindex.md` - Reindex and re-embed HQ for qmd search

### Updated Skills
The following skills have significant updates. Review and merge:
- `search.md` - **Breaking:** Complete rewrite to qmd-powered search (BM25, semantic, hybrid). Includes grep fallback if qmd is not installed.
- `handoff.md` - Added step 4: search index update (`qmd update && qmd embed`)
- `run-project.md` - Updated orchestration pattern with inline worker pipeline execution
- `execute-task.md` - Worker names aligned with dev-team IDs (`backend-dev`, `frontend-dev`, `dev-qa-tester`, etc.); added `content` task type

### New Knowledge
Copy these directories to your `core/knowledge/`:
- `pure-ralph/` - Branch workflow, learnings
- `hq/` - Checkpoint schema
- `projects/` - Project creation guidelines and templates
- `design-styles/ethereal-abstract.md` - Ethereal abstract style guide
- `design-styles/liminal-portal.md` - Liminal portal style guide

### Install qmd (Optional)
[qmd](https://github.com/tobi/qmd) powers the new `/search` command with semantic + full-text search.

```bash
# Install qmd (requires Go)
go install github.com/tobi/qmd@latest

# Index your HQ
cd ~/HQ
qmd update && qmd embed
```

If qmd is not installed, `/search` falls back to grep-based search.

### Breaking Changes
- `/search` syntax changed from grep-based to qmd queries. Install qmd or use the built-in fallback.

---

## Migrating to v2.1.0 (from v2.0.0)

### New Skills
Copy these files to your `.claude/commands/`:
- `generateimage.md` - Generate images via Gemini Nano Banana
- `post-now.md` - Post to X/LinkedIn immediately
- `preview-post.md` - Preview drafts, select images, approve posting
- `publish-kit.md` - Sync your HQ to hq-starter-kit

### Updated Skills
The following skills have significant updates. Review and merge:
- `contentidea.md` - Enhanced multi-platform workflow with:
  - Image generation per approved style (7 styles)
  - Visual prompt patterns organized by theme
  - Anti-AI slop rules (humanizer section)
  - Preview site sync workflow
- `scheduleposts.md` - Improved queue management
- `style-american-industrial.md` - Expanded monochrome variant with CSS variables
- `metrics.md`, `run.md`, `search.md`, `suggestposts.md` - Generalized examples

### New Directories (if using image generation)
```
workspace/social-drafts/images/   # Generated images for posts
repos/private/social-drafts/      # Preview site (optional)
```

### Breaking Changes
None in this release.

---

## Migrating to v2.0.0 (from v1.x)

### Major Changes
v2.0.0 is a significant upgrade with new project orchestration and 18 workers.

### New Directories
Create these if missing:
```
workspace/
  threads/          # Auto-saved sessions
  orchestrator/     # Project state
  learnings/        # Captured insights
  content-ideas/    # Idea inbox
social-content/
  drafts/
    x/              # X/Twitter drafts
    linkedin/       # LinkedIn drafts
```

### New Skills
Copy all files from `.claude/commands/`.

### New Workers
Copy `core/workers/dev-team/` and `core/workers/content-*/` directories.

### Knowledge Bases
Copy new knowledge directories:
- `core/knowledge/hq-core/`
- `core/knowledge/ai-security-framework/`
- `core/knowledge/design-styles/`
- `core/knowledge/dev-team/`

### Registry Update
Replace `core/workers/registry.yaml` with the new v2.0 format.

### Breaking Changes
- Registry format changed (version: "2.0")
- Thread format changed (see `core/knowledge/hq-core/thread-schema.md`)
- `/ralph-loop` renamed to `/run-project`

---

## General Update Process

1. **Backup your HQ** before updating
2. **Diff files** before overwriting - preserve your customizations
3. **Merge knowledge** - don't overwrite, combine with your additions
4. **Test skills** after copying to ensure they work with your setup
