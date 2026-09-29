---
name: team-access
description: "Set, change, or repair members' default read/write access to company vault folders, and find rules that lock members out."
allowed-tools: Bash(hq:*), Bash(jq:*), Bash(awk:*), Bash(test:*), Bash(mkdir:*), Bash(printf:*), Read, Write, AskUserQuestion
---

# /team-access — Member access baseline for a company vault

**Args:** `$ARGUMENTS` — optional company slug, or `--all-owned` to walk every
cloud company where you are an owner. Defaults to the active company.

## What this controls

Plain members of a company hold no file access until someone grants it. Owners and
admins bypass the access list; members do not, and inviting someone writes no grants.
So a member who creates a note under `knowledge/` cannot push it, and cannot pull what
teammates wrote, until a grant covers that path.

This skill lets an owner decide, folder by folder, what the whole team gets by default,
and lets them keep the grant narrower than the whole folder when a folder mixes shared
and sensitive material. It also repairs folders where an older or more specific rule
hides the team grant.

## The one rule the owner must understand

**Every shared-folder glob covers everything inside it, now and in the future.** Use
`knowledge/*` when the team should read and write the whole tree. A trailing slash,
such as `knowledge/`, is a private create-only folder: `write` permits one new direct
child and the first upload locks that child to its creator; it does not share existing
children. There is no "shared folder but not its subfolders" glob. To keep sensitive
material out of a team-wide grant, grant a narrower shared glob (`knowledge/shared/*`)
or keep it under a sibling path that is not granted.

Say this to the owner in plain words before the first decision. Do not let them grant a
root folder believing they can carve pieces out later by name.

## Which rule wins

For any file, the vault applies exactly one rule: the most specific one that matches.
Only that rule's entries count; a broader rule never adds to it. From most to least
specific, for a file under `knowledge/`:

1. A subfolder rule — `knowledge/finance/*` or a bare `knowledge/finance` — wins for
   files inside that subfolder.
2. A **legacy bare rule** `knowledge` (no slash, no `*`). It covers the whole folder
   and **outranks `knowledge/*`**. Older HQ versions wrote these. The `hq files acl`
   output for `knowledge/*` does not show it; only `hq files acl knowledge` does.
3. The shared-folder rule `knowledge/*`.
4. The bucket-wide rule `*`.

Consequences this skill handles:

- A rule with no entries still wins. An empty `knowledge/*` row (an "auto-lock",
  created when an owner first uploaded there) or an empty bare `knowledge` row locks
  every member out of the folder, even when `*` grants the team.
- A new `knowledge/*` row takes over from `*` for that folder. Any person, email,
  group, or app on `*` loses access to `knowledge/` unless the grant is copied.
- An emptied legacy row is kept, not deleted, so it keeps locking members out.
  Never remove entries from a bare row.

## Folders this skill never grants

`ontology/`, `signals/`, and `sources/` are never part of the member baseline.
Access to them is per audience: the ontology worker grants each
`@{audienceKey}/*` shared glob to exactly the people who were privy to its source
(`core/knowledge/public/hq-core/ontology-local-spec.md`). If an owner asks to
give the team those folders, explain that and stop.

## Principals

- `@all` — every active member of the company. The default for a baseline.
- `grp_<name>` — a group created with `hq groups create`. Use when only one function
  should see a folder.
- A person's email, or a `prs_`/`agt_` uid — for one-off shares. Not what this skill
  is for; point them at `/hq-share`. The skill only writes these when copying a grant
  that a new rule would otherwise hide (step 3b).

Permission is `read` or `write`. `write` includes read. A member needs `write` on a path
to push files they create there.

## Flow

Ask one question at a time with `AskUserQuestion`. Never batch the per-folder decisions.
In Codex, or any host without `AskUserQuestion`, ask the same single question in chat
as a short numbered list of options, recommended first, and wait for the reply before
the next one.

### 1. Resolve the company and confirm the caller can act

