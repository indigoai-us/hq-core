---
id: company-skill-bridge
title: Company-level skills and commands auto-mirror to root with company prefix
scope: global
trigger: skill_creation, command_creation, write_to_company_skills_dir, write_to_company_commands_dir
enforcement: hard
public: true
version: 1
created: 2026-04-29
---

## Rule

Every top-level skill or command authored under a company folder gets a root-level slash-command counterpart, automatically, via symlink. Authors write to the company folder; the bridge handles the rest.

| Source (canonical) | Mirror (auto-created) | Invocation |
|---|---|---|
| `companies/{co}/skills/{name}/SKILL.md` | `.claude/skills/{prefix}-{name}/` → relative symlink to source dir | `/{prefix}-{name}` |
| `companies/{co}/skills/{name}.md` (flat form) | `.claude/skills/{prefix}-{name}.md` → relative symlink | `/{prefix}-{name}` |
| `companies/{co}/commands/{name}.md` | `.claude/commands/{prefix}-{name}.md` → relative symlink | `/{prefix}-{name}` |

The `{prefix}` comes from `companies.{co}.prefix` in `companies/manifest.yaml` — auto-computed when the company is scaffolded (see Prefix algorithm below).

### Bridge contract

- **Authors write to the company folder.** Do not hand-create files under `.claude/skills/{prefix}-*` or `.claude/commands/{prefix}-*`. The PreToolUse hook `route-company-skill-creation` blocks direct writes to mirror paths and points the author at the canonical company-folder path.
- **Mirrors are symlinks, not copies.** Editing the source (`companies/{co}/skills/{name}/SKILL.md`) immediately changes what `/{prefix}-{name}` invokes — no rebuild step.
- **Symlinks are relative**, so HQ remains portable across machines.
- **Idempotent.** Re-running the auto-mirror on an already-correct symlink is a no-op. A symlink that points elsewhere is logged and skipped (collisions are human-resolved, not auto).
- **Backfill exists.** `scripts/backfill-company-skill-mirrors.sh` walks every company and ensures every top-level skill/command has its mirror. Safe to re-run.

### Prefix algorithm

When `/newcompany {slug}` runs, it computes `prefix` and writes it into the manifest entry:

1. Take the manifest key (e.g. `acmestudio`, `holler-mgmt`, `new-american-codex`)
2. Strip hyphens, lowercase (`acmestudio`, `hollermgmt`, `newamericancodex`)
3. Take the **first 3 characters** (`acm`, `hol`, `new`)
4. If that collides with an existing prefix in the manifest → take **first 4 characters** (`acme`, `holl`, `newa`)
5. If that still collides → suffix `-2`, then `-3`, etc.

The 18 companies present at bridge launch (no collisions, all 3-char):

```
acmestudio      acm     tonal               ton
indigo          ind     moonflow            moo
personal        per     dominion            dom
golden-thread   gol     hpo                 hpo
haven-slay      hav     amass               ama
holler-mgmt     hol     magical-moments     mag
brandstage      bra     dripkit             dri
estate-manager  est     new-american-codex  new
keptwork        kep     empire-os           emp
```

### The two hooks

| Hook | Event | Matcher | What it does |
|---|---|---|---|
| `auto-mirror-company-skill.sh` | PostToolUse | `Write` | After a Write to `companies/{co}/skills/{name}/SKILL.md`, `companies/{co}/skills/{name}.md`, or `companies/{co}/commands/{name}.md`, resolves `{co}` → `{prefix}` from `companies/manifest.yaml` and creates the relative symlink at `.claude/skills/{prefix}-{name}` or `.claude/commands/{prefix}-{name}.md`. Idempotent. Missing prefix → stderr nudge, exit 0 (lazy — does not block the write). |
| `route-company-skill-creation.sh` | PreToolUse | `Write` | If a Write targets `.claude/skills/{prefix}-*` or `.claude/commands/{prefix}-*.md` and `{prefix}` resolves to a known company, **blocks with exit 2** and points the author at the canonical company-folder path. Unknown prefix → passthrough (does not interfere with non-bridge skills like `/deploy`, `/checkpoint`, etc.). |

