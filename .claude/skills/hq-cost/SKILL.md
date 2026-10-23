---
name: hq-cost
description: Show HQ usage, projected bill and allowance left; preview fixes to cut it.
allowed-tools: Bash(hq:*), Bash(jq:*), Bash(du:*), Bash(test:*), Read, Grep, Edit
---

# /hq-cost — stay under the monthly allowance

Shows what HQ cloud use costs this month, names the biggest drivers in plain
words, and walks the user through one fix at a time. Every fix is previewed
first and runs only after the user says yes. HQ core, the CLI, DMs and deploys
keep working whatever the user picks.

**Args:** `$ARGUMENTS` — optional `--company <slug>` or `--personal`. Pass
them through as the scope flag in the commands below (`<scope>`).

## Rates come from the live card, never from this file

This skill quotes no prices. Every rate, the monthly allowance, the trial and
what is free come from the HQ pricing endpoint (`GET /v1/pricing`), read
through the CLI:

```bash
hq billing usage --card --json
```

- `card.meters[]`: `id`, `label`, `unit`, `unitUsd`, and `waivedInTrial` (the
  vault meter is waived during the trial).
- `card.includedUsd`: usage included free each month. `card.trial`: days and
  usage cap. `card.free`: what is never billed (deploys, DMs, background AI).
- The usage report in Step 1 carries the same rates per meter
  (`bill.meters[].unitUsd`) and the allowance (`bill.allowanceUsd`). Use those
  numbers. When `rateSource` is `bundled`, the endpoint was not reachable and
  the CLI used its shipped copy: say the rates may be out of date.
