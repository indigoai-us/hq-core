---
type: reference
domain: [operations, engineering]
status: canonical
tags: [outposts, company-outposts, scheduled-jobs, integrations, lanes]
relates_to:
  - core/knowledge/public/hq-core/outpost-jobs-spec.md
  - core/knowledge/public/hq-core/hq-cli-reference.md
  - core/policies/hq-suggest-outpost-uses.md
---

# Company Outposts

An Outpost is a cloud machine that runs HQ work while your own computer is off.
A company Outpost is the same machine with two differences: it syncs one
company's vault, and the company's owners and admins decide which members may
use it. The company pays for it.

Outposts are company-scoped by default. Create a personal Outpost (your own
machine, billed to you, carrying your personal HQ) only when the user says they
want a personal one. When a user asks for "an Outpost" while working for a
company, create or use that company's Outpost.

Commands below follow the help text of hq-cli 5.345.241. `<company>` is the
company slug. `<outpost>` is an Outpost name or id from `hq outposts list
--company <company>`.

## Create one (owners and admins)

1. Get the quote. Run the create without `--yes`:

   ```bash
   hq outposts provision --company <company> --size small
   ```

   Without a terminal, this prints the quote and stops. Nothing is created or
   billed. The quote has three lines: the machine price for the size, the disk
   (sized to the company vault, with the vault size and the date it was
   measured), and the monthly total billed to the company.

2. Show the quote to the user and ask for a yes. Then create it:

   ```bash
   hq outposts provision --company <company> --size small --yes
   ```

Sizes are `small`, `medium`, `large` and `xlarge`. Without `--size`, a terminal
shows a menu and a script is billed the small price. A company that already has
an Outpost gets another one. Members cannot create one; they use `hq outposts
request` (see Members below). `--runtime`, `--disk` and `--client-ip` apply to
personal Outposts only, and `codex-enable` works on personal Outposts only.

## Find it and check it

```bash
hq outposts list --company <company>
hq outposts status --company <company> --outpost <outpost>
```

`hq outposts list` without `--company` lists only your personal Outposts. A
company Outpost never shows there.

When the company has more than one Outpost, pass `--outpost <outpost>` on every
company command (`status`, `exec`, `terminal`, `login`, `login-code`,
`refresh-config`, `destroy`, `access`, `jobs`). The hints the CLI prints do not
always include it.

`status` shows the state, the Claude sign-in state, and every job with its last
run, next run and outcome.

## Company files on the box

File sync is on by default. Unless it has been turned off for the company, it
starts within a few minutes after the Outpost is ready. The first download can
take more than an hour for a large vault. The sync state is in the
`companySync` field of `hq outposts status --company <company> --outpost
<outpost> --json`; the plain-text output does not show it yet.

The company's files are stored at `/opt/hq-company-jobs/companies/<company>/`
on the box. In an `exec` or `terminal` session, `~/hq/companies` is a link to
that folder for the shell user. Jobs run as a separate account that cannot
reach `/home/ec2-user`, so job prompts must use the `/opt/hq-company-jobs/...`
path. Meeting notes are under `sources/meetings/` and extracted signals under
`signals/`, the same layout as on a laptop. Files a job or a person writes
there reach other devices on the next sync cycle. They are not instant.

## Claude sign-in (owners and admins)

Jobs run only after the box is signed in to Claude.

1. `hq outposts status --company <company> --outpost <outpost>` prints a
   sign-in link while the box waits. Give the user that link to open.
2. The user signs in and gets a code. Submit it:

   ```bash
   hq outposts login-code --company <company> --outpost <outpost> <code>
   ```

The `Next:` hint that `status` prints after the link shows `hq outposts
login-code --company <company> <code>` without `--outpost`. When the company
has more than one Outpost, add `--outpost <outpost>` yourself.

`hq outposts login --company <company> --outpost <outpost>` asks for a fresh
link when the old one expired.

## Run commands and get files

```bash
hq outposts exec --company <company> --outpost <outpost> -- '<command>'
hq outposts terminal --company <company> --outpost <outpost>
```

`exec` runs as `ec2-user` by default and waits for the result. Use `--async`
for commands longer than about 20 seconds, or `--detach` and then
`hq outposts exec-result --wait`. `terminal` needs the AWS session-manager
plugin on the local machine. `terminal --forward <port>` tunnels a port on the
box to your machine.

`hq outposts pull <outpost> <remote-path>` takes a personal Outpost id and has
no `--company` option. For a company Outpost, write the file into the company
folder and let it sync, or print a small file with `exec`.

## Scheduled jobs

A job is a prompt that Claude runs on the box on a schedule. Register it, then
confirm it is listed in `status` with a next run time.

