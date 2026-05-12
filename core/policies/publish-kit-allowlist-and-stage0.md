---
id: publish-kit-allowlist-and-stage0
title: Strict allowlist source scope, Stage 0 rebuild-from-scratch, and self-exclude pipeline artifacts
scope: command
trigger: "/publish-kit, /stage-kit — source-set resolution, walker enumeration, allowlist propagation, opt-in gate enumeration"
enforcement: soft
created: 2026-04-28
supersedes: publish-kit-source-is-strict-allowlist, hq-cmd-publish-kit-never-ship-pipeline-artifacts, publish-kit-enumerate-opt-in-gate
public: true
---

## Rule

publish-kit's source resolution is governed by three composable rules: a strict allowlist of HQ-core paths (with Stage 0 rebuild-from-scratch), a self-exclude carve-out for the pipeline's own artifacts, and an opt-in-gate enumeration discipline so plans don't over-promise what will ship.

### A. Source scope is a strict allowlist — never traverse owner-private dirs

publish-kit MUST treat its source scope as a **strict allowlist** of HQ-core paths. The walker never traverses owner-private top-level directories. The target directory `repos/public/hq-core/` (standalone scaffold repo `indigoai-us/hq-core`, retargeted 2026-04-21 from the retired `repos/public/hq/template/` monorepo subdir) is **rebuilt from scratch** on every full release (see Stage 0 in `.claude/commands/publish-kit.md`) — no overlay-without-delete, no drift across releases.

#### Canonical source (machine-readable)

As of 2026-04-22 (US-002, `projects/hq-kit-app`), the canonical allowlist is the machine-readable YAML at `.claude/kit/allowlist.yaml`, validated by `.claude/kit/allowlist.schema.json`. The markdown tables in `.claude/commands/publish-kit.md` (`## What to Sync` + `### Starter scaffolds`) are a **derived, human-readable mirror** retained for skill readability during the parallel-skills window.

Any change to the allowlist MUST update `.claude/kit/allowlist.yaml` **first**, then mirror into the markdown tables. The parity gate `scripts/check-kit-allowlist-parity.ts` expands both into file-path sets against the current HQ tree and fails CI on any mismatch. Until the hq-kit-app cutover (US-017) deletes the markdown skill, both sources must agree byte-for-byte on their expanded file sets.

Tooling:
- `bun scripts/check-kit-allowlist-parity.ts` — parity gate (exit 1 on drift)
- `bun scripts/extract-kit-allowlist.ts` — one-shot markdown-table dumper (diagnostic only)

#### In-scope (allowlist)

The walker MAY include only these top-level source paths:

**Core HQ infrastructure:**
- `.claude/commands/*.md` (filter: `visibility: public`)
- `.claude/policies/*.md` (filter: `scope: global` or `scope: command`, with opt-in `public: true` for globals; apply Policy Context Stripping)
- `.claude/skills/*/` (filter: has `SKILL.md`, not a symlink, not `g-*`)
- `.claude/hooks/*.sh`
- `.claude/scripts/*.sh`
- `.claude/CLAUDE.md`
- `.claude/settings.json` (filter: `outputStyle` + new `env` keys; permissions/hooks stay target-specific)
- `.claude/scrub-denylist.yaml` (thin defensive form)
- `workers/public/**` (entire tree; filter `registry.yaml` to `visibility: public` only; **exclude pack-owned** — see Pack-owned excludes below)
- `knowledge/public/**` (entire tree; **exclude pack-owned** — see Pack-owned excludes below)
- `modules/modules.yaml` (scrub company-specific entries)
- `scripts/*.sh` (named allowlist — see publish-kit.md "What to Sync" table)
- `prompts/` (entire dir — prompt templates for orchestrator)
- `USER-GUIDE.md`
- `.ignore`

**Named single-file remaps:**
- `workspace/orchestrator/monitor-project.sh` → `.claude/scripts/monitor-project.sh` (only file under `workspace/` that is ever published)

**Starter scaffolds (intentional, user-approved 2026-04-18):**
- `starter-projects/` (entire dir — bootstrap templates for consumers)
- `companies/_template/` (scaffold dir only; `companies/manifest.yaml` ships as a single-entry `personal` starter)
- `contacts/_example.yaml` (example contact schema)
- `prompts/pure-ralph-base.md` (covered by `prompts/` above)
- `tools/queue-curiosity.ts`, `tools/reindex.ts`, `tools/tag-inventory.sh` (kit-level tools)
- `settings/orchestrator.yaml`, `settings/pure-ralph.json` (default starter configs; scrub before ship)
- Empty-dir `.gitkeep` scaffolds under `workspace/{drafts,checkpoints,scratch,threads,learnings,orchestrator,reports}/`, `social-content/{images,drafts/x,drafts/linkedin}/`, `data/journal/`, `projects/`, `repos/{private,public}/`
- `packages/README.md` (empty-packages scaffold — documents pack install convention; real pack dirs populated by `hq install` on the consumer side)

