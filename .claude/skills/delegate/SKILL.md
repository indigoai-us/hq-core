---
name: delegate
description: Hand a project to a named person or fleet agent in one command — freezes state, grants vault access, hands over the branch and secrets, transfers ownership, and sends a self-sufficient pickup DM. The recipient pastes one prompt and has everything; no /hq-sync run, no follow-up questions.
allowed-tools: Read, AskUserQuestion, Skill, Bash(hq:*), Bash(bash core/scripts/hq-session.sh:*), Bash(bash core/scripts/hq-delegate-resolve.sh:*), Bash(bash core/scripts/hq-delegate-bundle.sh:*), Bash(bash core/scripts/hq-delegate-grant.sh:*), Bash(bash core/scripts/hq-delegate-repo.sh:*), Bash(bash core/scripts/hq-delegate-secrets.sh:*), Bash(bash core/scripts/hq-delegate-transfer.sh:*), Bash(bash core/scripts/hq-delegate-verify.sh:*), Bash(bash core/scripts/hq-delegate-send.sh:*), Bash(rm:*)
---

# /delegate — one-command project handoff

Transfer a project to a teammate or fleet agent so completely that they never
have to ask for anything: the dossier lands in the vault with verified access,
the branch is on the remote, the secrets they need are granted by name, the
board and work mesh point at them, and their DM carries a pickup prompt that
pulls every file on demand.

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
- `--no-secrets` — skip the credential handover entirely.
- `--dry-run` — print the full plan and change nothing.
- `--company <slug>` — defaults to the session's bound company
  (`bash core/scripts/hq-session.sh get company_slug`).

The heavy lifting lives in eight tested helpers; this skill orchestrates them
and owns the user-facing confirmation. Do not reimplement their logic inline.

## Process

### 1. Resolve context

Company from `--company` or `bash core/scripts/hq-session.sh get company_slug`;
project from the argument or `bash core/scripts/hq-session.sh get project`.
If either is still unknown, ask — one structured question, not a guess. Verify
`companies/<co>/projects/<project>/prd.json` exists; if not, stop and say so
plainly (a delegation needs a PRD to describe what is being handed over).

### 2. Resolve the recipient — confirm before anything else

```bash
bash core/scripts/hq-delegate-resolve.sh --company <co> --to "<recipient>"
```

- **Exit 0** — JSON `{kind, principal, displayName}`. Continue.
- **Exit 3 (ambiguous)** — the output carries `matches[]`. Present the
  candidates as a single structured picker (AskUserQuestion; decision-queue
  pattern, one question). Never guess, never send blind. Re-run nothing —
  use the chosen principal directly.
- **Exit 4 (not found / no email)** — STOP. Relay the helper's message: no
  teammate or fleet agent by that name in this company; the user can pass an
  exact email, `prs_…`, or `agt_…` instead.

Resolution is single-company and tenancy-safe; never look across companies.

### 3. Dry run (when `--dry-run`)

```bash
bash core/scripts/hq-delegate-verify.sh --dry-run --company <co> --project <project> --to <principal> [--mode share]
```

Print the plan verbatim and stop. Nothing is pushed, granted, transferred, or
sent, and nothing lands under `workspace/delegations/`.

### 4. Freeze session state

Before building the bundle, checkpoint the session so nothing in flight is
lost to the handoff:

```bash
hq core checkpoint --summary "Delegating <project> to <displayName>" || true
```

If checkpointing is unavailable in this runtime, note it and continue — the
delegation itself does not depend on it.

### 5. Build the bundle

```bash
bash core/scripts/hq-delegate-bundle.sh build --company <co> --project <project> \
  --to <principal> --to-kind <kind> --to-name "<displayName>" [--mode share]
```

Prints the `delegationId`; the manifest is
`workspace/delegations/<delegationId>/manifest.json`. The builder fails closed
if its own output matches a secret pattern — if it does, stop and report,
never work around it.

### 6. Collect the plan (no mutations yet)

Run the three gated helpers WITHOUT `--yes`. Each prints its plan and exits 2;
none of them touches anything:

