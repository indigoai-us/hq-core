---
name: team-access
description: Set or change what company members can read and write in the company vault by default — whole synced folders or only chosen subfolders — with a guided, one-question-at-a-time flow, grant-before-revoke ordering, and a readback check that proves every grant landed. Use when an owner asks "give the team access to X", "members can't sync their knowledge", "narrow what everyone can see", or wants to review the current member baseline.
allowed-tools: Bash(hq:*), Bash(jq:*), Bash(test:*), Bash(mkdir:*), Bash(printf:*), Read, Write, AskUserQuestion
---

# /team-access — Member access baseline for a company vault

**Args:** `$ARGUMENTS` — optional company slug. Defaults to the active company.

## What this controls

Plain members of a company hold no file access until someone grants it. Owners and
admins bypass the access list; members do not, and inviting someone writes no grants.
So a member who creates a note under `knowledge/` cannot push it, and cannot pull what
teammates wrote, until a grant covers that path.

This skill lets an owner decide, folder by folder, what the whole team gets by default,
and lets them keep the grant narrower than the whole folder when a folder mixes shared
and sensitive material.

## The one rule the owner must understand

**Every folder grant covers everything inside it, now and in the future.** There is no
"this folder but not its subfolders" grant. Granting `knowledge/` covers
`knowledge/anything/at/any/depth`. The way to keep something out of a team-wide grant is
to grant a narrower path (`knowledge/shared/` instead of `knowledge/`) or to keep the
sensitive material under a sibling path that is not granted.

Say this to the owner in plain words before the first decision. Do not let them grant a
root folder believing they can carve pieces out later by name.

## Folders this skill never grants

`ontology/`, `signals/`, and `sources/` are never part of the member baseline.
Access to them is per audience: the ontology worker grants each
`@{audienceKey}/` folder to exactly the people who were privy to its source
(`core/knowledge/public/hq-core/ontology-local-spec.md`). If an owner asks to
give the team those folders, explain that and stop.

## Principals

- `@all` — every active member of the company. The default for a baseline.
- `grp_<name>` — a group created with `hq groups create`. Use when only one function
  should see a folder.
- A person's email — for one-off shares. Not what this skill is for; point them at
  `/hq-share`.

Permission is `read` or `write`. `write` includes read. A member needs `write` on a path
to push files they create there.

## Flow

Ask one question at a time with `AskUserQuestion`. Never batch the per-folder decisions.

### 1. Resolve the company and confirm the caller can act

```bash
slug="${ARGUMENTS:-$(jq -r '.company // empty' .hq/config.json 2>/dev/null)}"
test -n "$slug" || { echo "No company slug given and no active company." >&2; exit 2; }
test -d "companies/$slug" || { echo "companies/$slug does not exist locally." >&2; exit 2; }
```

The company must be cloud-backed (`cloud: true` in `companies/{slug}/company.yaml`). If
it is not, stop and tell the owner to run `/designate-team {slug}` first; there is no
vault to grant on yet.

Only an owner or admin can write grants. If the first grant returns a 403, say so and
stop; do not retry.

### 2. Read the current state

For each synced root — `knowledge`, `projects`, `policies`, `skills` — read the grant
that covers it and the folders directly inside it:

```bash
hq files acl "$root/" --company "$slug" --json
hq files browse "companies/$slug/$root/" --company "$slug"
```

Summarize per root in one line each, plain words:

> `knowledge/` — everyone can read and write the whole folder (set 2026-09-22). Inside: `shared/`, `finance/`, `onboarding/`.
> `projects/` — no team-wide access yet.

If a root has a bucket-wide `*` grant to `@all`, flag it as the first thing to fix: that
grant covers the entire vault, including anything added later anywhere.

### 3. Decide per root

For each root, in order, one question:

> Who should be able to work in `{root}/` by default?

Options (recommended first, adjusted to what step 2 found):

1. **Everyone, the whole folder** — one `@all write` grant on `{root}/`. Right for
   folders that are meant to be shared by construction (`skills/`, `policies/`,
   usually `projects/`).
2. **Everyone, but only these subfolders** — follow-up multi-select over the folders
   found in step 2. One `@all write` grant per chosen subfolder. Right for `knowledge/`
   when it holds both team material and private material.
