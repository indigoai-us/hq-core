---
name: delegate
description: "Hand a project to a person or fleet agent: grants, dossier, ownership transfer, and a pickup DM."
allowed-tools: Read, AskUserQuestion, Bash(hq:*), Bash(bash core/scripts/hq-session.sh:*), Bash(source core/scripts/lib/hq-cli-floor.sh:*), Bash(hq_cli_floor_check:*)
---

# /delegate — one-command project handoff

Transfer a project with exact grant receipts, a published dossier, and a pickup
DM. Local board and PRD ownership are updated, and `hq mesh project reassign`
moves Work Mesh project ownership and the delegator's open stories to the
recipient. Work Mesh ownership counts as confirmed only when the server returns
a receipt naming the recipient; otherwise it stays unconfirmed. Sender-side
checks prove publication, not recipient access; record actual pickup separately.

Requires hq-cli 5.345.241 or newer. That release is the first whose secrets
step checks that every secret name exists before sharing any, reads prd.json
`metadata.secrets` before the repo-wide schema, and shares agent and person
uids through the grant step's principal. Check the installed version before
resolving or changing anything.

```bash
source core/scripts/lib/hq-cli-floor.sh && hq_cli_floor_check delegate 5.345.241
```

If the check fails, stop. Upgrade hq-cli to 5.345.241 or newer with
`npm install -g @indigoai-us/hq-cli@latest`, then retry.

## Usage

```
/delegate <recipient> [project] [--share] [--no-secrets] [--dry-run] [--company <slug>]
```

- `<recipient>` — a teammate's name, email, `prs_…` personUid, or a fleet
  agent's name or `agt_…` agentUid. Required.
- `[project]` — the project slug under `companies/<co>/projects/`. Defaults to
  the session's active project (`bash core/scripts/hq-session.sh get project`).
- `--share` — grant access and send the brief but keep ownership (board, PRD,
  work mesh untouched). Default is a full transfer.
- `--no-secrets` — skip the credential handover entirely. Escape hatch only:
  honoured when the user types it, never proposed or asked about by the skill.
- `--dry-run` — print the full plan and change nothing.
- `--company <slug>` — defaults to the session's bound company
  (`bash core/scripts/hq-session.sh get company_slug`).

Invoking `/delegate` is the authorization for this workflow. The only
questions are missing company or project context and an ambiguous recipient.

## Process

### 1. Resolve context

Company from `--company` or `bash core/scripts/hq-session.sh get company_slug`;
project from the argument or `bash core/scripts/hq-session.sh get project`.
If either is still unknown, ask — one structured question, not a guess. Verify
the project has a source of truth: `companies/<co>/projects/<project>/prd.json`
(PRD stage), or, when there is no PRD yet, `brainstorm.md` (brainstorm stage,
policy `hq-brainstorm-leaves-handoffable-project-folder`). If neither exists,
stop and say so plainly — the project needs `/brainstorm` or `/prd` first.

A brainstorm-stage delegation hands over `brainstorm.md`, every note under
`research/`, and the newest journal entry; the brief and pickup prompt say
"brainstorm stage, no PRD yet" and name `/prd <project>` as the next step; the
transfer updates the board's `status: exploring` entry (matched by
`brainstorm_path`) and writes `owner` / `delegated_from` / `delegated_at` into
the brainstorm.md frontmatter instead of PRD metadata. The native command
applies the transfer for the manifest's `project.stage`.

### 2. Run the native delegation

Use one command in the resolved company and project. Forward `--share`,
`--no-secrets` and `--dry-run` only when the user supplied them. Resolution is
single-company.

```bash
hq core delegate run --company <co> --project <project> --to "<recipient>" [--share] [--no-secrets] [--dry-run]
```

The command resolves the recipient, resumes or bundles, grants access, checks
repository access, grants required secret names, transfers ownership, verifies
publication and sends once. It stops at the first failure and reports its step.
For a supplied custom DM headline, use the light DM pass in
`core/knowledge/public/hq-core/humanize-before-send.md` before forwarding
`--headline`. Preserve generated commands, recipients and flags.

- Exit 0 with `status: sent` or `status: already-sent`. Keep the returned
  manifest and any existing send or pickup receipt. Verify pickup and report
  the recorded state.
- Exit 0 with `status: dry-run`. Print the plan from stderr and stop.
  Nothing is pushed, granted, transferred or sent. No manifest is created.