- Name the source when quoting a rate ("from the HQ price card, version
  `card.version`"). For how billing works, point to
  `core/knowledge/public/hq-core/pricing-and-billing.md`.

## Rules

- **Read first, change later.** Steps 1 and 2 only read. Never run an `apply`
  command, `hq storage prune` without `--dry-run`, `hq secrets delete`,
  `hq daemon sync pause`, git gc, or any reclaim while showing usage.
- **Preview, then yes, then apply.** For each fix: run its `preview` commands,
  show what would change in plain words (what goes, what stays, the saving),
  ask one yes/no question, and run `apply` only on a clear yes. A "no" or no
  answer means nothing changes.
- **Nothing is deleted without a preview** of exactly what will be deleted.
  Deletes are one fix at a time; secrets are one name at a time.
- **Who sees what.** Every person, members included, can see their own
  personal usage (`--personal`), so they can turn off personal cloud services
  such as personal vault sync. Company usage is for the company's owners and
  admins only. The server enforces this, not this skill: the company report
  reads `GET /v1/billing/usage`, which returns 403 for members. Treat a 403 (or
  a "not an owner or admin" error from the CLI) the same as a non-owner role. Use only the companies `hq billing usage` finds in the user's
  own memberships, and never pass a company the user is not a member of. When
  a company report comes back with `scope.role` other than `owner` or `admin`,
  do not show its numbers or drivers: say that company usage is visible to
  its owners and admins, offer the user's personal usage instead, and suggest
  they ask an owner to run `/hq-cost` for the company.
- Use existing HQ commands for every change. Do not write new delete logic,
  call AWS directly, or edit files under `companies/` other than `.hqignore`
  at the HQ root.
- Ask decisions one question at a time.

## Step 1 — Read usage

```bash
hq billing usage --json <scope>
```

- "more than one company": ask which one (list the slugs it printed, plus
  "personal"), then re-run with `--company <slug>` or `--personal`. If the
  company report shows the user is not an owner or admin there, follow the
  "Who sees what" rule and switch to `--personal`.
- Not signed in: tell the user to run `/hq-login` and stop.
- The cloud storage listing can take a minute or two on a large company. If
  the user wants it faster, re-run with `--no-storage-scan` (no old-versions
  split).

The JSON is a `UsageReport`:

- `scope`: `kind` (`company` or `person`), `companySlug`, `role`.
- `bill`: `meters[]` (per meter: `key`, `displayName`, `unit`, `unitUsd`,
  `value`, `state`, `monthToDateUsd`, `projectedUsd`), `monthToDateUsd`,
  `allowanceUsd`, `allowanceLeftUsd`, `projectedUsd`, `projectedBillUsd`,
  `incomplete`, `daysElapsed`, `daysInMonth`.
- `storage` (when scanned): current vs old-version bytes, `canDelete`.
- `drivers[]`: `meter`, `summary`, `projectedUsd`, and `fixes[]` (`id`,
  `title`, `detail`, `preview[]`, `apply[]`, `savesUsdPerMonth`,
  `blockedReason`).
- `rateSource`, `trialActive`, `freeItems`, `noSyncGuideUrl`, `period`.

## Step 2 — Show it

A short table: meter, amount, rate, projected cost, all from `bill.meters[]`.
A meter whose `state` is `not-available` shows "not counted here yet", never
zero. Then:

- Used so far (`bill.monthToDateUsd`) and allowance left
  (`bill.allowanceLeftUsd` of `bill.allowanceUsd`).
- Projected month total (`bill.projectedUsd`) and projected bill after the
  allowance (`bill.projectedBillUsd`). When `bill.incomplete` is true, say "at
  least" and explain that some meters arrive with the daily usage rollup.
- When `trialActive` is true, say which meters the trial waives
  (`waivedInTrial` on the card).
- Each driver's `summary`, biggest first, with the fixes it offers and the
  saving from `savesUsdPerMonth` when present. Savings always come from the
  server's `fixes[].savesUsdPerMonth`; never compute one from rates.
- For someone using HQ on their own (`scope.kind` is `person`): their personal account gets its
  own allowance each month, and usage above it is billed to them.
- What is free (`freeItems`), and that no card is needed to sign in, deploy or
  use DMs.

If the projected bill is zero and nothing is incomplete, say so and stop
unless the user asks for more.

## Step 3 — Pick a fix

Ask which fix to look at (one question; include "none"). Skip fixes with a
`blockedReason` and show the reason instead.

### prune-old-versions — delete old file versions

1. Run the preview (`hq storage prune --cloud-before <date> --company <slug> --dry-run --json`).
2. Show how many versions and how many GB would go, the date cutoff, that
   current files are not touched, that this cannot be undone, and the saving
   from the fix's `savesUsdPerMonth` in the report. Do not compute savings
   yourself; when `savesUsdPerMonth` is missing, say the saving is not known.
3. Ask: "Delete these old versions?" On yes, run the `apply` command.

### remove-unused-secrets — remove secrets nothing uses

1. Run the preview (`hq secrets [--company <slug> | --personal] list`).
2. HQ does not record when a secret was last read. To suggest candidates, search
   for each name in the user's repos and HQ (`Grep` for the name in
   `.env.schema`, `.env.example`, `hq run`/`hq secrets exec` scripts, skills and
   worker files). A name with no reference and an old "last modified" date is a
   candidate. Never read secret values.
3. Show the candidate names and the secret meter's rate (`unitUsd`) as the
   price of one secret. For the fix's total saving use its `savesUsdPerMonth`
   from the report; do not multiply it out yourself. Let the user pick names.
4. Confirm the final list. Delete one name at a time with the `apply` command
   (`... delete <NAME> --force`), reporting each result.

### exclude-folders — stop syncing folders

1. Run the preview (`hq sync mode --show`, `hq storage status --company <slug> --json`)
   and measure the biggest local folders under the company with `du -sh`.
2. Propose `.hqignore` lines (one folder per line, for example `exports/`) and
   show the exact lines that would be added to `<HQ root>/.hqignore`.
3. On yes, append them (never rewrite or remove existing lines). Explain that
   sync stops uploading those folders, files already in the cloud stay until
   removed, and nothing local is deleted. For a member who only needs some
   folders, `hq sync mode shared` narrows what is downloaded; preview it with
   `hq sync narrow` (dry run by default) and apply only on yes.