```bash
slug="${ARGUMENTS:-$(jq -r '.company // empty' .hq/config.json 2>/dev/null)}"
test -n "$slug" || { echo "No company slug given and no active company." >&2; exit 2; }
test -d "companies/$slug" || { echo "companies/$slug does not exist locally." >&2; exit 2; }
```

If `$ARGUMENTS` is `--all-owned`, follow "Several companies in one run" below instead.

The company must be cloud-backed (`cloud: true` in `companies/{slug}/company.yaml`). If
it is not, stop and tell the owner to run `/designate-team {slug}` first; there is no
vault to grant on yet.

Only an owner or admin can write grants. If the first grant returns a 403, say so and
stop; do not retry.

### 2. Read the current state

For each synced root — `knowledge`, `projects`, `policies`, `skills` — read all three
rule shapes that can govern it, plus what is inside:

```bash
hq files acl "$root"   --company "$slug" --json   # legacy bare row; outranks $root/*
hq files acl "$root/"  --company "$slug" --json   # private-folder row
hq files acl "$root/*" --company "$slug" --json   # shared row, the inherited '*' entries, and child rows with grants
hq files browse "companies/$slug/$root/" --company "$slug"
```

In each JSON result, `.exists` says whether that exact row exists and `.direct` holds
its entries. `.inherited` on the `$root/*` read carries the `*` entries (tagged
`sourcePrefix: "*"`). `.children` lists entries of rows below the root, tagged by
`sourcePrefix`; rows below the root with no entries do not appear there (see step 4b).

Find the **winning row** for files in the folder:

- bare `$root` exists → the bare row wins;
- otherwise `$root/*` exists → `$root/*` wins;
- otherwise `*` wins if it exists; otherwise nothing covers the folder.

Then classify the folder, first match wins:

| Finding | Meaning |
|---|---|
| `$root/` exists and `$root/*` does not | Private-folder row. A `$root/*` grant will fail with `ACL_PATTERN_CONFLICT` (DEV-3405). Step 4 stops for this folder. |
| Bare `$root` exists | Legacy row governs the folder. Say who its entries give access to; "nobody" if empty. |
| Winning row has a `company-wide` `write` entry | Team already has the folder. |
| Winning row has a `company-wide` `read` entry only | Team can read but not push. |
| Winning row is `$root/*` with no entries | Auto-lock: only the creator and owners/admins can use the folder. |
| Winning row is `$root/*` with only people, emails, groups | Team as a whole has no access. |
| Winning row is `*` | No folder rule yet. The `*` entries decide. |
| Nothing covers the folder | No rule at all. Members have no access. |

Summarize per root in one line each, plain words:

> `knowledge/` — locked by an old folder rule that gives nobody access. Inside: `shared/`, `finance/`, `onboarding/`.
> `projects/` — no team-wide access yet (locked when it was first used).

If `*` has a `company-wide` entry, flag it as the first thing to fix: that grant covers
the entire vault, including anything added later anywhere.

Judge members' access only from the entries on the winning row. Never use
`effectivePermission` for this: it reports the caller's own access, and an owner or
admin always has full access, so it says nothing about members.

### 3. Decide per root

For a folder classified as a private-folder conflict, do not offer the options below.
Tell the owner the folder is set up as a private create-only folder, which blocks a
team-wide grant. If that row has no entries, or the owner wants the team to share the
folder, give them the support message from step 4 ("Private-folder conflict") and
record the folder under `blocked` in step 6. For every other root, in order, one
question:

> Who should be able to work in `{root}/` by default?

Options (recommended first, adjusted to what step 2 found):

1. **Everyone, the whole folder** — one `@all write` grant on `{root}/*`, plus the same
   grant on the bare `{root}` row when one exists, so the rule that actually wins
   carries it. Right for folders that are meant to be shared by construction
   (`skills/`, `policies/`, usually `projects/`).
2. **Everyone, but only these subfolders** — follow-up multi-select over the folders
   found in step 2. One `@all write` grant per chosen subfolder using `{subfolder}/*`. Right for `knowledge/`
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

### 3b. Grants a new row would hide

