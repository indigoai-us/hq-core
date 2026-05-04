---
name: hq-files
description: Manage file access controls in HQ vault — share prefixes, revoke grants, inspect ACLs, and orchestrate access for individuals or groups.
allowed-tools: Bash(hq:*)
---

# HQ Files

Manage per-prefix file access controls in the HQ vault via the `hq files` CLI. Access is scoped to S3 key prefixes within a company vault, controlled by an ACL layer that resolves grants at vend-time. See also [`hq-secrets`](../hq-secrets/SKILL.md) for secret-level ACLs and group management.

## Requires

- `@indigoai-us/hq-cli` **≥ 5.8.4** — earlier versions return `ACL for undefined` from `hq files acl`, and `hq files share` 404s on prefixes that don't already have an ACL row instead of auto-creating one. Check with `hq --version`; upgrade via `npm i -g @indigoai-us/hq-cli@latest`.

## Commands

| Command | Purpose |
|---------|---------|
| `hq files share <prefix> --with <principal> --permission <level>` | Grant `read` or `write` access on a prefix to a person or group. If no ACL row exists for the prefix, one is auto-created with this grant as its first entry; the success message is `Created ACL and granted ...` instead of `Granted ...`. |
| `hq files unshare <prefix> --with <principal>` | Revoke a grant on a prefix from a person or group |
| `hq files acl <prefix>` | Show the ACL for a prefix: creator, grantees, permissions, open/restricted status, your effective permission |

All commands accept `--company <slug>` to target a specific company. If omitted, the CLI resolves the company from your membership.

## Prefix Conventions

A **prefix** is an S3-style path fragment. The CLI normalizes it before sending to the API:

- **Trailing slash** — automatically appended with `*`. `reports/q3/` → `reports/q3/*`
- **Bare folder with `*`** — passed through unchanged. `reports/q3/*`
- **Exact key** — passed through unchanged. `reports/q3/summary.pdf`

The API rejects prefixes that start with `/` (returns 400). S3-key character constraints (no `\0`, `\n`, traversal patterns) are also enforced server-side.

Examples:
- `reports/` → normalized to `reports/*` — grants access to all keys under `reports/`
- `invoices/2025/*` → grants access to all keys matching that glob
- `README.md` → grants access to exactly that key

## Permission Model

Each ACL entry grants one of two permission levels via the `--permission` flag:

- **`read`** — caller may list, download, and view metadata for files matching the prefix.
- **`write`** — full `read` plus upload, overwrite, and delete.

The CLI accepts only `read` or `write` for `--permission`. The ACL row's **creator** additionally gets effective `admin` automatically via creator-bypass at resolution time — visible as `Your effective permission: admin` in `hq files acl` output even when no entry grants admin explicitly. Mutating the ACL (`share`/`unshare`) requires that effective admin: company owners/admins, or the row's creator.

An ACL may be **open** (all active members get at least `read` automatically) or **restricted** (only explicit entries have access). Most ACLs are created open during the initial backfill; individual grants narrow or extend access on top of the open floor.

**Carve-out Denies:** when a more-specific prefix exists with no entry for a caller, that sub-tree is denied even if a broader prefix grants access. This is enforced at vend-time (STS session policy), not at the ACL API layer.

## Groups as Grantees

`--with` accepts either an email address or a group id matching `grp_[A-Za-z0-9_-]+` (letters, digits, underscores, hyphens — e.g. `grp_backend-team`). A group grant extends the permission to every current member. Adding or removing members from the group adjusts who has file access without touching the ACL.

Group management is shared with secrets (same `hq groups` subcommands). See [`hq-secrets`](../hq-secrets/SKILL.md) for `hq groups create`, `hq groups add`, etc.

## `unshare` Idempotency

`hq files unshare` is safe to call multiple times. When the grant is already absent, the server returns `404`; the CLI treats this as a successful no-op — it prints a green "Grant already absent" message and exits 0. Code or automation calling `unshare` does not need to pre-check whether the grant exists.

