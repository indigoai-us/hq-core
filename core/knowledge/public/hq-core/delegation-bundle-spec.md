# Delegation bundle — manifest.json v1 schema

A **delegation bundle** is the portable, self-describing artifact `/delegate`
builds when a project is handed from one principal to another. It lives at
`workspace/delegations/<delegationId>/` and contains:

- `manifest.json` — the machine-readable contract described here
- `BRIEF.md` — full-prose orientation for a reader who has never seen the
  project
- `PICKUP-PROMPT.md` — generated later (US-007) from the manifest; the
  self-sufficient prompt delivered by DM

The manifest is the **single source of truth** for the whole delegation: the
grant step, the verification probe, and the pickup prompt are all generated
from it. Nothing downstream may invent a path, prefix, or secret name that is
not in the manifest, and nothing in the manifest may be silently skipped.

Builder: `core/scripts/hq-delegate-bundle.sh build --company <slug>
--project <name> --to <principal> [--to-kind person|agent] [--to-name <name>]
[--mode transfer|share]`. Prints the `delegationId` on stdout.

## Top-level fields

| Field | Type | Meaning |
|---|---|---|
| `schemaVersion` | number | Always `1` for this spec. |
| `delegationId` | string | `dlg-<UTCstamp>-<project>` — also the bundle directory name. |
| `createdAt` | string | ISO-8601 UTC creation time. |
| `mode` | `"transfer"` \| `"share"` | `transfer` reassigns ownership (board, PRD, work mesh); `share` grants access but leaves ownership with the delegator. |
| `from` | object | `{email, personUid}` of the delegator — resolved from `hq whoami` when available, else `null`s (filled before send). |
| `to` | object | `{kind, principal, displayName}` — `kind` is `person` or `agent`; `principal` is a **confirmed** email, `prs_…`, or `agt_…` (resolved by `hq-delegate-resolve.sh`, never a guessed name). |
| `company` | string | Company slug. Delegation never crosses a company boundary. |
| `project` | object | `{name, prdPath, boardId}` — `prdPath` is HQ-root-relative; `boardId` is the `companies/<co>/board.json` project id or `null`. |
| `vaultPrefixes` | array | What gets granted — see below. |
| `repo` | object \| `null` | Code handover state — see below. `null` when the project has no `metadata.repoPath`. |
| `secrets` | array | Secret **names** (never values) the recipient is granted — filled by the US-005 step; `[]` until then, `{skipped: true}` recorded when `--no-secrets`. |
| `knowledge` | array | HQ-root-relative knowledge paths referenced by the PRD (for the brief and pickup prompt). |
| `policies` | array | HQ-root-relative policy paths referenced by the PRD. |
| `checksums` | object | `{<HQ-root-relative path>: <sha256>}` for every file in the project dossier at freeze time (capped at 200 files). Lets the recipient verify integrity after pulling. |
| `status` | string | Delegation state machine — see below. |

## `vaultPrefixes[]` entries

```json
{ "prefix": "projects/hq-delegate-command/", "permission": "write", "reason": "project dossier" }
```

- `prefix` — **bucket-relative** (never prefixed with `companies/<slug>/`) and
  **always trailing-slash folder form**, per the hq-files prefix conventions. A
  bare prefix would degrade to a single literal key and grant nothing useful;
  the builder hard-fails rather than emit one.
- `permission` — `write` on the project dossier, `read` on referenced
  knowledge/policy folders. Individual knowledge *files* are mapped to their
  containing folder.
- `reason` — human-readable justification, surfaced in the confirmation step.

After the grant step verifies a prefix via ACL read-back, it may annotate the
entry with `verifiedAt` and the confirmed permission.

## `repo` block

```json
{ "path": "repos/public/hq-core", "remote": "git@github.com:org/repo.git",
  "branch": "feature/x", "baseBranch": "main", "headSha": "abc123…",
  "dirtyFiles": [], "accessVerified": false }
```

The builder records `path`, `branch`, and `baseBranch` from the PRD; the
US-004 handover step fills `remote` and `headSha`, lists uncommitted work in
`dirtyFiles[]` (called out in the brief as **not transferred**), and sets
`accessVerified` after a read-only `gh` access check. Repo paths never appear
in `vaultPrefixes[]` and repo content is never pushed to the vault.

## `status` state machine

```
building → granted → verified → sent
```

- `building` — bundle written, nothing granted yet.
- `granted` — vault ACL grants written and read back successfully (US-003).
- `verified` — every prefix probed reachable via `hq files browse` (US-008).
- `sent` — DM delivered; manifest records the DM `eventId`.

A failed step leaves the last successful status, so a re-run resumes instead
of repeating grants. `--dry-run` never creates a bundle at all.

## Hard safety rules

Two rules apply to every artifact in the bundle and everything generated from
it (policy `hq-delegate-never-inlines-secrets-or-share-urls`):

1. **No secret value, ever.** Secrets appear by *name* only and are consumed
   through `hq run` / `hq secrets exec`. The builder scans its own manifest and
   brief against the shared secret patterns
   (`core/scripts/lib/secret-patterns.sh`, mirroring
   `.claude/hooks/detect-secrets.sh`) and fails closed on any match.
2. **No share-session URLs.** Delegation uses direct ACL grants only. A
   share-session URL is a live capability token and must never be minted or
   embedded by any delegation step.
