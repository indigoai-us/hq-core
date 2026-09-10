---
name: hq-access
description: Diagnose and fix a vault file you cannot find or open — never existed, not synced (fetch and pin it), or no access (ask the owner with a one-click grant DM).
allowed-tools: Bash(hq:*), Read, AskUserQuestion
---

# /hq-access — the access ladder

When someone cannot find or open a file under `companies/<slug>/…`, do not
reply "the file does not exist". Exactly one of three things is true, and this
skill tells you which and fixes what it can:

1. **never-existed** — the path is not in the vault (offer to create it if a generator exists).
2. **not-synced** — it is in the vault and you can read it, but it is not on this machine. Fetch and pin it.
3. **no-access** — it is in the vault but you lack a grant. Ask the right owner once, with a ready-made grant command.

**User input:** `$ARGUMENTS` — a path (`companies/<slug>/knowledge/report.md` or
`knowledge/report.md`) or free text naming the file ("the August platinum
report"). Optional flags pass straight through: `--company <slug>`, `--no-fix`,
`--yes`.

## Step 1 — Parse the target

- If `$ARGUMENTS` looks like a path (contains `/` or a file extension), use it verbatim.
- Otherwise treat it as a search query. Never guess a key from free text: the
  CLI (or the backup ladder) will search and, on several hits, you MUST ask the
  user to pick with `AskUserQuestion` before touching anything.
- Resolve the company: `--company`, else the `companies/<slug>/` anchor in the
  path, else the active company in `<hqRoot>/.hq/config.json`.

## Step 2 — Run the CLI ladder (preferred)

```bash
hq access "<target>" --json [--company <slug>] [--no-fix]
```

`hq access` ships in `@indigoai-us/hq-cli` **>= 5.109.0**. It vends through
`/sts/vend`, checks the exact prefix ACL (carve-out denies honoured, "no ACL
record" = membership-distributed, not denied), fetches and pins on
`not-synced` (running `hq sync status` / `hq sync doctor` and retrying once if
the fetch fails), and on `no-access` resolves the grantor and asks once before
sending the DM.

Read the JSON: `{ outcome, path, company, exists, steps[], grantor?, localPath?,
requestSentAt?, alreadyAskedAt?, candidates? }`. Exit codes: `0` local or
not-synced, `2` never-existed, `3` no-access or pending-confirmation, `4`
ambiguous.

- `ambiguous` (exit 4): show `candidates` with `AskUserQuestion` (one question,
  the keys as options), then re-run with the chosen path.
- `pending-confirmation` (exit 3): the CLI resolved the grantor but did not send
  because `--json` was used without `--yes`. Go to Step 4.
- Any other outcome: report it in the words of Step 5.

If the command fails with `unknown command 'access'` / `error: unknown command`,
or `hq --version` is below 5.109.0, fall back to Step 3.

## Step 3 — Backup ladder (older CLIs)

Run the same rungs in the same order with the commands every CLI already has.
Stop at the first rung that decides the outcome.

1. **Resolve.** Exact path first. Otherwise
   `hq files search "<query>" --company <slug>`; one hit proceeds, several hits
   go to `AskUserQuestion` (never auto-pick), zero hits → `never-existed`.
2. **Exists?** `hq files browse companies/<slug>/<dir>/ --company <slug>` and
   look for the key. Absent → `never-existed`.
3. **Access?** `hq files acl <company-relative-prefix> --company <slug>`.
   "No ACL record exists" on a company file is normal — treat as accessible.
   `Your effective permission:` missing, `none`, or `deny` (including a carve-out
   deny on the exact prefix under a broader read) → `no-access`.
4. **Not local?** `ls <hqRoot>/companies/<slug>/<key>`. Present → `local`.
   Otherwise `hq files get companies/<slug>/<key> --company <slug>` (materializes
   and pins). If get fails for a non-403 reason: `hq sync status`, then
   `hq sync doctor --reconcile-conflicts` (dry-run; add `--yes` only if it
   reports conflict twins), then retry get exactly once. If the output contains
   a bulk-asymmetry circuit-breaker message, surface it verbatim and stop —
   never override it.
5. **No access → ask the owner.** Grantor = the `Creator:` from `hq files acl`
   if there is a row (map the uid to a person with `hq members list --company
   <slug>`), else the company `owner`, then `admin`s from the same list. Bare
   names go through `hq people resolve <name> --company <slug>`. Then Step 4.

## Step 4 — The one confirmation before the owner DM

Always show the resolved recipient **email** first, then ask exactly one
question (use `AskUserQuestion` when available, plain y/N otherwise):

> Ask `<name> <email>` for read access to `<company-relative-prefix>`?

Only on yes:

```bash
hq dm <grantor-email> "<requester-email> is asking for read access to <prefix> in <slug>." \
  --prompt "hq files share <prefix> --with <requester-email> --permission read --company <slug>"
```

or, when the CLI has `hq access`, re-run it with `--yes`. Never send without
that answer, never send twice for the same (requester, prefix, grantor) within
24 hours (`<hqRoot>/.hq/access-requests.json` is the ledger; say "already asked
<name> <time ago>" instead), and never print share-session URLs or secrets.

## Step 5 — Report in plain language

End with exactly one of:

- `never created` — "`<path>` was never created in the <slug> vault." Offer to create it if a generator exists.
- `not synced, now fixed` — "Fetched and pinned; now local at `<absolute path>`." Then open it.
- `no access, owner asked` — "The file exists but you do not have read access. Asked <name>; you will get a DM when granted."

Never reply "the file does not exist" without naming which of the three it is
(policy `hq-failed-file-open-runs-access-ladder`).

## See also

- `/hq-files` — grants, ACLs, browse/cat/get, pins
- `/hq-sync` — full sync, `hq sync status`, `hq sync doctor`
- `/hq-heal --class access` — routes here
- `/dm` — the notification primitive the request rung uses
