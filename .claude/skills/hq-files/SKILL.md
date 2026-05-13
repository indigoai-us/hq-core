---
name: hq-files
description: Manage file access controls in HQ vault — share prefixes, revoke grants, inspect ACLs, and orchestrate access for individuals or groups.
allowed-tools: Bash(hq:*)
---

# HQ Files

Manage per-prefix file access controls in the HQ vault via the `hq files` CLI. Access is scoped to S3 key prefixes within a company vault, controlled by an ACL layer that resolves grants at vend-time. See also [`hq-secrets`](../hq-secrets/SKILL.md) for secret-level ACLs and group management.

## Requires

- `@indigoai-us/hq-cli` **≥ 5.12.x (post-`f71dbf3`)** — the browser-launch share flow (`hq files share <paths...>` with no `--with`) and `--with @all` for company-wide grants both ship in the post-5.12.2 commits. For the legacy direct-grant CLI surface alone, `≥ 5.8.4` is sufficient. Check with `hq --version`; upgrade via `npm i -g @indigoai-us/hq-cli@latest`.

## Commands

| Command | Purpose |
|---------|---------|
| `hq files share <prefix>` *(no `--with`)* | **Browser flow.** Mints an encrypted single-use share-session token, opens the share-session page in your default browser, and lets you batch-pick recipients (members, groups, "Share with All") with per-recipient read/write before submitting all grants in one click. Supports multiple paths: `hq files share path/a/ path/b/`. Use `--no-open` to print the URL without launching a browser. |
| `hq files share <prefix> --with <principal> --permission <level>` | **Direct grant.** Grant `read` or `write` access on a prefix to a person, group, or `@all`. If no ACL row exists for the prefix, one is auto-created with this grant as its first entry; success message is `Created ACL and granted ...` instead of `Granted ...`. |
| `hq files share <prefix> --with @all --permission <level>` | **Company-wide grant.** Writes a single ACL entry with `granteeType: 'company-wide'` covering every active member. Distinct from the legacy `open` flag (see "Company-wide vs `open` flag" below). |
| `hq files unshare <prefix> --with <principal>` | Revoke a grant on a prefix from a person, group, or `@all` |
| `hq files acl <prefix>` | Show the ACL for a prefix: creator, grantees, permissions, open/restricted status, your effective permission |

All commands accept `--company <slug>` to target a specific company. If omitted, the CLI resolves the company from your membership.

### Choosing between direct grant and the browser flow

| Situation | Use |
|-----------|-----|
| Single recipient, one path, you already know the email/group | `--with` direct grant — one command, no browser hop |
| 2+ recipients, or 2+ paths, or you want to see who already has access | Browser flow — one share-session, one submit |
| Granting to the entire company | `--with @all --permission read` (direct) **or** the browser flow's "Share with All" toggle |
| Scripted/automated grants | Always direct grant — the browser flow is interactive by design |

## Prefix Conventions

A **prefix** is an S3-style path fragment, **relative to the company's vault bucket root**. The bucket is already scoped to the company — never prepend `companies/<slug>/`, the company's name, or any other company-identifying segment. A grant on `companies/myco/reports/` does not cover `reports/` (those are different keys, and the former does not exist in the bucket).

The CLI normalizes the prefix before sending to the API:

- **Trailing slash** — automatically appended with `*`. `reports/q3/` → `reports/q3/*`
- **Bare folder with `*`** — passed through unchanged. `reports/q3/*`
- **Exact key** — passed through unchanged. `reports/q3/summary.pdf`

A **bare prefix without a trailing slash and without `/*`** (e.g. `reports`) is treated as an exact key — it covers only an object literally named `reports`. It does **not** cover `reports/q3.pdf` or anything else under it. To share a folder, always use the trailing slash or explicit `/*`.

The API rejects prefixes that start with `/` (returns 400). S3-key character constraints (no `\0`, `\n`, traversal patterns) are also enforced server-side.

Examples:
- `reports/` → normalized to `reports/*` — grants access to all keys under `reports/`
- `invoices/2025/*` → grants access to all keys matching that glob
- `README.md` → grants access to exactly that key
- `reports` (bare, no slash, no `*`) → grants access to **only** the key literally named `reports` — almost certainly not what you want for a folder

## Permission Model

Each ACL entry grants one of two permission levels via the `--permission` flag:

- **`read`** — caller may list, download, and view metadata for files matching the prefix.
- **`write`** — full `read` plus upload, overwrite, and delete.

The CLI accepts only `read` or `write` for `--permission`. The ACL row's **creator** additionally gets effective `admin` automatically via creator-bypass at resolution time — visible as `Your effective permission: admin` in `hq files acl` output even when no entry grants admin explicitly. Mutating the ACL (`share`/`unshare`) requires that effective admin: company owners/admins, or the row's creator.

