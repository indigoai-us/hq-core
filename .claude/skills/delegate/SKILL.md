---
name: delegate
description: Hand a project to a named person or fleet agent with exact grant receipts, a published dossier, local ownership updates, and a pickup DM. Track recipient access separately through their acknowledgment.
allowed-tools: Read, AskUserQuestion, Skill, Bash(hq:*), Bash(bash core/scripts/hq-session.sh:*), Bash(bash core/scripts/hq-delegate-resolve.sh:*), Bash(bash core/scripts/hq-delegate-bundle.sh:*), Bash(bash core/scripts/hq-delegate-grant.sh:*), Bash(bash core/scripts/hq-delegate-repo.sh:*), Bash(bash core/scripts/hq-delegate-secrets.sh:*), Bash(bash core/scripts/hq-delegate-transfer.sh:*), Bash(bash core/scripts/hq-delegate-verify.sh:*), Bash(bash core/scripts/hq-delegate-send.sh:*), Bash(bash core/scripts/hq-delegate-pickup.sh:*), Bash(rm:*)
---

# /delegate — one-command project handoff

Transfer a project with exact grant receipts, a published dossier, and a pickup
DM. Local board and PRD ownership are updated. Work Mesh ownership remains
unconfirmed until its authoritative system supplies a receipt. Sender-side
checks prove publication, not recipient access; record actual pickup separately.

Requires HQ CLI 5.109.7 or newer, with `whoami --json`, `files acl --json`, and
`people resolve --membership-only`. If those options are unsupported, update
the CLI before retrying; never fall back to parsing display tables.

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

The heavy lifting lives in tested helpers; this skill orchestrates them
and reports what they did. Do not reimplement their logic inline.
Invoking `/delegate` is the authorization — the skill asks the user nothing.

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
none of them touches anything. This is how the skill learns the vault prefixes,
the secret names, and whether the branch needs pushing — it is not a gate, and
nothing waits on the user here:

```bash
bash core/scripts/hq-delegate-grant.sh --manifest <manifest>          # vault grants incl. write escalation
bash core/scripts/hq-delegate-repo.sh --manifest <manifest>           # exit 2 only when a local-only branch needs pushing
bash core/scripts/hq-delegate-secrets.sh --manifest <manifest>        # secret NAMES that will be granted (only skipped when the user typed --no-secrets)
```

### 7. State the plan, then proceed — no confirmation

There is no confirmation step.
The invocation is the authorization for everything the flow does: the user
typed `/delegate` with a recipient, and that is the whole approval. Do NOT present a
Proceed/Cancel picker, do NOT offer alternatives or a reduced variant, and do
NOT raise the vault write grant, the credential handover, the branch push, or
the DM as questions. Nothing here waits on the user.

State — do not ask — what is about to happen, in one compact full-prose block:

- the recipient as resolved: display name + principal, and whether they are a
  person or a fleet agent
- the mode: full ownership transfer, or share (ownership stays)
- every vault prefix with its permission — noting plainly that **write** lets
  the recipient upload, overwrite, and delete under the project prefix, and
  that access persists until manually revoked
- every secret name being granted (read) — this always happens, values never
  move, and the recipient consumes them via `hq run` / `hq secrets exec`
- the repo and branch, including "the branch exists only locally and will be
  pushed" when the repo helper said so
- that a DM goes to the recipient once everything verifies

Then go straight to step 8 in the same turn. `--dry-run` is the preview path
for anyone who wants the plan without the mutation, and `--no-secrets` is the
credential opt-out; both are the user's to type and neither is ever suggested
mid-run.

AskUserQuestion survives for exactly two things, and neither is a permission
prompt: an ambiguous recipient (step 2, exit 3) and a company or project that
could not be resolved (step 1). Those are missing inputs — the skill cannot
name a recipient it cannot resolve. Everything else proceeds unasked.

### 8. Execute, in order, stopping at the first failure

```bash
bash core/scripts/hq-delegate-grant.sh --manifest <manifest> --yes
bash core/scripts/hq-delegate-repo.sh --manifest <manifest> --yes        # when the project has a repo
bash core/scripts/hq-delegate-secrets.sh --manifest <manifest> --yes     # always, unless the user typed --no-secrets
bash core/scripts/hq-delegate-transfer.sh --manifest <manifest>          # skipped automatically in share mode
bash core/scripts/hq-delegate-verify.sh --manifest <manifest>            # reachability probe — gates the send
```

Verification invokes `core/scripts/hq-delegate-publish.sh` to publish the final
PRD, brief, manifest, and journal. It compares canonical cloud bytes with local
checksums before allowing the send. Conflicts or stale canonical files fail
verification; resolve them through HQ sync and reuse the same manifest.

If any step fails: report **which step** in plain language with the specific
fix from its stderr, send nothing, and never claim partial success. The
manifest keeps its last successful status, so re-running `/delegate` for the
same project resumes instead of re-granting. Never delete
`workspace/delegations/<delegationId>/` on failure — that record is what makes
the resume work.

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

If a DM call fails or returns no event receipt, status stays `sending`.
Inspect HQ DM history and reconcile the actual event before retrying. Never
reset that status merely to resend; the previous call may have delivered.

### 10. Close the loop: receipt or FAILED

"Sent" is a send receipt, not a delivery receipt. The delegation is not done
until the recipient demonstrably has it. Record the receipt the moment there is
evidence, and let silence turn into a FAILED state instead of an open question:

```bash
bash core/scripts/hq-delegate-pickup.sh --manifest <manifest> --ack "<their reply, verbatim>"   # they acknowledged
bash core/scripts/hq-delegate-pickup.sh --manifest <manifest> --check                            # probe: recipient commit on the branch? (exit 0 picked-up, 6 waiting, 5 FAILED past the window)
bash core/scripts/hq-delegate-pickup.sh --manifest <manifest> --status                           # one-line state
```

Default window is 72h (`HQ_DELEGATE_PICKUP_WINDOW_HOURS`). A FAILED result names
why (no acknowledgement, no commit by the recipient) so the delegator can
re-send with a direct ask or hand it to someone else. `/startwork` should run
`--check` on any manifest still at `sent`.

### 11. Report

One plain sentence naming the recipient and what they now have — no step log,
no jargon. Example:

> Alice's grants and dossier are verified, and her pickup DM was sent.
> Recipient acknowledgement is pending.

## Rules

1. **Never mint or embed a share-session URL.** Delegation uses direct ACL
   grants only (policy `hq-delegate-never-inlines-secrets-or-share-urls`).
   If a step suggests the browser share flow, that is the wrong path.
2. **Never let a secret value into any artifact, DM, or output.** Names only;
   the helpers fail closed on secret-shaped content — respect the failure,
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
5. **Never send blind.** The recipient must come from
   `hq-delegate-resolve.sh` output or be an exact principal the user typed.
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
  contract every helper reads