## Rules for Agent Workflows

1. **Normalize prefixes before calling `share`.** Pass a trailing slash or an explicit `/*` suffix for folder-level grants. The CLI normalizes for you, but be deliberate: granting `reports/q3.pdf` (exact key) is very different from granting `reports/q3/` (folder).

2. **Always confirm the target company.** Run `hq files acl <prefix> --company <slug>` to inspect before mutating. A grant on the wrong company uid is hard to clean up.

3. **Prefer group grants for teams.** Share `reports/*` with `grp_finance` rather than granting each person individually. Membership changes automatically adjust access.

4. **Do not widen ACLs without explicit human approval.** Granting `write` on a prefix is a privilege escalation. Always confirm with the human before making these changes.

5. **Check your effective permission before attempting mutation.** `hq files acl <prefix>` shows `Your effective permission:` in the output. Attempting `share`/`unshare` without the authority to mutate this ACL (creator or company owner/admin) returns 403.

6. **Do not share exact keys when a folder-level grant is intended.** `reports/q3/summary.pdf` only covers that one file; `reports/q3/` (normalized to `reports/q3/*`) covers the whole folder.

7. **Carve-out awareness.** If a broad prefix (`reports/*`) is open and you also need to restrict `reports/q3/*` for a subset of members, that narrowing is expressed as a more-specific ACL with fewer grants — the vend layer automatically denies the sub-tree for callers without a matching entry. Do not attempt to revoke a broad grant to achieve narrowing; instead, ensure the more-specific prefix has the right entries.

## Common Workflows

### Share a folder with a teammate

```bash
hq files share reports/q3/ --with alice@example.com --permission read --company myco
# → Granted read on reports/q3/* to alice@example.com
```

### Share a folder with a team group

```bash
hq files share invoices/ --with grp_finance --permission read --company myco
```

### Give write access on a subfolder

```bash
hq files share uploads/inbox/ --with bob@example.com --permission write
```

### Revoke access

```bash
hq files unshare reports/q3/ --with alice@example.com --company myco
# → Removed grant for alice@example.com on 'reports/q3/*'
```

### Revoke a grant that may or may not exist (idempotent)

```bash
hq files unshare reports/q3/ --with alice@example.com
# → Grant already absent for 'reports/q3/*' / alice@example.com   (exits 0)
```

### Inspect an ACL

```bash
hq files acl reports/q3/ --company myco
# ACL for reports/q3/* (restricted)
# Creator: person_xxx
# Your effective permission: read
# Entries:
# TYPE   GRANTEE              PERMISSION  GRANTED_BY   GRANTED_AT
# email  alice@example.com    read        person_xxx   2025-09-01
# group  grp_finance          read        person_xxx   2025-10-12
```

### Create a group and share a folder with it

```bash
hq groups create grp_backend-team --name "Backend team"
hq groups add grp_backend-team alice@example.com
hq groups add grp_backend-team bob@example.com
hq files share services/logs/ --with grp_backend-team --permission read
```

## Error Reference

| HTTP Status | Meaning |
|-------------|---------|
| `400` | Bad request — invalid prefix, invalid permission, or `PolicyNestingUnrepresentable` (3+ nesting depth would produce an unrepresentable IAM policy) |
| `401` | Not authenticated — run `hq login` |
| `403` | Not authorized — you need the authority to mutate this ACL (creator or company owner/admin) |
| `404` | For `acl`: no ACL record exists yet for this prefix. For `unshare`: grant already absent — the CLI converts this to a no-op and exits 0. `share` no longer surfaces 404 (the row is auto-created on first grant). |
| `409` | Concurrent modification — retry |
| `5xx` | Server error |

When `share` returns `400 PolicyNestingUnrepresentable`, the ACL write is rejected because granting the principal both a broad allow AND a nested allow (with a carve-out Deny in between) would produce an IAM policy exceeding the representability limit. Resolution: grant the principal at the intermediate prefix first (`hq files share <carve-out-prefix> --with <principal> --permission read`), then retry the nested grant.