Both hooks route through `.claude/hooks/hook-gate.sh` for profile control — `HQ_HOOK_PROFILE=minimal` disables them both; `standard` (default) enables them.

### Override env var

```bash
HQ_ALLOW_DIRECT_PREFIX_WRITE=1
```

Set this only when you genuinely need to write directly to a `.claude/skills/{prefix}-*` or `.claude/commands/{prefix}-*` path (rare — e.g. emergency repair of a broken symlink). The route hook will let the write through. Same convention as `HQ_BYPASS_CORE_PROTECT` and `HQ_IGNORE_ACTIVE_RUNS`.

### Worker-nested skills are NOT mirrored

Skills under `companies/{co}/workers/{worker}/skills/{name}/SKILL.md` are out of scope for the bridge. Reasons:

1. **They already have a stable invocation:** `/run {worker} {skill}`. Adding a second `/{prefix}-{worker}-{skill}` form would just create two ways to call the same thing.
2. **Worker skills are scoped, not global.** A worker's skill often assumes the worker's environment (knowledge pointers, credentials, tool subset). Promoting it to a top-level slash command would invite calls without that scoping.
3. **Manifest hygiene:** the prefix maps a *company*, not a *worker* — adding worker-nested skills would force a flatter namespace and increase collision risk.

If a worker skill genuinely deserves global access, **lift it** to `companies/{co}/skills/{name}/SKILL.md` (top-level), and the bridge picks it up automatically.

### Manual prefix collision resolution

If two companies' prefixes collide and the auto-suffix `-2`/`-3` is unsatisfying, edit `companies/manifest.yaml` directly:

```yaml
companies:
  someco:
    prefix: scx     # ← change to a hand-picked unique 2-4 char string
```

Then re-run the backfill so any existing mirrors are regenerated under the new prefix:

```bash
# Remove old mirrors first (safe — they're symlinks)
find .claude/skills -maxdepth 1 -type l -name 'OLD_PREFIX-*' -delete
find .claude/commands -maxdepth 1 -type l -name 'OLD_PREFIX-*.md' -delete

bash scripts/backfill-company-skill-mirrors.sh
```

Constraints: prefix MUST be 2–4 lowercase alphanumeric chars (matches the route hook's regex), and MUST be unique across `companies/manifest.yaml`.

## Verification

1. Create a throwaway top-level company skill at `companies/indigo/skills/_test-bridge/SKILL.md` → confirm `.claude/skills/ind-_test-bridge/` symlink appears, resolves to the source dir.
2. Attempt to Write directly to `.claude/skills/ind-foo/SKILL.md` → blocked with stderr message; set `HQ_ALLOW_DIRECT_PREFIX_WRITE=1` and retry → passthrough.
3. Run `bash scripts/backfill-company-skill-mirrors.sh` twice → first run reports symlinks created, second run reports zero new symlinks (idempotent).
4. Confirm `/ind-demo-hq` appears in the live skills list (already verified mid-session at bridge launch).
5. Worker-nested skill Write (e.g. `companies/acmestudio/workers/deploy/skills/deploy.md`) → no mirror created at `.claude/skills/acm-deploy/` (out of scope by design).

## Related

- `auto-mirror-company-skill.sh` — `.claude/hooks/auto-mirror-company-skill.sh`
- `route-company-skill-creation.sh` — `.claude/hooks/route-company-skill-creation.sh`
- Backfill — `scripts/backfill-company-skill-mirrors.sh`
- Newcompany prefix step — `.claude/commands/newcompany.md`
- Manifest source of truth — `companies/manifest.yaml` (`companies.{co}.prefix`)