Before writing to any path whose row does not exist yet (`.exists == false`), find
the row that governs it today and list that row's entries that are not
`company-wide`. Those are the grants the new row would cut off.

The governing row is the most specific **existing** row above the path, decided by
`.exists`, never by whether it has entries: an empty row still governs and already
blocks everything above it. For a direct subfolder of a root, check in this order and
stop at the first that exists: bare `{root}`, then `{root}/*`, then `*` (step 2 already
read all three). For a new `{root}/*` row the order is bare `{root}` (if it exists the
new row changes nothing for members; go on), then `*`. For a deeper path, check each
parent folder's bare and `/*` rows first, innermost first.

```bash
hq files acl "$governing" --company "$slug" --json \
  | jq 'if .exists then .prefix as $from
        | [.direct[] | select(.granteeType != "company-wide")
           | {granteeType, granteeId, permission, from: $from}]
        else [] end'
```

Do not read these entries from `.inherited` of the new path: it lists only rows that
carry entries, skips empty rows, and never lists a bare row, so it can name grants
from `*` that an empty `{root}/*` row is blocking today. Copying those would open the
new folder to people who are shut out now.

If the list is empty, go on. If not, ask one question, naming each grantee and its
permission:

> Adding a team rule on `{path}` would cut off these existing grants, which reach it
> today through `{from}`: {list}. What should happen to them?

1. **Keep them** (recommended) — copy each onto `{path}` with the same permission.
2. **Let them lapse** — only the team grant applies there from now on.
3. **Skip this folder** — change nothing here.

`hq files share` accepts emails, `grp_` ids, and `prs_`/`agt_` uids. It cannot write an
`app` grant. If the list has an `app` entry, say that the app would lose access to
`{path}`, recommend option 3, and name it under "Not applied" in step 7 if the owner
skips.

### 4. Apply, grant-before-revoke

Order matters when narrowing. If step 2 found a whole-root `@all` grant and the owner is
moving to subfolders:

1. Write every new narrower grant first.
2. Read each one back (step 5) and confirm it landed.
3. Only then remove the broad grant:
   `hq files unshare "$root/*" --with @all --company "$slug"`.

Never revoke first. A member mid-sync between the revoke and the new grant loses access
to files they are editing.

**Narrowing is blocked when a bare `$root` row carries the team grant.** The bare row
wins over `$root/*` and this skill never unshares from it, so removing the `$root/*`
grant would not take access away from the folders the owner left out. In that case
grant the chosen subfolders if the owner still wants them, but do not remove any
broad grant and do not record the narrowing as done. Tell the owner plainly that the
old folder rule still gives everyone the whole folder and that Indigo support has to
remove it, list it under "Not applied" in step 7, and record it under `blocked` in
step 6.

Grant form, one call per path:

```bash
hq files share "$path" --with "$principal" --permission write --company "$slug"
```

For a whole-folder choice — "Everyone, the whole folder" (`@all`) or "Only a group"
for the whole folder (`grp_*`) — write `"$root/*"` first. If a bare `$root` row exists,
then write the same principal on the bare row too, so the rule that wins carries it:

```bash
hq files share "$root/*" --with "$principal" --permission write --company "$slug"
hq files share "$root"   --with "$principal" --permission write --company "$slug"   # only when the bare row exists
```

For the everyone choice, `$principal` is `@all`:

```bash
hq files share "$root/*" --with @all --permission write --company "$slug"
hq files share "$root"   --with @all --permission write --company "$slug"   # only when the bare row exists
```

The same applies to every folder you grant as `{folder}/*`, including a chosen
subfolder such as `knowledge/shared/*`: first read its bare row
(`hq files acl "knowledge/shared" --company "$slug" --json`). A bare row on the folder
itself outranks its `/*` row, so when it exists, write the same principal on it too
and verify it in step 5.

Never create a bare row that does not already exist, and never run `hq files unshare`
on a bare row. Removing its last entry leaves it empty, and an empty legacy row stays
in place and locks members out.

