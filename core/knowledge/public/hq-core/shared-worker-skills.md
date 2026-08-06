# Single-source worker-scoped skills

Worker-scoped skills — the ones listed in a worker's `skills:` block, resolving
to files at `{worker}/skills/{skill}.md` — must be **single-sourced** when more
than one worker uses the same skill. A skill shared by copy drifts: editing one
worker's copy leaves the others stale, and over time the copies diverge (a
shared `e2e-testing` splitting into two different versions is the canonical
example). This note is the convention that prevents that.

> Scope: this is only about **worker-scoped** skills. Top-level HQ skills
> (`.claude/skills/{name}/SKILL.md`) are already single-sourced through the
> reindex symlink overlay and are not covered here.

## Mechanism: symlink, not reference-by-path

A shared skill lives **once** as a canonical file in a scope-appropriate
`_shared-skills/` store. Every worker that uses it keeps its normal
`{worker}/skills/{skill}.md` entry, but that entry is a **relative symlink** to
the canonical file.

This is **purely a file-layout change — there is no resolver change.** `/run`
(and its Codex mirror, and `execute-task`/`run-project`) resolve a worker skill
by reading the file at `{worker}/skills/{skill}.md` with the Read tool. A symlink
at that path is followed transparently, so:

- No skill resolver is edited.
- No `worker.yaml` is edited — the skill name still maps to the same path; only
  the file *type* changes (regular file → symlink).
- The workers registry generator is unaffected — it only reads `worker.yaml`,
  never skill files.

Reference-by-path (a shared ref string in `worker.yaml` resolved at load time)
was considered and rejected: it would require teaching every skill consumer to
resolve the ref and rewriting every sharing worker's `skills:` block, for the
same end result.

## Where the canonical file lives (narrowest scope wins)

Put the canonical in the **narrowest scope that contains every sharing worker**,
so the relative symlinks never cross an install/sync boundary:

| Sharers | Canonical location | Ships / syncs via |
|---|---|---|
| Two or more **core** workers | `core/workers/_shared-skills/{skill}.md` | hq-core release → `/update-hq` |
| Workers within one **pack** | `core/packages/<pack>/workers/_shared-skills/{skill}.md` | the pack (self-contained) |
| Workers within one **company** | `companies/<co>/workers/_shared-skills/{skill}.md` | `hq-sync` (tenant-isolated) |

Rules:

- **Per-file symlinks only.** Never symlink a worker's whole `skills/` directory
  — workers mix private and shared skills in the same folder.
- **Relative targets only.** Absolute symlinks break when the tree moves between
  machines, packs, or installs.
- **No cross-scope symlinks.** A company worker must not link into a pack, and a
  pack must not link into another pack. If two sharers live in different scopes,
  the canonical belongs in the narrowest scope that contains both — most often
  that means the shared skill is really scope-local and should be duplicated by
  *intent*, not linked across the boundary.
- The `_shared-skills/` directory contains no `worker.yaml`, so it is never
  mistaken for a worker by the registry generator.

## Migrating existing duplicates

Use `hq core worker share` — it never edits any `worker.yaml` and is dry-run by
default:

```bash
# preview
hq core worker share core/workers e2e-testing \
  core/workers/dev-team/backend-dev/skills/e2e-testing.md \
  core/workers/dev-team/frontend-dev/skills/e2e-testing.md

# apply
hq core worker share --apply core/workers e2e-testing \
  core/workers/dev-team/backend-dev/skills/e2e-testing.md \
  core/workers/dev-team/frontend-dev/skills/e2e-testing.md
```

It promotes the first copy to the canonical and replaces every copy with a
relative symlink. If a copy has **already drifted** from the canonical, it
refuses rather than silently overwriting — reconcile the two versions by hand
first (a deliberate human decision), then re-run. `--force` accepts the
canonical and discards a drifted copy's content; use it only after you've
decided the canonical wins.

Because the change is per-file and additive, migration is safe **one skill at a
time**: an unmigrated copy is still a plain readable file, and a migrated one
reads identically through its link. There is no flag-day.

## Guardrail

`hq core worker lint` fails if two or more **regular** (non-symlink) skill files
share identical content anywhere under the scanned roots (default
`core/workers core/packages`) — i.e. a copy that isn't single-sourced — or if a
shared-skill symlink dangles. It does **not** flag two same-named skills whose
content differs (those are distinct skills that merely share a filename). Pass
explicit roots to widen the scan (e.g. `hq core worker lint companies/<co>/workers`).

This is an **on-demand** check, not a CI gate: run it before promoting worker
changes, or wire it into your own pre-commit. (It lives in the CLI rather than
hq-core CI, so hq-core's checks never depend on a published CLI version.)

## Shipping changes

Core and pack `_shared-skills/` stores and their symlinks are release-owned:
author them in the hq-core staging repo and ship through `/release-hq-core` →
`/promote-hq-core`, never by hand-editing the local shipped `core/` tree (which
`/update-hq` replaces wholesale). Company `_shared-skills/` stores are made under
`companies/<co>/` and travel via `hq-sync`.

## Tooling

The `hq core worker lint` and `hq core worker share` commands are provided by the
HQ CLI (`@indigoai-us/hq-cli`), not by the scaffold. Per the
`scaffold-vs-cli-code-ownership` policy, these cold, explicitly-invoked
operations live in the CLI; run `hq core worker --help` for usage.