#### Pack-owned excludes (hard block — shipped via `hq install`, not `publish-kit`)

The following paths live inside `workers/public/` / `knowledge/public/` / `scripts/` (and thus sit inside the allowlist above) but are **owned by `@indigoai-us/hq-pack-*` packs**. They are shipped to consumers via `hq install` against the hq monorepo (`github:indigoai-us/hq#packages/hq-pack-*@<ref>` git-subpath transport), NOT by `publish-kit`. Emitting them here would double-publish the same content under two transports and defeat the hq-core/hq-pack split landed 2026-04-21.

- `workers/public/impeccable-designer/` (deprecated 2026-04-15 — kept in HQ for legacy worker resolution only)
- `workers/public/sample-worker/` (owner-only scratch worker)
- `workers/public/gemini-*/` (shipped by `hq-pack-gemini`)
- `workers/public/gstack-team/` (shipped by `hq-pack-gstack`)
- `knowledge/public/impeccable/` (deprecated alongside impeccable-designer)
- `knowledge/public/design-styles/` (shipped by `hq-pack-design-styles`)
- `knowledge/public/design-quality/` (shipped by `hq-pack-design-quality`)
- `knowledge/public/gemini-cli/` (shipped by `hq-pack-gemini`)
- `scripts/gstack-bridge.sh` (shipped by `hq-pack-gstack`)

The walker MUST apply this exclusion list AFTER the allowlist walk but BEFORE emit. Publish-kit.md mirrors this list as the `PACK_OWNED_EXCLUDES` array in its Stage 0.5 allowlist assertion; both enumerations MUST stay in sync.

#### Never-traverse (denylist — hard block)

The walker MUST NEVER read from, copy from, or emit any file under:

- `companies/*/` except the explicit starter carve-out `companies/_template/` and a minimal `companies/manifest.yaml` (personal starter only)
- `projects/*/` except intentionally-named starter projects published through `starter-projects/` (real owner PRDs under `projects/` are **never** shipped)
- `workspace/*/` except the named single-file remap `workspace/orchestrator/monitor-project.sh` (no other files from `workspace/` may ship — no reports, content-ideas, ralph-test, insights, etc.)
- `social-content/drafts/*.md`, `social-content/drafts/**/*.png`, `social-content/images/*` (only `.gitkeep` scaffolds of these dirs may ship)
- `repos/private/**`, `repos/public/**` (only the `.gitkeep`-scaffolded empty dirs may ship)
- `agents-profile.md`, `agents-companies.md`, `INDEX.md` (owner-scoped)
- `.obsidian/**` (owner Obsidian vault state — always leak)
- `.claude/settings.local.json` (owner-local overrides)
- `.cache_ggshield`, `.DS_Store`, any other dotcache or OS cruft

#### Target directory discipline (rebuild-from-scratch)

Stage 0 of `/publish-kit` (full release mode) MUST:

1. Assert `$TARGET_DIR = repos/public/hq-core` is within a git repo
2. `rm -rf "$TARGET_DIR"` then `mkdir -p "$TARGET_DIR"` — blank slate
3. Emit every file purely from the allowlist walk (minus `PACK_OWNED_EXCLUDES`)
4. Let the resulting git diff against the prior HEAD reveal adds/updates/deletes naturally (no need to track deletions separately)

This ensures the target tree is a **pure function** of the source allowlist. Drift becomes impossible by construction: any file in the target that isn't emitted by the walker simply doesn't survive to the next release.

**Patch mode (`--item ...`)** still operates file-by-file and may overlay into the target without the rebuild; patch mode inherits the allowlist but skips Stage 0.

### B. Never ship publish-kit/stage-kit/scrub-denylist artifacts to the public template

NEVER sync publish-pipeline artifacts into the public target tree. The pipeline is an owner-side build tool — template users have no `/publish-kit` command, no HQ-core vs template split, and no publish target of their own. Shipping its machinery is pure dead weight (plus leakage risk).

Excluded from the publish allowlist (self-reference lockout):