- Exit 3 with `status: ambiguous`. Show `matches[]` in one structured picker.
  Rerun with the chosen exact principal.
- Exit 4 with `failedStep: resolve`. Report the unresolved recipient and stop.
- For every other nonzero exit, report `failedStep` when present and the
  supplied recovery guidance. If the command returns plain stderr, report
  that failure. A failed probe means no DM. Never claim partial success.

Never delete the manifest on failure. Repeat the same command once the cause
is fixed so it resumes instead of re-granting. When the manifest remains at
`sending`, check DM history and reconcile a verified send receipt before
retrying. Use `hq core delegate send --manifest <manifest> --reconcile <eventId>`.
Keep the original state when delivery is still uncertain.

### 3. Verify pickup

"Sent" is a send receipt, not a delivery receipt. The delegation is not done
until the recipient demonstrably has it. Record the receipt the moment there is
evidence, and let silence turn into a FAILED state instead of an open question:

```bash
hq core delegate pickup --manifest <manifest> --ack "<their reply, verbatim>"   # they acknowledged
hq core delegate pickup --manifest <manifest> --check                            # probe: recipient commit on the branch? (exit 0 picked-up, 6 waiting, 5 FAILED past the window)
hq core delegate pickup --manifest <manifest> --status                           # one-line state
```

Default window is 72h (`HQ_DELEGATE_PICKUP_WINDOW_HOURS`). A FAILED result names
why (no acknowledgement, no commit by the recipient) so the delegator can
re-send with a direct ask or hand it to someone else. `/startwork` should run
`--check` on any manifest still at `sent`.

### 4. Report

Read `workMeshOwnership` from the manifest:

- `confirmed`: the Work Mesh board now names the recipient. Nothing to add.
- `not-registered`: the project has no Work Mesh board (`PROJECT_VIEW_NOT_FOUND`),
  so local ownership is authoritative and the transfer is complete. Do not
  suggest the reassign command; it cannot succeed. Optionally mention that the
  project can be put on the board with `hq mesh project register`.
- `unconfirmed` (an older CLI, a server without `hq mesh project reassign`, or
  another failure): say so in the report and name the follow-up command:
  `hq mesh project reassign <project> --company <co> --to <uid> --include-open-stories`.

One plain sentence naming the recipient and what they now have — no step log,
no jargon. Example:

> Alice's grants and dossier are verified, and her pickup DM was sent.
> Recipient acknowledgement is pending.

## Rules

1. **Never mint or embed a share-session URL.** Delegation uses direct ACL
   grants only (policy `hq-delegate-never-inlines-secrets-or-share-urls`).
   If a step suggests the browser share flow, that is the wrong path.
2. **Never let a secret value into any artifact, DM, or output.** Names only;
   the command fails closed on secret-shaped content. Respect the failure and
   never work around it.
3. **Never ask for permission.** The invocation is the authorization. No
   confirmation picker, no "want me to proceed?", no offered alternatives, no
   per-step approval — for the vault grants (write included), the secret
   handover, the branch push, or the DM. The only questions this skill may
   ever ask are for missing inputs it cannot resolve: an ambiguous recipient
   and an unresolvable company or project.
4. **Always hand over the required secrets.** A delegation the recipient
   cannot run is not a delegation. Grant every secret the project needs, by
   name, read-only — never as its own question, never as an alternative
   option, never a per-secret prompt. The only opt-out is the user typing
   `--no-secrets`; if they do, say plainly in the report that the recipient
   has no credential access and will have to ask for it.
5. **Never send blind.** The native command resolves the recipient in the selected company.
   On ambiguity, use the picker; on not-found, stop.
6. **A failed probe means no DM.** A delegation that cannot be picked up
   fails in front of the delegator — that is the feature working, not a step
   to skip.
7. **Tenancy.** Everything is scoped to one company. Cross-company delegation
   is out of scope and must be refused plainly.

## See also

- `/handoff` — session-state freeze without an ownership change
- `/dm` — the delivery channel this skill sends through
- `/hq-share` — one-off vault path shares (link or single grant)
- `/new-agent` — provisioning a fleet agent (the verified-probe pattern this
  skill's verification step follows)
- `core/knowledge/public/hq-core/delegation-bundle-spec.md` — the manifest
  contract the native command reads