An ACL may be **open** (all active members get at least `read` automatically) or **restricted** (only explicit entries have access). Most ACLs are created open during the initial backfill; individual grants narrow or extend access on top of the open floor.

**Carve-out Denies:** when a more-specific prefix exists with no entry for a caller, that sub-tree is denied even if a broader prefix grants access. This is enforced at vend-time (STS session policy), not at the ACL API layer.

## Groups as Grantees

`--with` accepts an email address, a group id matching `grp_[A-Za-z0-9_-]+` (letters, digits, underscores, hyphens — e.g. `grp_backend-team`), or the literal `@all` for company-wide grants. A group grant extends the permission to every current member. Adding or removing members from the group adjusts who has file access without touching the ACL.

Group management is shared with secrets (same `hq groups` subcommands). See [`hq-secrets`](../hq-secrets/SKILL.md) for `hq groups create`, `hq groups add`, etc.

## Company-wide vs `open` Flag

Two ways to give everyone in the company access to a prefix — they look similar but behave very differently:

| | `--with @all` (company-wide entry) | Legacy `open: true` flag |
|---|---|---|
| ACL representation | Explicit row, `granteeType: 'company-wide'` | Boolean on the ACL header |
| Audit trail | Visible in `hq files acl <prefix>` as a regular grant with grantor + timestamp | Just a flag — no grantor, no timestamp |
| Revoke | `hq files unshare <prefix> --with @all` | Requires flipping the flag, often via backfill script |
| New-member propagation | Automatic at vend-time (every active member resolves through the company-wide entry) | Automatic at vend-time |
| Distinct from per-member entries | Yes — coexists cleanly with named grants | Conflates "everyone has read" with "this is a public folder" |

**Always prefer `--with @all` for new company-wide intent.** The `open` flag exists only because most ACLs were created open during the initial backfill — it's load-bearing for legacy data, not the path forward.

## Sharing via the Web Page (Share-Session Flow)

When `hq files share` is run with no `--with`, the CLI mints an **encrypted single-use share-session token** and opens a web page where the issuer picks recipients and per-recipient permissions, then submits all grants in one round-trip.

How the token works:

- **Encrypted at mint time** with the master key (AES-256-GCM, `iv || authTag || ciphertext` base64url-encoded). The Lambda decrypts on every read; the token is opaque to the browser.
- **Pinned scope** — the encrypted payload includes the issuer's identity, the requested paths, and `maxPermissionByPath` computed from the issuer's own ACL. The page cannot grant beyond what the issuer had at mint time, even if the page is mutated client-side.
- **Single-use** — the page's submit endpoint claims the token's `nonce` atomically (DynamoDB `attribute_not_exists`). A successful submit invalidates the token; a second submit returns 409.
- **Short-lived** — default 15-minute TTL, bounded `60s..7d`. The page returns 403 with `expired` if the token is past its `expiresAt`.
- **Public route, no Cognito session required** — the share-session page lives outside the console's authenticated `(shell)` group at `/share-session/[token]`. The token *is* the auth.

Failure modes (operator-visible):

| HTTP | Meaning |
|------|---------|
| `403 expired` | Token TTL exceeded |
| `403 scope_exceeded` | Page tried to grant a permission higher than `maxPermissionByPath[path]` for that path |
| `409 nonce_already_claimed` | Token was already redeemed — mint a fresh one |
| `400 invalid_token` | Decryption failed — token corrupted or signed under a different master key (e.g. wrong stage) |

## `unshare` Idempotency

`hq files unshare` is safe to call multiple times. When the grant is already absent, the server returns `404`; the CLI treats this as a successful no-op — it prints a green "Grant already absent" message and exits 0. Code or automation calling `unshare` does not need to pre-check whether the grant exists.

## Rules for Agent Workflows

1. **Normalize prefixes before calling `share`.** Pass a trailing slash or an explicit `/*` suffix for folder-level grants. The CLI normalizes for you, but be deliberate: granting `reports/q3.pdf` (exact key) is very different from granting `reports/q3/` (folder), and granting bare `reports` (no slash, no `*`) is an exact-key grant that covers nothing inside the folder.

2. **Prefixes are bucket-relative — never include the company name or `companies/<slug>/`.** The vault bucket is already scoped to the company; prepending the slug points the grant at a path that doesn't exist. If the user asks you to "share `companies/myco/reports/` with X", translate that to `reports/` before calling `hq files share`.

3. **Push local files before sharing them.** `hq files share` only creates an ACL row or share-session token; it does not upload local files. If the requested path exists under `companies/{company}/`, run `hq sync push <local-path> --hq-root <hq-root> --company <slug> --on-conflict keep` first, then verify the plan/upload count. Treat `0 files to upload` on a newly-created folder as a blocker: the path is probably excluded by `.hqinclude` / `.hqignore`, or the local path does not map to the bucket-relative prefix you plan to grant.