```bash
bash core/scripts/hq-delegate-grant.sh --manifest <manifest>          # vault grants incl. write escalation
bash core/scripts/hq-delegate-repo.sh --manifest <manifest>           # exit 2 only when a local-only branch needs pushing
bash core/scripts/hq-delegate-secrets.sh --manifest <manifest>        # secret NAMES that would be granted (skip when --no-secrets)
```

### 7. The one confirmation

Present exactly one structured confirmation (AskUserQuestion) before any
mutation, in full prose — no shorthand here. It must name:

- the recipient as resolved: display name + principal, and whether they are a
  person or a fleet agent
- the mode: full ownership transfer, or share (ownership stays)
- every vault prefix with its permission — stating plainly that **write** lets
  the recipient upload, overwrite, and delete under the project prefix, and
  that access persists until manually revoked
- every secret name that will be granted (read) — values never move, the
  recipient consumes them via `hq run` / `hq secrets exec`
- the repo and branch, including "the branch exists only locally and will be
  pushed" when the repo helper said so
- that a DM will be sent to the recipient when everything verifies

Offer **Proceed** / **Proceed without secrets** / **Cancel**. On cancel:
delete `workspace/delegations/<delegationId>/`, confirm nothing was granted,
transferred, or sent, and stop. This single gate carries the write-grant and
secret-handover confirmations — the helpers are then invoked with `--yes`.

### 8. Execute, in order, stopping at the first failure

```bash
bash core/scripts/hq-delegate-grant.sh --manifest <manifest> --yes
bash core/scripts/hq-delegate-repo.sh --manifest <manifest> --yes        # when the project has a repo
bash core/scripts/hq-delegate-secrets.sh --manifest <manifest> --yes     # or --no-secrets
bash core/scripts/hq-delegate-transfer.sh --manifest <manifest>          # skipped automatically in share mode
bash core/scripts/hq-delegate-verify.sh --manifest <manifest>            # reachability probe — gates the send
```

If any step fails: report **which step** in plain language with the specific
fix from its stderr, send nothing, and never claim partial success. The
manifest keeps its last successful status, so re-running `/delegate` for the
same project resumes instead of re-granting.

### 9. Send

Draft the DM headline, then run the channel-aware humanize pass on it per
`core/knowledge/public/hq-core/humanize-before-send.md` (channel `dm`,
intensity `light`) — plain and factual, no hype. Never rewrite the generated
command lines, recipients, or flags. Then:

```bash
bash core/scripts/hq-delegate-send.sh --manifest <manifest> --send --headline "<humanized headline>"
```

One DM, prompt and brief attached from files. The helper refuses to send
unless the probe passed.

### 10. Report

One plain sentence naming the recipient and what they now have — no step log,
no jargon. Example:

> Done — Alice owns the widget project now. Her DM has the brief and a prompt
> that pulls everything she needs; nothing for her to ask for.

## Rules

1. **Never mint or embed a share-session URL.** Delegation uses direct ACL
   grants only (policy `hq-delegate-never-inlines-secrets-or-share-urls`).
   If a step suggests the browser share flow, that is the wrong path.
2. **Never let a secret value into any artifact, DM, or output.** Names only;
   the helpers fail closed on secret-shaped content — respect the failure,
   never work around it.
3. **Confirm before granting, once.** Exactly one structured confirmation
   covers write grants, secret names, branch push, and the DM. Decline means
   nothing mutates.
4. **Never send blind.** The recipient must come from
   `hq-delegate-resolve.sh` output or be an exact principal the user typed.
   On ambiguity, use the picker; on not-found, stop.
5. **A failed probe means no DM.** A delegation that cannot be picked up
   fails in front of the delegator — that is the feature working, not a step
   to skip.
6. **Tenancy.** Everything is scoped to one company. Cross-company delegation
   is out of scope and must be refused plainly.

## See also

- `/handoff` — session-state freeze without an ownership change
- `/dm` — the delivery channel this skill sends through
- `/hq-share` — one-off vault path shares (link or single grant)
- `/new-agent` — provisioning a fleet agent (the verified-probe pattern this
  skill's verification step follows)
- `core/knowledge/public/hq-core/delegation-bundle-spec.md` — the manifest
  contract every helper reads