### turn-sync-off — turn cloud sync off for one vault or all of them

Sync is switched per vault on this computer: the personal vault, each company
vault, or all cloud sync at once. The switches live in the HQ app under
**Settings > Sync**, one click from the usage meter ("Turn sync off or on for
each vault") and from the account menu (**Sync**). This skill cannot flip
them; the user does.

1. Preview: run `hq sync mode --show` and `hq daemon sync status --json`, and
   list the vaults this computer syncs (personal plus each company). Point at
   the vault the drivers name, for example the company with the most syncs.
2. Explain, per vault the user picks: turning it off stops this computer's
   syncs for that vault, so they stop counting from now on. It does not end
   that vault's charges: the vault fee and its cloud storage continue, and
   teammates who still sync it keep adding sync usage. Never describe it as
   "no more sync charges" or "no sync fees". Its files stay on this computer,
   and teammates (or, for the personal vault, the user's other computers) stop
   getting this computer's changes. Other vaults keep syncing. It changes only
   this computer, never teammates. Files already in the cloud stay and still
   count as storage until removed. Sign-in, HQ core, the CLI, DMs and deploys keep working.
3. Ask which to turn off: one vault, several, or **Turn off all cloud sync**.
   Then have the user flip the switch in Settings > Sync. The app shows "Sync
   is off for <vault>" and how to turn it back on.
4. The CLI honours the same switches: `hq sync push|pull|now` for a vault
   that is off is refused (exit code 3, nothing uploaded or downloaded), and
   `hq sync now --all` skips the off vaults. Confirm with one read:
   `hq sync status`. The per-vault Sync section ships in the HQ desktop app
   0.11.15 and later; if this computer's app has no Sync section, ask the
   user to update the app first.
5. No desktop app (CLI-only install where the daemon owns sync): on yes, run
   `hq daemon sync pause` (resume later with `hq daemon sync resume`). To keep
   the daemon from starting sync at all, the user can also run
   `hq daemon disable sync`.
6. Turning sync off only stops syncing. This skill never copies vault files
   to a new place, never creates a repo for them, and never pushes them
   anywhere: company data stays in the vault. If the user wants to share the
   files another way, tell them to make that move themselves and name the
   risk: files copied out of the vault lose its access rules, so anyone who
   can read the new place (a git repo, its GitHub owner, every clone) can
   read them, and the company may not allow that. Point to the no-sync guide
   (`noSyncGuideUrl` from the report) and stop there.
7. Confirm the rest of HQ still works:
   - CLI: `hq --version` and `hq whoami`.
   - DM: `hq dm inbox` (read). Offer to send the user a test DM to themselves
     through `/dm`; send only on yes.
   - Deploy: deploys go through `/deploy` (there is no `hq deploy` command).
     Offer to deploy a one-page test artifact; deploy only on yes, and report
     the URL.
   Report each check as passed or failed in one line.

## Step 4 — Re-read and show the new bill

After any applied change, run `hq billing usage --json --fresh <scope>` and
show the new projected bill next to the old one. Storage reflects a prune
right away; secret counts can take a few minutes. If nothing moved, say why
(for example, only this computer's syncs stop counting, and only from now
on).

Then offer the next driver, or stop.

## Notes

- `hq billing usage` (hq-cli 5.345.144 or later) reads rates from
  `GET /v1/pricing`, storage and secrets from `GET /v1/billing/usage-limits`,
  and the live cloud version listing. Call-count meters (syncs, gateway calls,
  HQ MCP calls, agent runs) come from the daily usage rollup
  (`GET /v1/billing/usage`) once the CLI reads it; until then they show "not
  counted here yet" and the bill says "at least". This skill reads only what
  the CLI reports, so it needs no change when the CLI switches source.
- Own-cloud options (your own storage bucket, full self-host) are not offered.