4. **Always confirm the target company.** Run `hq files acl <prefix> --company <slug>` to inspect before mutating. A grant on the wrong company uid is hard to clean up.

5. **Verify after sharing.** Immediately after `hq files share`, run `hq files acl <prefix> --company <slug>` and confirm the displayed pattern ends in `/*` (for folder grants) or matches the exact key you intended. If it shows a bare prefix without `/*`, the grant only covers a literal key match and almost certainly does nothing — `unshare` and re-grant with the correct pattern.

6. **To share everything in a vault, prefer one grant on `*` over many per-folder grants.** Every vault is provisioned with a `*` ACL row; granting the principal `read` on `*` covers all current and future keys. Per-folder fan-out is fragile (easy to miss new top-level folders) and harder to audit.

7. **Prefer group grants for teams.** Share `reports/*` with `grp_finance` rather than granting each person individually. Membership changes automatically adjust access.

8. **Do not widen ACLs without explicit human approval.** Granting `write` on a prefix is a privilege escalation. Always confirm with the human before making these changes.

9. **Check your effective permission before attempting mutation.** `hq files acl <prefix>` shows `Your effective permission:` in the output. Attempting `share`/`unshare` without the authority to mutate this ACL (creator or company owner/admin) returns 403.

10. **Do not share exact keys when a folder-level grant is intended.** `reports/q3/summary.pdf` only covers that one file; `reports/q3/` (normalized to `reports/q3/*`) covers the whole folder.

11. **Carve-out awareness.** If a broad prefix (`reports/*`) is open and you also need to restrict `reports/q3/*` for a subset of members, that narrowing is expressed as a more-specific ACL with fewer grants — the vend layer automatically denies the sub-tree for callers without a matching entry. Do not attempt to revoke a broad grant to achieve narrowing; instead, ensure the more-specific prefix has the right entries.

12. **Use the browser flow for 2+ recipients or 2+ paths.** A single share-session page handles N×M grants in one human action — N CLI calls is friction, error-prone, and produces a noisy ACL audit trail. Reserve direct `--with` grants for single-recipient/single-path or scripted automation.

13. **Prefer `@all` over the legacy `open` flag for new company-wide intent.** Explicit `granteeType: 'company-wide'` rows are auditable, individually revocable, and don't conflate "everyone has read" with "this folder is public." See "Company-wide vs `open` Flag" above.

14. **Treat share-session URLs as live capabilities — never persist them.** A share-session URL is an encrypted, single-use, 15-minute capability that any holder can redeem to write ACLs in the issuer's name. Do **not** paste share-session URLs into:
    - Auto-checkpoint thread files (`workspace/threads/`)
    - Journal entries, learnings, or session logs
    - Git commit messages or PR descriptions
    - Slack, email, or any chat surface other than the intended human recipient
    - Worker handoff payloads
    - Any *subsequent* assistant turn that summarizes or revisits the action

    When demonstrating the flow in documentation, redact the token segment as `https://hq.{co}.com/share-session/<TOKEN_REDACTED>`. The 15-minute TTL is a defense in depth, not a license to log them.

15. **Mint fresh URLs rather than re-sending stale ones.** If a recipient says "the link doesn't work," mint a new one — do not extend TTLs server-side or attempt to debug an expired token. Mint cost is one round-trip; a stale token can mask scope drift if the issuer's permissions changed since mint.

## Common Workflows

### Share via the browser (multi-recipient or multi-path)

```bash
# If the folder was created locally, upload it first; sharing only writes ACLs.
hq sync push companies/myco/reports/q3/ --hq-root ~/HQ --company myco --on-conflict keep

# Opens default browser to a share-session page; pick recipients + permissions, click Submit
hq files share reports/q3/ docs/handbook/ --company myco

# Print the URL without launching a browser (useful in headless contexts)
hq files share reports/q3/ --no-open --company myco
# → Share-session URL generated:
#     https://hq.myco.com/share-session/<TOKEN_REDACTED>
#     Paths:   reports/q3/*
#     Expires: 2026-05-12T03:34:16Z
```

### Share a folder with the entire company (`@all`)

```bash
hq files share announcements/ --with @all --permission read --company myco
# → Granted read on announcements/* to @all (granteeType: company-wide)

# Revoke later — single ACL row, single command
hq files unshare announcements/ --with @all --company myco
```

### Share the entire vault with a teammate

```bash
hq files share '*' --with alice@example.com --permission read --company myco
# → Granted read on * to alice@example.com
hq files acl '*' --company myco
# Confirm alice@example.com appears in Entries with permission=read
```

### Share a folder with a teammate

```bash
hq files share reports/q3/ --with alice@example.com --permission read --company myco
# → Granted read on reports/q3/* to alice@example.com

# Always verify — the displayed pattern should end in /*
hq files acl reports/q3/ --company myco
# ACL for reports/q3/* (restricted)   ← /* is the pattern actually written
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