Copied grants from step 3b use the grantee's own id and permission on the new path,
after the team grant on the same path.

**Private-folder conflict (DEV-3405).** If step 2 found a `$root/` row, or a share
fails with `ACL_PATTERN_CONFLICT` (the CLI prints "Conflicting ACL pattern already
exists" and "cannot both exist"), stop for that folder. Do not remove the `$root/` row,
do not grant `$root/` instead, do not retry, and do not try another pattern: the
command line cannot clear this row. Go on with the other folders and tell the owner in
plain words:

> Your team can't be given `{root}/` yet. It has an empty private-folder setting that
> blocks a team-wide grant, and HQ can't remove it from your side. Please contact
> Indigo support (reply to the email Indigo sent you about team access, or use your
> usual Indigo support contact) and mention DEV-3405 and the folder `{root}/` in
> `{Name}`.

Never write a `*` grant from this skill, even if asked. If the owner wants the whole
vault shared, tell them that is what `hq files share --full` does, name the risk, and
leave it to them to run.

### 4b. Locked subfolders under a granted root

A whole-root grant does not reach a subfolder that has its own row: that row wins for
everything inside the subfolder. After granting a root, check below it.

Rows with entries show up in `.children` of the root read:

```bash
hq files acl "$root/*" --company "$slug" --json \
  | jq '.children | group_by(.sourcePrefix)
        | map({path: .[0].sourcePrefix,
               team: ([.[] | select(.granteeType == "company-wide") | .permission] | first),
               grants: length})'
```

These were shared on purpose. Do not change them. Report how many exist and which
ones leave out the team (`team: null`), so the owner knows members can't open them.

Rows with no entries do not show up anywhere in the CLI output. For each direct
subfolder listed by `hq files browse` in step 2, probe the shared and bare rules:

```bash
hq files acl "$root/$sub/*" --company "$slug" --json | jq '{prefix, exists, entries: (.direct | length)}'
hq files acl "$root/$sub"   --company "$slug" --json | jq '{prefix, exists, entries: (.direct | length)}'
```

That is two reads per subfolder; a folder with hundreds of subfolders takes several
minutes, so tell the owner before starting. `exists: true` with `entries: 0` is a
locked subfolder. For each one, ask one question:

> `{root}/{sub}/` has its own rule that gives nobody access, so the team grant on
> `{root}/` doesn't reach it. Give everyone write access to it too?

1. **Yes** — `hq files share "<that prefix>" --with @all --permission write --company "$slug"`,
   then read it back with `--company "$slug"` as in step 5.
2. **Leave it locked.**

A `$root/$sub/` private-folder row is a deliberate creator-only folder; leave it.

**Limitation:** no `hq files` command lists rows that have no entries. The probe above
covers direct subfolders only. An empty row two or more levels down, or on a folder
that holds no files yet, cannot be found from the CLI. Say so in the report. If a
member still can't sync a deeper folder, check that folder with
`hq files acl "<folder>/*"` and `hq files acl "<folder>"`.

### 5. Verify by readback, not by exit code

For every path touched, read the ACL back and confirm the grantee and permission are
present in `.direct` of that exact row:

```bash
hq files acl "$path" --company "$slug" --json \
  | jq -e --arg p "$principal" --arg perm "$permission" \
      '.exists and any(.direct[]?; (.granteeId==$p or ($p=="@all" and .granteeType=="company-wide")) and .permission==$perm)'
```

Then check the row that actually wins for members. For every `{folder}/*` grant —
a whole root or a chosen subfolder — re-read the folder's bare row (`$root` for a
root) with the same check and the same principal the owner chose
(`@all` or the `grp_*` id): if the bare row exists, it is the winner and must carry
that entry. If it does not exist, `{folder}/*` is the winner. A `{folder}/*` readback
alone does not prove members can use a folder that has a bare row. Never add `@all` just to
make a readback pass.

Never use `effectivePermission` as proof. It reflects the caller's own owner or admin
role, not what members hold.