3. **Only a group** — follow-up: which `grp_*` (list from `hq groups list --company
   {slug}`), then whole folder or subfolders as above.
4. **Nobody by default** — leave it to per-person shares. Say plainly that members will
   not be able to sync anything they create here until someone shares it.

If the owner picks subfolders and a subfolder they need does not exist yet, create it
locally with a `.gitkeep`, push it, then grant it. A grant on a path that has no objects
is valid and covers files added later.

Ask read vs write only if the owner raises it; default to `write`, since the point of a
baseline is letting members contribute. Read-only baselines are a deliberate choice, not
the default.

### 4. Apply, grant-before-revoke

Order matters when narrowing. If step 2 found a whole-root `@all` grant and the owner is
moving to subfolders:

1. Write every new narrower grant first.
2. Read each one back (step 5) and confirm it landed.
3. Only then remove the broad grant:
   `hq files unshare "$root/" --with @all --company "$slug"`.

Never revoke first. A member mid-sync between the revoke and the new grant loses access
to files they are editing.

Grant form, one call per path:

```bash
hq files share "$path" --with "$principal" --permission write --company "$slug"
```

Never write a `*` grant from this skill, even if asked. If the owner wants the whole
vault shared, tell them that is what `hq files share --full` does, name the risk, and
leave it to them to run.

### 5. Verify by readback, not by exit code

For every path touched, read the ACL back and confirm the grantee and permission are
present:

```bash
hq files acl "$path" --company "$slug" --json \
  | jq -e --arg p "$principal" --arg perm "$permission" \
      '.direct[]? | select((.granteeId==$p or ($p=="@all" and .granteeType=="company-wide")) and .permission==$perm)'
```

The `prefix` field in the output is normalized (`knowledge/` reads back as
`knowledge/*`); that is the same grant, not a wider one.

A grant that returned success but is absent on readback is a failure. Report it as one,
with the exact command to re-run. Do not report the baseline as set until every path
reads back.

### 6. Record the decision

Write `companies/{slug}/settings/team-access.yaml` so the next run can show what was
intended and diff it against what the vault actually holds:

```yaml
version: 1
updated: <ISO date>
baseline:
  knowledge:
    - path: knowledge/shared/
      with: "@all"
      permission: write
  projects:
    - path: projects/
      with: "@all"
      permission: write
  policies:
    - path: policies/
      with: "@all"
      permission: write
  skills:
    - path: skills/
      with: "@all"
      permission: write
excluded:
  - knowledge/finance/   # kept out of the team-wide grant on purpose
```

`settings/` does not sync to the vault; this file is the owner's record on their own
machine. The grants themselves live in the vault and are what members actually get.

### 7. Report

Plain words, one line per root, then the exclusions:

```
Team access for {Name}
  knowledge/  everyone can write in shared/ and onboarding/  (finance/ stays private)
  projects/   everyone can write the whole folder
  policies/   everyone can write the whole folder
  skills/     everyone can write the whole folder
All 5 grants verified by readback.
```

If anything did not verify, list it under "Not applied" with the re-run command.

## Rules

- One question per decision. Never batch the per-root questions into one prompt.
- Explain the "covers everything inside" rule before the first decision, every run.
- Grant new access before revoking old access. Never the other way round.
- Never write a `*` grant. Never widen a subfolder choice to its parent silently.
- Verify every grant by readback. Success exit codes are not proof.
- Owner and admin only. Members cannot run this; say so and stop on 403.
- Secrets are a separate system with owner-only grants. This skill does not touch them;
  point at `/hq-secrets` if the owner asks.

## Re-running

Running `/team-access` again on a company that already has a baseline shows the
current grants next to the recorded intent and asks only about the differences. This
is the safe way to narrow a company that was set up with whole-root grants: pick
subfolders, and the skill grants them first and removes the root grant last.

## See also

- `/designate-team` — cloud-backs a company and writes the default baseline
  (`@all write` on the four synced roots). Run `/team-access` afterward to narrow it.
- `/hq-share` — one-off shares to a person or a link.
- `/hq-files` — inspect any grant directly.
