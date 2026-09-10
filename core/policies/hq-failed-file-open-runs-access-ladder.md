---
id: hq-failed-file-open-runs-access-ladder
title: A failed open of a companies/ path runs the access ladder before "file does not exist"
scope: global
trigger: any Read, cat, open, or Glob of a companies/<slug>/… path that fails (ENOENT, not found, permission denied, 403), or a user asking for a company file that cannot be found
when: companies && (ENOENT || 403 || denied || forbidden || NoSuchKey || missing || nonexistent)
on: [PreToolUse, PostToolUse, UserPromptSubmit]
enforcement: hard
public: true
version: 1
created: 2026-09-08
updated: 2026-09-08
source: project:self-healing-sync-share-access
tags: [infrastructure, sync, access]
---

## Rule

When a read, cat, open, or lookup of a `companies/<slug>/…` path fails, you
MUST run `/hq-access <path>` (which runs `hq access <path> --json`, or the
backup ladder on older CLIs) BEFORE telling the user the file does not exist.

The reply must then name exactly one of the three outcomes:

1. **never created** — the path is not in the vault.
2. **not synced, now fixed** — it existed in the vault; it has been fetched and pinned and is now local at the absolute path you report.
3. **no access, owner asked** — it exists but the caller lacks a grant; the grantor's email was shown, the user confirmed once, and the request DM went out (or was already sent within 24h).

Never reply "the file does not exist", "no such file", or "I cannot find it"
for a `companies/` path without that classification. Never auto-pick when the
ladder finds several matching keys — ask the user. Never send the owner DM
without the single explicit confirmation, and never bypass a sync
bulk-asymmetry circuit breaker while repairing.

## Rationale

Clients see one bare error — "file does not exist" — for three different
causes: the file was never created, it exists but this machine has not synced
it (sync mode, stale sync, pruned orphan), or it exists and the person lacks a
grant. Every one of those lands on the company owner as a manual sync
explanation or a manual grant, which is the support load clients complain
about. All the rungs already exist as CLI commands (`files search|acl|get`,
`sync status|doctor`, `members list`, `people resolve`, `dm`); the gap was
that nothing chained them at the moment of failure. `hq access` (hq-cli >=
5.109.0) and the `/hq-access` skill close that gap; this policy makes the
ladder fire at the trigger instead of relying on the user to know it exists.