```bash
hq outposts jobs register --company <company> --outpost <outpost> \
  --prompt "<what to do>" --cron "0 8 * * 1-5" --timezone America/New_York
hq outposts jobs run-now --company <company> --outpost <outpost> <jobId>
hq outposts jobs runs --company <company> --outpost <outpost> <jobId>
```

`--cron` takes `rate(N minutes|hours|days)`, a five-field cron with `*` for day
of month and month, or the AWS `cron(...)` form. `--at <iso>` makes a one-time
job. `edit`, `pause`, `resume`, `delete`, `run-now` and `runs` take the job
id. `edit` and `delete --yes` also need `--revision` with the latest accepted
revision (the one `register` or the last `edit` printed). `runs` is
for owners and admins and shows each run's outcome and the reason a run
failed. Full run output stays on the box.

Inside a job, `hq` calls run as the Outpost's own identity. A job can:

- read and write the company files under `/opt/hq-company-jobs/companies/<company>/`
  (use this path in job prompts, not `~/hq`);
- call company apps through `hq integrations call`, limited to apps connected
  in the company and shared with the company's members (check with
  `hq integrations list --usable --company <company>`). A change-making call
  may be queued for an owner's approval, depending on the app's policy;
- read secrets that were explicitly granted to the Outpost.

The detailed runner design is in [outpost-jobs-spec.md](outpost-jobs-spec.md).

## Members

A member who wants to use an existing company Outpost asks for access. A member
who wants a new one asks for it.

```bash
hq outposts request-access --company <company> --outpost <outpost> --note "<why>"
hq outposts request --company <company> --size small --note "<why>"
```

Owners and admins review requests and manage access:

```bash
hq outposts requests --company <company>
hq outposts approve --company <company> --request <id>
hq outposts decline --company <company> --request <id> --reason "<why>"
hq outposts access list --company <company> --outpost <outpost>
hq outposts access grant --company <company> --outpost <outpost> --person <prs_id>
hq outposts access revoke --company <company> --outpost <outpost> --person <prs_id>
```

`approve` shows who asked, what for and the price before it approves.
Without a terminal, `approve` and `access grant` need `--yes`. Granted
access gives the member full control of the box, including root, until it is
revoked. Revoking closes the member's open terminals. An approved member can
use `exec` and `terminal`; sign-in, `refresh-config` and `destroy` stay with
owners and admins.

## Destroy (owners and admins)

```bash
hq outposts destroy --company <company> --outpost <outpost> --yes
```

This permanently removes the box and stops its billing. Ask the user first.
Files that already synced stay in the company vault.

## Lanes and runners

`hq runners create` (alias `hq lanes`) accepts `--company <company> --outpost
<opc_id>`. Lanes placed on a company Outpost do not start yet. Lanes on a
company Outpost are refused until the server marks that Outpost ready for
lanes in the company Outpost list; a refused lane prints that the Outpost "is
not set up for lanes yet" and dispatches nothing. `--placement auto` skips
company Outposts that are not marked ready. Run lanes on a personal Outpost or
on the local machine for now. To run recurring company work on a company Outpost, use
a scheduled job. `/outpost-host` (serve an app from the box) runs only in a
session on the box itself.

## Known limits today

- A company Outpost cannot send HQ DMs or email from a job. Have the job write
  its result into the company folder, or post through a company app such as
  Slack when that app is usable.
- Changes made on the box reach other devices on the next sync cycle.
- Lanes placed on a company Outpost do not start yet (see above).
- The sign-in hint in `status` leaves out `--outpost`. Add it when the company
  has more than one Outpost.
- `hq outposts pull` works with personal Outpost ids only.
- One company job runs at a time on a box. A job's default time limit is 10
  minutes and the maximum is 4 hours.

## Suggesting uses

When a user creates or starts using an Outpost, follow
`core/policies/hq-suggest-outpost-uses.md`: look briefly at the user's recent
work, propose one to three jobs, and connect only the apps those jobs need.

Generic jobs and what each needs. None of them has yet been tested end to end
on a company Outpost, so run each once with `run-now` and check `runs` before
telling the user it works.

| Job | What it needs |
|---|---|
| Daily brief from meetings | File sync on, and meeting notes in `sources/meetings/` (the company records meetings with the HQ meeting bot). Not yet tested end to end on a company Outpost |
| Daily brief that adds team chat | The above, plus Slack (or the team's chat app) connected and shared with the company. Not yet tested end to end on a company Outpost |
| Morning summary of open pull requests and failing checks | GitHub connected and shared with the company. The box has no `gh` CLI. Not yet tested end to end on a company Outpost |
| Weekly digest of new and changed files in the company vault | File sync on. Not yet tested end to end on a company Outpost |

Each job writes its result to a file in the company folder, for example
`/opt/hq-company-jobs/companies/<company>/reports/<job-name>/<date>.md`, which
reaches the user's other devices on the next sync.
