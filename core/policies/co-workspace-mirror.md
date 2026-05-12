---
id: co-workspace-mirror
title: Per-Company Workspace Mirror — Hardlink Sessions + Audit Log
scope: cross-cutting
trigger: checkpoint, handoff, prd, run-project, execute-task, newcompany
enforcement: soft
public: true
created: 2026-05-02
---

## Rule

Every HQ session that touches a company is mirrored into that company's
`workspace/` folder so each company has its own audit trail of sessions.

**Layout (per company):**

```
companies/{co}/workspace/
  index.jsonl              ← committed to git, append-only audit log
  sessions/{thread-id}.json ← gitignored, hardlinked from workspace/threads/
  .gitignore                ← excludes sessions/, tracks index.jsonl
```

**The canonical session store at `workspace/threads/{thread-id}.json` remains the
source of truth.** Mirroring is purely additive — no thread file is moved or
modified by mirror logic.

### When mirroring fires

A PostToolUse(Write|Edit) hook (`mirror-thread-to-company.sh`) reads
`metadata.company` from any `workspace/threads/T-*.json` file written by tool
calls. For each company in that field:

1. `mkdir -p companies/{co}/workspace/sessions/`
2. Create per-company `.gitignore` if missing.
3. `ln -f` the thread file into `sessions/{thread-id}.json` (zero-copy hardlink).
4. Append a row to `index.jsonl` with `{thread_id, ts, kind, company, title}`.
5. Skip if the `(thread_id, ts, kind)` tuple is already present (idempotent).

The hook silently no-ops when:
- `tool_name` is not `Write` or `Edit`.
- `file_path` doesn't match `workspace/threads/T-*.json`.
- `metadata.company` is missing (HQ-infra-only sessions never mirror).

### Multi-company sessions

If `metadata.company` is an array, the mirror writes to **every** touched
company. The audit trail is duplicated by design so each company's view is
complete.

### Sub-sessions

Worker-spawned sub-sessions inherit the parent thread's company assignment.
Sub-sessions do not re-resolve the company independently.

### Cloud durability

`companies/{co}/workspace/` is synced via the existing `hq-sync` infrastructure
(no server-side allow-list change required — the published `@indigoai-us/hq-cloud`
sync is permissive by default with a `.hqignore`-style deny list, and
`workspace/` is not in any default-ignored pattern). For users running the
AppBar daemon, mirror writes are picked up and synced automatically. CLI-only
users sync manually via `/hq-sync`.

### Hardlink portability

Hardlinks only work within a single filesystem. HQ root and `companies/` are on
the same volume by convention. If a future migration splits them across volumes,
the hook falls back to `cp -f` automatically (built into the script — `ln -f "$FILE_PATH" "$TARGET" || cp -f "$FILE_PATH" "$TARGET"`), so mirroring continues to work; only the zero-disk-cost property is lost. The `index.jsonl` audit log
is a true file regardless, so it always survives.

### Append-only conflict semantics

Bidirectional sync of `index.jsonl` from two machines simultaneously may
produce divergent rows. The `(thread_id, ts, kind)` tuple is the dedup key —
manual reconciliation should union both sides, not pick a winner. The standard
`hq-sync --on-conflict keep` strategy will produce a `.conflict-*` sidecar
file in this case, which `/resolve-conflicts` handles interactively.

### Retention

Forever, both locally and in the cloud. No pruning. With ~12 active companies
and a normal session cadence, expected growth is well under 100MB/year per
company — negligible at standard S3 pricing.

## Rationale

**Why mirror at all?** Today, HQ session history lives globally in
`workspace/threads/` with 100+ files. Asking "what work happened on company X?"
requires grepping every file. The per-company mirror puts each company's
session history inside its own directory, alongside its other artifacts.

**Why hardlinks?** Disk-cheap (zero duplication), automatically stay in sync if
the canonical thread is ever updated in place, and require no special tooling
to read — every standard file tool sees both paths as the same file.

**Why a separate committed `index.jsonl`?** Hardlinks live on one machine; git
+ cloud sync are how the audit trail travels. The committed JSONL gives
collaborators the index of what happened (via git clone), while the actual
session content lives in cloud-synced `sessions/` (richer detail for those
with cloud access).

**Why skip threads with no `metadata.company`?** Most HQ work is HQ-infra
itself (skills, policies, orchestrator) and isn't tied to any one company. A
mirror of HQ-infra sessions doesn't aid any company's audit trail and would
create noise.

## Implementation Files

- Hook: `.claude/hooks/mirror-thread-to-company.sh`
- Hook gate: `.claude/hooks/hook-gate.sh` (registered in standard + strict profiles)
- Wiring: `.claude/settings.json` PostToolUse(Write) and PostToolUse(Edit)
- Backfill: `core/scripts/backfill-workspace-mirror.sh` (idempotent — safe to re-run)
- Scaffold: `.claude/commands/newcompany.md` creates `workspace/` on new company creation
- Auto-checkpoint exclusion: `.claude/hooks/auto-checkpoint-trigger.sh` skips
  writes to `companies/*/workspace/sessions/`, `index.jsonl`, and `.gitignore`
  to prevent loops.