- `.claude/commands/publish-kit.md` and `.claude/commands/stage-kit.md`
- `.claude/skills/publish-kit/**` and `.claude/skills/stage-kit/**`
- `.claude/policies/publish-kit-*.md`, `.claude/policies/hq-cmd-publish-kit-*.md`, `.claude/policies/hq-cmd-stage-kit-*.md`, `.claude/policies/stage-kit-*.md`
- Any policy file whose `## Rule` body describes publish-kit, stage-kit, HQ-core boundary discipline, or scrub-denylist semantics
- `.claude/scrub-denylist.yaml`
- `scripts/build-policy-digest.sh`-driven digests that are publish-kit-internal (not the runtime digest — that ships; the scrub working copy does not)
- `scripts/stage-kit*.sh`, `scripts/publish-kit*.sh`, `scripts/hq-template-*.sh` if any exist

Allowed to ship (runtime necessities for template consumers):

- `scripts/build-policy-digest.sh` — template needs it to rebuild its own digest at SessionStart
- `.claude/hooks/load-policies-for-session.sh` — reads the digest at session start
- Policy digest output (`.claude/policies/_digest.md`) — regenerated in target; itself not synced

Enforce in three places:

1. **publish-kit.md allowlist walker** — exclude the above explicitly before any rsync/copy pass
2. **Stage 0 rebuild verification** — after Stage 0 emits the new tree, assert none of the excluded paths exist in the target
3. **Pre-commit hook on the target tree** — block commits that stage any excluded path

### C. Enumerate the publish-kit opt-in gate before claiming tagged policies will ship

ALWAYS: Before telling the user a set of `applies_to`-tagged policies "will ship" via `/publish-kit` or `/stage-kit`, enumerate which actually pass the publish opt-in gate: `scope: command` OR (`scope: global` AND `public: true`). The `applies_to:` tag and the publish gate are orthogonal — tagging N policies does not mean N will propagate. Run a quick frontmatter grep to produce the real count:

```bash
for f in .claude/policies/*.md; do
  scope=$(awk -F': *' '/^scope:/{print $2; exit}' "$f")
  pub=$(awk -F': *' '/^public:/{print $2; exit}' "$f")
  applies=$(grep -c '^applies_to:' "$f")
  [ "$applies" -eq 0 ] && continue
  if [ "$scope" = "command" ] || { [ "$scope" = "global" ] && [ "$pub" = "true" ]; }; then
    echo "SHIPS: $f"
  else
    echo "HELD:  $f ($scope / public=$pub)"
  fi
done
```

Report the SHIPS/HELD split in the plan and stage-kit/publish-kit summaries. Do not collapse the count to just "38 tagged" when only 2 will reach the template.

## Rationale

**A:** publish-kit v11.2.0 spent 3 sessions (~24 wall-clock hours) trying to scrub PII out of ~40 HQ-core files and 128 policies while the root cause was architectural: the walker had no enforced scope, the target dir was never pruned, and company/project/workspace content kept leaking in. The owner's guidance on 2026-04-18: "we need to prevent PII from ending up in these files in the first place" (2026-04-17), "we should not even look into the company folders" (2026-04-18), "why would we be publishing workspace threads?" (2026-04-18). The fix is structural: define the allowlist, never traverse owner-private dirs, rebuild target from scratch. Once this policy is enforced, PII-at-source becomes a non-problem for publish-kit because the walker can't reach into dirs where owner PII lives. Coverage audits: Stage 0 assertion compares `find` output against the allowlist emit log; pre-commit hook scans staged paths against the never-traverse denylist.

**B:** publish-kit v11.2.0 Phase C audit (2026-04-19) found the template had been shipping `/publish-kit` in `USER-GUIDE.md` without ever shipping `.claude/commands/publish-kit.md` — and also shipping scattered publish-kit policies that referenced paths (`companies/`, `workspace/orchestrator/`, `.claude/scrub-denylist.yaml`) the template doesn't expose. Root cause: the allowlist was additive (include HQ-core) without a self-exclude pass for the pipeline that owns the allowlist. A tool that ships itself into its output is always incoherent — the copied version can never be reached by the tool that copies it. Fix: pipeline artifacts are explicitly carved OUT of the allowlist.

**C:** The applies_to plan tagged 38 policies and the plan file implied all 38 would propagate via `/publish-kit`. During stage-kit execution, only 2 of 38 passed the opt-in gate — the rest ship as `public: false` (the new-policy default from the `learn` skill). The plan's implicit promise was wrong, and the user caught it at report time. Enumerating the gate up-front prevents planning drift and makes the per-policy `public: true` review visible as a real TODO rather than an invisible bottleneck.

The unifying principle: publish-kit's output is a **pure function** of an explicit allowlist minus a self-reference carve-out, and any planning that talks about "what will ship" must be evaluated through the same gate the walker uses. Source scope, self-exclusion, and gate enumeration are three views of the same discipline.