The `prefix` field in the output is the exact pattern sent: `knowledge/` remains a
private create-only row, while `knowledge/*` is the shared recursive row. They are
different ACL rows and cannot coexist.

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
    - path: knowledge/shared/*
      with: "@all"
      permission: write
  projects:
    - path: projects/*
      with: "@all"
      permission: write
    - path: projects        # legacy bare row, granted so the winning rule matches
      with: "@all"
      permission: write
  policies:
    - path: policies/*
      with: "@all"
      permission: write
  skills:
    - path: skills/*
      with: "@all"
      permission: write
excluded:
  - knowledge/finance/   # private-folder marker; not a shared recursive grant
blocked:
  - path: skills/
    reason: DEV-3405 private-folder row; owner told to contact Indigo support
```

`settings/` does not sync to the vault; this file is the owner's record on their own
machine. The grants themselves live in the vault and are what members actually get.

### 7. Report

Plain words, one line per root, then the exclusions:

```
Team access for {Name}
  knowledge/  everyone can write in shared/* and onboarding/*  (finance/ stays private)
  projects/   everyone can write the whole folder via projects/* and the old projects rule
  policies/   everyone can write the whole folder via policies/*
  skills/     not changed: needs Indigo support (DEV-3405)
  Subfolders: 32 shared on purpose left as they are (3 leave out the team); 1 locked one opened.
All 6 grants verified by readback.
```

If anything did not verify, list it under "Not applied" with the re-run command. List
DEV-3405 folders, skipped `app` grants, and the deeper-subfolder limitation there too.

## Several companies in one run

When the owner asks to fix access "everywhere", "for all my companies", or passes
`--all-owned`, loop over every cloud company where the caller is an owner:

```bash
me="$(hq whoami --json | jq -r '.email')"
hq sync mode --show                                     # companies you belong to (first column)
hq members list --company "$c" | awk -v me="$me" '$1==me {print $2}'   # your role in company $c
```

Keep a company only if `companies/$c/company.yaml` has `cloud: true` and your role is
`owner`. Show the list, then take one company at a time: ask one question — "Check
team access for `{Name}` now?" with **Yes** / **Skip** / **Stop here** — and, on Yes,
run steps 2–7 for that company alone before the next one. Never mix companies in one
question, one grant, or one summary line; each company's settings and records stay in
its own `companies/{slug}/`. End with one line per company: fixed, already fine,
skipped, or needs Indigo support.

## Rules

- One question per decision. Never batch the per-root questions into one prompt. Chat
  fallback in hosts without `AskUserQuestion`.
- Explain the "covers everything inside" rule before the first decision, every run.
- Read the bare `{root}` row as well as `{root}/` and `{root}/*`. A bare row outranks
  `{root}/*`.
- Grant new access before revoking old access. Never the other way round.
- Never unshare from a bare `{root}` row. Never create one.
- Before writing a new row, list the grants it would hide and ask what to do with them.
- On `ACL_PATTERN_CONFLICT`, stop for that folder and send the owner to Indigo support
  (DEV-3405). No workarounds.
- Never write a `*` grant. Never widen a subfolder choice to its parent silently.
- Verify every grant by readback on the winning row's `.direct` entries. Success exit
  codes and `effectivePermission` are not proof.
- Owner and admin only. Members cannot run this; say so and stop on 403.
- Secrets are a separate system with owner-only grants. This skill does not touch them;
  point at `/hq-secrets` if the owner asks.

## Re-running

Running `/team-access` again on a company that already has a baseline shows the
current grants next to the recorded intent and asks only about the differences. This
is the safe way to narrow a company that was set up with whole-root grants: pick
subfolders, and the skill grants them first and removes the root grant last. It is
also the way to heal a company whose members can't sync: the step 2 classification
names the rule that locks them out.

## See also

- `/designate-team` — cloud-backs a company and writes the default baseline
  (`@all write` on the four synced roots). Run `/team-access` afterward to narrow it.
- `/hq-share` — one-off shares to a person or a link.
- `/hq-files` — inspect any grant directly.
