---
name: daily-brief
description: Build the user's Daily Brief across personal work and every permitted company. Reads the last brief and the user's brief preferences, sweeps sessions, PRs, CI and DMs (plus meeting signals, fleet and connected integrations when a company is bound), writes brief-data.json and brief.json with a launch prompt for every action, and reports status so the desktop app can notify the user. The person's first ready brief adds a welcome edition. Run by the main local bot when the user presses Create brief, or on a schedule.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash
---

# /daily-brief

Builds one person's Daily Brief across personal work and every permitted company by default. The HQ desktop app starts this through the main local bot when the user presses **Create brief**. A person can also run it directly with `/daily-brief [--all|company|--personal] [--welcome] [--today YYYY-MM-DD]`.

An explicit personal brief (`--personal`) reads only what belongs to the person on this machine and in GitHub: work sessions, PRs, main-branch CI and personal DM messages (messages with no company). The company-only sources (meetings, meeting signals, fleet agents and integrations) are skipped and recorded as skipped, and housekeeping skips the doctor and sync checks. A new user with no company gets a useful first brief this way.

The output is a set of files the desktop app reads. This skill never posts, sends, merges or deploys anything.

## Inputs

| Input | Default |
|---|---|
| `--all` | Default: personal work plus every membership permitted by the session lock |
| `company` | Explicit first argument selects only that company |
| `--personal` | Build a brief with no company, even when the session has one bound |
| `--welcome` | Add the welcome edition (Welcome edition, below). On by default for the person’s first ready run in any mode |
| `today` | Today's local date |
| `run_id` | `--run-id <id>`, passed by the app. If missing, generate one as `brief-<YYYYMMDD-HHMMSS>` in local time |

Briefs are manually triggered, so several can exist per day. Each run gets its own folder, `workspace/brief/<run_id>/`. The `run_id` is `brief-<YYYYMMDD-HHMMSS>` in local time.

| File | Written when | What it is |
|---|---|---|
| `status.json` | At every step | Progress the app polls |
| `brief-data.json` | Step 3 | Raw normalized sweep output |
| `brief.json` | Step 4 | Synthesized items with prompts, read by the generator |
| `housekeeping.json` | Step 5 | Cleanup results and proposed cleanup actions |

When a run finishes, ready or failed, append one line to `workspace/brief/index.jsonl`. The desktop app's history navigator reads this file:

```json
{"run_id":"…","created_at":"…","finished_at":"…","duration_s":0,"window":{"from":"…","to":"…"},"state":"ready|failed","mode":"company|personal","company":"acme|null","catch_up":false,"lead":"…","counts":{"decisions":0,"shipped":0,"incidents":0,"carry":0,"recovered":0},"landed":false,"headline":"one plain line"}
```

`counts.shipped` is `brief-data.json.prs_summary.merged`, the same number the loader and the brief show. `counts.carry` and `counts.recovered` are the lengths of `items.carry` and `items.recovered`; `landed` is true when the run saw at least one merged PR or a release. `brief_rank.py --check` prints `index_counts` and `landed` ready to copy.

`status.json` shape:

```json
{"run_id":"…","state":"running|ready|failed","step":"…","progress":0.0,"started_at":"…","updated_at":"…","error":null,"sources":{}}
```

Write `status.json` before each step, and again after every source and integration check, so the app's progress bar stays truthful and keeps moving. Also keep a rolling `activity` list in `status.json`, newest last, capped at 12 entries. The app shows it under the sunrise so the user can see the run is alive:

```json
"activity":[{"at":"…","label":"Read 42 work sessions","state":"done","detail":"Oct 4–9"},{"at":"…","label":"Checking GitHub PRs","state":"running"}]
```

As each source lands, also update `findings` and `samples` in `status.json`. The app animates these as live counters and preview cards:

```json
"findings":{"signals":{"decision":0,"action_item":0,"risk":0,"commitment":0,"key_point":0},"sessions":0,"meetings":0,"dms":{"total":0,"need_you":0},"prs":{"merged":0,"opened":0,"open":0,"review_requested":0},"ci_red":0,"agents":{"total":0,"attention":0},"integrations":{}},
"samples":[{"kind":"decision","title":"Approve release-gate fix","company":"acme","at":"…"}]
```

`samples` holds at most 8 items, all from the active company only (`company` is null on a personal brief). Titles are short and plain. Never include DM body text: use the sender name and a summary instead.

`state` is `running`, `done`, `skipped` or `failed`. Labels are plain, user-facing language with real counts ("Found 31 DMs, 4 need you"), never commands or file paths. For other-company items, give counts only. Spread progress evenly across the sweep (0.25 → 0.7) by source, and across the integration checks. Read every timestamp from the clock in the same command that writes it.

## Step 1. Start

Write `status.json` with `state: running`, `step: "Checking your setup"` and `progress: 0.05`.

Check the session's company (`bash core/scripts/hq-session.sh current`). Never sweep a company the session is not locked to. The sweep reads the lock with `bash core/scripts/hq-session.sh get company_slugs` and refuses `--company` when that slug is outside the locked set.

- Default to a person brief (`--all`), including personal work and a section for each permitted company. `--company <slug>` and `--personal` remain explicit narrow modes.
- Membership inventory comes from the read-only `hq sync mode --show` table (the caller's memberships), intersected with `hq-session.sh get company_slugs`. Never widen the lock. Show every excluded membership as "not included: open HQ in that company to include it". Inventory/lock failures are visible source failures, never an invented empty membership list.

## Step 2. Load what we know about this person

- Read `personal/brief/brief-prefs.yaml`. If it is missing, create it from the defaults below. Besides `density`, `engine` and the VIP and mute lists, read the widget preferences the app's picker uses: `widget_weights` (kind → -2..2), `pinned_widgets` and `muted_widgets`. Step 4 copies them into `prefs_applied.widgets`.
- Find the last brief: the newest `ready` entry in `workspace/brief/index.jsonl` with `mode: person` for an all-company brief; for explicit narrow modes use the same company and mode. Skip lines that name another company. A line with no `company` field is an older run: use it only when its `brief.json` or `brief-data.json` has the same `company`. Read that run's `brief.json` too: its `items` are the carry-over candidates, and its `carry` rows give `carried_since` and `briefs` for chaining (Step 4, carry).
  - **Deliberate reset.** If `workspace/brief/` is missing or holds no earlier run (no other run folder and no `ready` line in `index.jsonl`) and a sibling `workspace/brief-backup-*` folder exists, the owner reset brief history on purpose. It is not an incident, problem or decision, and never part of the lead. Treat the run as a first brief with no carry-over, label the activity "Starting fresh brief history", and leave the one-line note to housekeeping (Step 5). `brief-data.json.brief_history.reset_on_purpose` records the same check. A missing folder with no backup next to it is also only a housekeeping note, never the lead.
  - **Window:** always the last 24 hours. The brief is a picture of the user's day, not a diff since the last run; a second run an hour later shows the same day again with the new items added. Only a catch-up brief widens the window: to the gap since the last brief, capped at 14 days.
  - **Catch-up:** if the gap since the last brief is 3 days or more, set `catch_up: true`.
  - Carry-over still uses the last brief: an item that was in it and is still open is marked `carry`, never dropped as "nothing new".
- Read the last brief's items. Anything still open becomes a carry-over candidate. Note what was launched or dismissed, from `personal/brief/brief-log.jsonl`.

Write status `step: "Reading your last brief"`, `progress: 0.15`.

## Step 3. Sweep

Run the sweep script. It records each source's success or failure, and never fills a gap with an invented value.

`--hours 24` is the brief's window: sessions, PRs and meetings from the last 24 hours. `--days 7` is only the per-day rollup (`days`) the week arc copies; it never widens the brief. For a catch-up brief (the user has been away 3 or more days) add `--catch-up` and set `--days` to the number of days since the last brief (at most 14), which keeps the meetings from that gap.

```bash
python3 -I .claude/skills/daily-brief/scripts/brief-sweep.py \
  --all --days 7 --hours 24 --today <today> \
  --hq-root "$PWD" --out workspace/brief/<run_id>/brief-data.json \
  --status workspace/brief/<run_id>/status.json
```

For a narrow brief, replace `--all` with `--company <slug>` or `--personal`. Add `--welcome` to force the welcome edition.

On a company brief, PR search is limited to the company's GitHub owner: `--org <owner>`, or else the company's `github_org` in `companies/manifest.yaml`. With neither, and on a personal brief, it covers every owner the user's `gh` login can see. PRs from an owner that `companies/manifest.yaml` maps to another company (to any company, on a personal brief) are dropped and only counted in `prs_other`. The worktree scan treats worktrees the same way: they count in `detail.other` and their paths are never listed. Main-branch CI checks the repos of the user's own PRs in the window (most PRs first, at most 8); `--repos a,b` names them instead, as bare names (owner from `--org` or the PR rows) or owner-qualified names.

The script covers these sources:

| Source | Read through |
|---|---|
| Work sessions | Sessions come from `workspace/sessions` meta files plus the Claude and Codex transcripts (title, and kind you, agent or lane), for the last 24 hours (`--hours`). Other-company sessions are a count only. |
| Recorded meetings, plus each meeting's signals (company only) | `hq meetings list` and `get`. Per meeting, up to 5 decisions and 5 action items carry `text` (the signal's summary line, never transcript text), `owner`, and `mine` (the owner is the user, matched against `--me` or `git config user.name`) |
| DM inbox | `hq dm inbox`, then only this company's messages. A personal brief keeps messages with no company. Another company's messages are dropped and never written. Agent senders, with `agt_` IDs, are labeled. On a company brief, if the inbox page has messages and none carry a company slug field (`company`, `companySlug` or `company_slug` on the message or its channel), the source is skipped with `skipped_reason: "inbox has no company tag"`. `companyUid` is an id, not that field, so a page that only has it is still skipped. An empty inbox is a real empty result, not a skip. |
| Fleet agents (company only) | `hq agents list` |
| The user's PRs | `gh search prs --author @me` (with `author`), plus open PRs where the user is a requested reviewer (`--review-requested @me`, marked `review_requested: true` and `reviewRequests: ["@me"]`). Each row has `product`, `repo`, `repo_full` (the owner-qualified name), `authored_by_me` and `is_release`. Read-only |
| Main-branch CI health | `gh run list` |

Every source has an entry in `brief-data.json.sources` with `state`: `ok` (it ran), `failed` (it ran and broke; `note` and `error` hold one plain line such as "Couldn't read DMs."; the exception text goes to stderr only) or `skipped` (left out on purpose; `skipped_reason` says why). On a personal brief the company-only sources use `needs a company`. On a company brief, DMs use `inbox has no company tag` when the inbox page cannot be filtered by company. `ok` is true only for `state: ok`. A skipped source's top-level key is null. The top-level `mode` is `person`, `company` or `personal`. In person mode, `personal` holds personal sources and `companies.<slug>` holds each company sweep; `company` is null at the root. Each section has its own sources, window, derived summaries and deltas. Person history compares only previous `mode: person` runs, matching company sections by slug.

A skipped source is not a failure and not an empty result. The sweep writes its activity entry with `state: skipped`, a plain label (`Skipped DMs` for the inbox) and `detail` set to `skipped_reason`. It does not write `findings.dms` as `{total: 0}`, and it does not say there were no messages. The brief copies that: when `sources.dms.state` is `skipped`, write no DM decisions, waits or people from the inbox, and do not say the inbox was empty. One clause is enough: "DMs were skipped; the inbox has no company tag."

The script also writes `window.today`, `window.hours`, `window.prs_from`/`prs_to`, `window.attended_meetings_from` (= `sessions_from`, or the first catch-up day), and a top-level `prs_summary: {merged, opened, open, review_requested, median_merge_hours, by_product}` for the 24-hour window, counting only the user's own PRs. The loader's PR line uses the same function, so the app and the brief show the same numbers.

Derived data the sweep adds for the app's widgets (all computed, never estimated; every helper has a unit test in `scripts/test_brief_additions.py`):

| Block | What it carries |
|---|---|
| `sessions[]` | `project` (repo from the cwd), `product` (its human name), `cwd`, `last_activity`, `has_handoff` (a handoff thread record exists). Other-company rows keep only times and counts. On a personal brief the person's own rows, the ones bound to no company, carry `company: "personal"`; rows bound to any company count as `other` |
| `prs[]` | `closed` is null on open rows, `isDraft`, `merge_hours` on merged rows, `reviewDecision` and `reviewers` on open rows (a bounded `gh pr view`, null when it did not run) |
| `prs_summary.by_product[]` | `{product, merged, opened, open, median_merge_hours}` for the window |
| `releases[]` | `{product, repo, version, merged_at, url, pending_count, pending_by_day: [{day, count, theme}]}`: the latest merged Release PR per repo and the merges that landed after it |
| `main_health[repo].red[]` | `{workflow, since, merges_on_top}`; `since` is the first red run found (carried back to the previous run's value when it was already red). `delta: {newly_red, still_red, recovered}` against the previous ready run, null when there is none |
| `fleet` | `stuck: [{name, status, phase, since}]` (setup failed or waiting, or a status that is not resting; dormant is not stuck), `delta: {newly_stuck, still_stuck, recovered}` by name, `series: [{generated_at, stuck}]` one bucket per prior ready run. `sources.fleet.count` is the agent count |
| `meetings[]` | only meetings whose start is inside the window, deduped by title and start (`duplicate_ids` keeps the folded ids), with `participants` (names), `end`, `duration_min` and `attended` (the user is in the participants, the title or owns one of its signals). The `days` rollup still counts every meeting fetched |
| `meeting_signals[]` | unchanged shape, plus `detail`; owner inference also reads "X decided to" and "X agreed to" |
| `dms[]` | `need_you` (looks like an ask: "?", "can you", "please", "need you", "waiting on"; the writer confirms each one by reading the preview), `direction` and `thread_id` (null until the inbox exposes them). `sources.dms` records `truncated` and a `note` when the 40-message page did not reach back to the window start. When the source is skipped, `dms` is null and there is no truncation note |
| `previous_run` | `{run_id, generated_at}` of the previous ready run, found through `index.jsonl`; null for a first brief |
| `welcome` | The welcome edition (below), or null |

Then, on a company brief only, run the **integration checks** that matter to this user. A personal brief skips them; the sweep has already recorded `sources.integrations` as skipped. Use `bash core/scripts/usable-integrations.sh show --company <company>`, and only check apps that are connected:
- **Linear or Jira:** issues assigned to the user that changed or are due.
- **GitHub:** review requests waiting on the user.
- **Gmail:** threads from VIP people with no reply.
- **Calendar:** today's events. The desktop app supplies these from /v1/calendar/events, so only fill them when running outside the app.
- **Anything listed in `prefs.integrations`.**

Record each check in `brief-data.json.integrations[<app>] = {ok, count, items, error}`. Skip an app quietly when it is not connected. Never ask the user to connect one in the middle of a run.

Write status `step: "Sweeping your day"`, from `progress: 0.25` up to `0.7`. Include the per-source `sources` map so far.

### Welcome edition

`brief-data.json.welcome` is set when `--welcome` is passed, or on the person’s first ready run in any mode (no earlier ready run in `index.jsonl`). Otherwise it is null. It is built from local data only:

```json
"welcome":{"first_run":true,"headline":"HQ found 2,263 past sessions across 41 projects on this Mac, most of them in Claude Code.",
 "import":{"path":null,"scanned_at":null,"source":"detected","written_at":null,"plans":null,"…":null,
           "sessions":{"total":2262,"claude":2037,"codex":225,"cursor":0,"days_seen":96,"first_at":"2026-07-14","last_at":"2026-10-17"},
           "tools":["claude-code","codex"],"projects":41},
 "sessions":{"total":2263,"local":2263,"imported":2262,"claude":2038,"codex":225,"days_seen":96},
 "harness":{"primary":"claude-code","counts":{"claude_code":2038,"codex":225,"cursor":3},
            "action":{"id":"open-hq-in-harness","kind":"open_harness","harness":"claude-code","label":"Open HQ in Claude Code","launch_prompt":"…"}},
 "top_projects":[{"name":"web-app","path":"~/code/web-app","sessions":310,"last_active_at":"2026-10-17T21:02:11Z","harness":"claude-code"}],
 "top_repos":[{"name":"web-app","path":"~/code/web-app","sessions":310,"last_commit_at":"2026-10-17T20:55:03-07:00"}],
 "recent_work":[{"title":"Fix the signup redirect","project":"web-app","at":"2026-10-17T21:02:11Z","harness":"claude-code"}],
 "repos":[{"name":"web-app","sessions":9}],"apps":["Claude Code","Codex","Cursor"],
 "tree":{"companies":2,"projects":14,"knowledge_files":380},
 "actions":[{"id":"connect-company","kind":"connect_company","label":"Create or join a company","reason":"…","launch_prompt":"/onboard","primary":true}],
 "next_steps":[{"id":"connect-company","kind":"connect_company","reason":"…"}]}
```

Field names live in one constant block in `brief-sweep.py` (`WELCOME_FIELDS`, `WELCOME_SESSION_FIELDS`, `WELCOME_PROJECT_FIELDS`, `WELCOME_REPO_FIELDS`, `WELCOME_RECENT_FIELDS`, `WELCOME_TREE_FIELDS`, `WELCOME_ACTION_FIELDS`, `WELCOME_ACTION_KINDS`). The desktop app hides any absent field. `first_run`, `import`, `sessions`, `repos`, `apps` and `next_steps` keep their earlier meaning.

- `headline`: one plain sentence about the person's own past work. Its project count leaves out folders with a session in another company. With zero sessions it is the first-steps line instead.
- `import` (fields in `IMPORT_FIELDS`): `{path, scanned_at, source, written_at, <counts>, sessions, tools, projects}`. With a report it comes from the newest `workspace/imports/<stamp>/report.json` (see "Import report contract" below): `scanned_at` is the folder's UTC time (`2026-10-19T15:00:28Z`; the report's `scan_id` is never copied), `source` is the report's `source` (`desktop-tree-step`, else `import-context`), the per-category counts are `plans`, `commands`, `skills`, `hooks`, `policies`, `agents`, `claude_md`, `settings_fragments`, `mcp_servers`, `knowledge_dirs`, `claude_repos` and `conversations` (session stores, not sessions), `sessions` is `{total, claude, codex, cursor, days_seen, first_at, last_at}`, `tools` lists the harness ids found, and `projects` is how many project names the report lists (the names are never copied, because the report covers every company). Counts are non-negative integers; a negative, boolean, decimal or text value reads as 0 (null inside `sessions`). Without a report, when any session other than the one running the brief is on this Mac, `source` is `detected`, `path`, `scanned_at`, `written_at` and the counts are null, and `sessions`, `tools` and `projects` come from the machine inventory (`total`, `claude` and `codex` leave out the running session; `first_at` and `last_at` are dates; `projects` leaves out folders with a session in another company). Past sessions are the inventory's transcripts, so an HQ-started session and its transcript count once. The session running the brief is read from `CLAUDE_CODE_SESSION_ID`, `CLAUDE_SESSION_ID`, `CODEX_THREAD_ID` or `CODEX_SESSION_ID`. When none of those ids is in the inventory, a transcript written to in the last 10 minutes is treated as the running session and left out. Null only when there is no report and no other session.
- `sessions`: `local` counts every session on this Mac, one per session id: HQ-started sessions, every Claude Code transcript (under `~/.claude/projects` and the `CLAUDE_CONFIG_DIR` projects folder), every Codex rollout (`CODEX_HOME`, else `~/.codex`) and every Cursor workspace with chat state (one each). `imported` is `import.sessions.total` (0 when the report has no session total). `total` is the larger of the two. `claude`, `codex`, `cursor` and `days_seen` are counted across all of them.
- `harness`: `primary` is the harness with the most sessions (null with none); `counts` covers `claude_code`, `codex` and `cursor` (Cursor counts workspaces with chat state). `action` opens HQ in that harness. Harness ids are hyphenated (`claude-code`, `codex`, `cursor`) in `harness.primary`, `harness.action.harness`, `top_projects[].harness` and `recent_work[].harness`. The underscore keys appear only inside `harness.counts`.
- `top_projects` (up to 5): working folders ranked by sessions, then newest activity. `top_repos` (up to 5): the git repos those folders sit in, with the newest commit time. `recent_work` (up to 5, newest first): session titles, at most 80 characters, with their project and harness. A title is the Claude Code custom title or summary, or the Codex thread name; the first prompt line is the last resort. The filter is safe by default: a title is never shown when it names a credential (password, passwd, passphrase, passcode, pwd, secret, token, api key, bearer, private key, access key, auth, credential, creds, key, pass, pin, otp, 2fa, mfa, pw, cred, and passwort, contraseña or mot de passe), sets a name that holds pass, key, pwd, pw, cred, secret, token, auth or pin (such as DBPASS=), holds a known API key prefix, a private-key header or a URL with a password, or holds a hex run of 24+ characters, a run of 16+ letters and digits mixed, or a base64/base62 run of 20+ that has a digit or capital letter. Full-width letters and accents are folded first. That session reads "Session in <project>". Session-row titles from the registry, lane and thread fields go through the same filter; a secret-looking thread title leaves the registry title in place. `top_projects[].path` starts with `~/` inside the home folder and is the folder name only outside it.
- `tree`: companies in this HQ, plus projects and knowledge files of the brief's own scope.
- `actions`: each is `{id, kind, label, reason, launch_prompt, primary}`. `kind` is one of `open_harness`, `connect_ai_apps`, `connect_integration`, `connect_company`, `import_history`, `open_tree`. `import_history` ("Bring in your past work") appears only when `import` is null: no report and no session other than the current one. `open_harness` adds `harness`; `connect_integration` adds `integration: {slug, name}`; `connect_ai_apps` has no `integration`. Exactly one action has `primary: true`: `connect_ai_apps` with zero sessions, else `import_history` when `import` is null, else `connect_company` when there is no company, else `open_harness`.
- `getting_started`: set only when there are zero sessions, or with the membership copy below.
- Company isolation: every session is counted, but names, paths and titles come only from the brief's own company (and the person brief's included companies). Each session's company comes from the scan row, then its HQ `meta.yaml` `company_slug`, then a folder under `companies/<slug>`; a folder under `companies/<slug>` is that company's even when the session is recorded as personal. A folder is named only when every one of its sessions resolves to an included company. A session inside HQ with no record of its company (the HQ root, `repos/`, worktrees) is counted and never named, and so is a repo whose GitHub owner is another company's `github_org`.
- Reads are bounded: a 30-second inventory budget (sessions past it are still counted, without their project), at most 60 project folders checked, 5-second git reads within a 30-second git budget (past it, repos are not named), title reads within a 20-second budget (at most 1 MB from the start of a long transcript and 16 MB of the Codex thread index), and 20,000 tree entries. The whole welcome step stays well under 3 minutes.
- `next_steps` holds `connect_company` (no company), `import` (only when `import` is null), and `connect_integration` and `sync` (company briefs).
- On failure, `welcome` is `{first_run, note}` with one plain `note` ("Couldn't read welcome history.") and the rest of the brief is unaffected. A partly read inventory, or a failed title or tree read, adds a plain `note` and leaves that part out. Exception text never appears in `welcome`; it goes to stderr.

#### Import report contract

Agreed between Core and Desktop on 2026-10-19.

- Writer: Desktop. At the end of the tree step, the desktop writes `<hq>/workspace/imports/<YYYY-MM-DDTHH-MM-SS>/report.json` atomically from the scan's done summary. Later, `hq import scan --output <path>` can take over the write with the same shape. `/import-context` keeps writing `<hq>/workspace/imports/<YYYYMMDDTHHMMSSZ>/report.json`. Both folder names are UTC times. A second import in the same second adds `-2`, `-3`, ... to the folder name. The reader parses both formats into UTC times, sorts by time and then by the numeric suffix (the base name counts as 1), and skips folders that match neither format.
- Fields: the existing `{scan_id, counts{the 12 keys}, categories, discovery{ok, errors}}`, plus `sessions{total, claude, codex, cursor, days_seen, first_at, last_at}`, `tools[]` (harnesses found), `projects[]` (top project names, never paths), `source: "desktop-tree-step"` and `written_at`.
- Reader limits: a `report.json` over 1 MB, nested deeper than 32 levels, not UTF-8 or not a JSON object is skipped and the next newest report is tried. A symlinked `imports` folder, stamp folder or `report.json` is not followed. Reading never fails the brief: with no usable report, direct detection applies.
- Reader: prefer `sessions.total`. An older report has no `sessions` block; its total is the sum of `categories.conversations[].sessions`. `counts.conversations` counts session stores and is never used as a session count. Missing fields are tolerated.
- Transcripts stay where the harness wrote them. With no report, direct detection uses the machine inventory.
- Once a report exists or any session other than the current one is found, the welcome edition never shows "Bring in your past work". Project names shown in the brief still go through the title filter and company isolation.

Keep one welcome block at the root of a person brief; never duplicate it in company or personal sections. Suggest connecting a company only when membership lookup confirms zero companies. A failed lookup still shows the getting-started copy with one plain source error line. A failed company pass leaves a plain error in its own section and does not stop other passes. Status progress updates after each pass. History reads open at most the newest 14 candidate run files.

For zero memberships or a failed membership lookup, include this getting-started copy verbatim: "HQ brings your work, shared context and AI tools together. Start with a personal task, then create or join a company with /onboard when you are ready."

## Step 4. Synthesize brief.json

First start housekeeping in the background (Step 5's command), so it runs while you write. Then turn `brief-data.json` and the prefs into these items. The reader is the person the brief is for, who may not be a developer. Every list holds **at most 5 items**, and only things that truly need them.

For `mode: person`, apply the synthesis below separately to `personal` and each `companies.<slug>` section. Preserve those sections in `brief.json`, copy `not_included`, and keep every item’s company. Run `brief_rank.py --check` on the aggregate; inspect every section report and require no `isolation_problems` and no `welcome_problems`. Company PRs remain in their company sections, rather than being dropped from the person brief. Use only the previous person run for carry-over, matching both company and item identity. Record `mode: person` in the ready index entry.

### Status while writing

The writing step must never go quiet. Before each section, append an activity entry to `status.json` and move `progress`, so the app never goes more than about 30 seconds without a new entry. Use these labels and progress values, in order:

| Activity label | progress |
|---|---|
| Writing decisions | 0.72 |
| Writing what shipped | 0.78 |
| Writing problems | 0.83 |
| Writing meetings | 0.87 |
| Writing priorities | 0.91 |
| Housekeeping | 0.95 |

Mark the previous entry `done` with a plain detail ("4 decisions") when the next one starts. If a section takes longer than 30 seconds, update its `detail` ("3 of 5 written"). The Housekeeping entry is the one `housekeeping.py` writes; if it has not finished, add the entry yourself as `running` and let the script complete it. Read the clock in the same command that writes each entry.

### Item fields

Every item carries `id` (short and unique within the brief, like `d1`, `p2`, `m3`), `title`, `why`, `company` (the slug, or null on a personal brief), `product` (the human name, see Product names), `source` (where it came from), and `origin: {repo, number, url}` when it comes from GitHub. Actionable items also carry `unlocks[]`, `people_waiting` (a count), `revenue` (true when money waits on it), `effort` (`quick`, `medium` or `large`), `risk`, `age_hours` and `prompt`. The app shows the company logo and the `product` label, never a repo chip.

`age_hours` is always computed from a timestamp in `brief-data.json`, never estimated: the meeting start, the PR `created`, the earliest matching DM `at`, or the `since` of a red workflow (the first prior run that listed it red). `source` is required on decisions and incidents: `meeting_signals`, `dms`, `main_health`, `prs` or `fleet`. The app folds the sweep's own red-main risk into the decision or incident with `source: main_health` on the same repo or product, so write exactly one item per red repo.

`action` is required on every decision and names the kind of call, which decides the button the app shows and how the picker treats it:

| `action` | When |
|---|---|
| `cut` | Drop or hold work: cut a change from a release, stop a project, skip a run. A `cut` with `source: prs` is the release call, so the Release train card yields to Needs you. |
| `go` | Approve something ready: merge, ship, deploy, sign off, say yes. |
| `decide` | Pick between options; carries `choices: [a, b]`. |
| `reply` | Answer a person: a DM, a question from a meeting, an email. |
| `prep` | Get something ready before a call or a deadline: read, draft, review. |

The app defaults a missing or unknown `action` to `decide`; `brief_rank.py --check` reports it under `field_problems` so it never ships that way.

### Root fields

- `today`: `YYYY-MM-DD` local, copied from `brief-data.json.window.today`. The app's only weekday source; never derive it from `generated_at`.
- `prefs_applied.widgets`: `{pinned: [kind], muted: [kind], weights: {kind: -2..2}, density: auto|calm|full}` copied from `brief-prefs.yaml` (`pinned_widgets`, `muted_widgets`, `widget_weights`, `density`). `sunrise`, `needs` and `catchup` may not be muted: drop the entry and add one `learned_notes` line saying so. Clamp weights to -2..2 with a note. `brief_rank.apply_widget_prefs` does both.
- `mode`: `company` or `personal`, copied from `brief-data.json.mode`. Write `mode` and `company` on the run's `index.jsonl` line too.
- `welcome`: copied from `brief-data.json.welcome` when it is set; omit it or write null otherwise. The writer may shorten each `next_steps[].reason` but adds no new steps. On a first run where `welcome.sessions.total` is above 0, the brief writes no empty-state lines anywhere: no "Nothing owed", "No sessions", "Nothing needs a call from you today" or similar. Lead with the person's own work from `headline`, `top_projects` and `recent_work`, and turn quiet lists into the `actions` (primary first). The first brief has no technical sentences.
- `week`: `[{date, sessions, meetings, merged, opened, beat?}]`, the last 7 local days of the active company (or of the person's own work on a personal brief), copied from `brief-data.json.days` (that is what `--days 7` is for). `beat` is optional: `{kind: turn|crisis|resolution|push, label, evidence}` where `crisis` is the day an incident opened, `resolution` the day something in `items.recovered` recovered, `push` the day with the most merges, and `turn` the event that led into the crisis. One beat per day at most.
- `landed_days`: `[YYYY-MM-DD]` days in `week` with at least one merged PR or release.
- `time_to_clear_min`: the sum over decisions of effort minutes (`quick` 2, `medium` 6, `large` 15).

### Titles and why

These rules apply to decisions, incidents (problems), watch, waiting and priorities.

- `title` is the ask in plain English, the way a person would say it. Verb first, 8 words or fewer. No repo names, PR numbers, conventional-commit prefixes (`feat(...)`, `fix:`), file paths, flags or code. Good: "Approve the desktop 0.11.3 release", "Decide: can cloud placeholders ever count as deletes?", "Unblock Jamie's billing dashboard", "Fix the red release gate on staging". Bad: "web-api #919: feat(sync): cloud-only placeholders".
- The repo, PR number and URL go in `origin`, and may be named in `why` or the prompt, never in the title.
- `why` is one plain sentence a non-engineer understands: what it is, who is waiting, and what happens if it waits.
- Shipped groups use product names too: "Desktop app: 17 changes shipped", not "desktop-app: 17 merged".

### Product names

Use human product names everywhere instead of repo slugs. They come from data files, never from the skill itself:

- `companies/<company>/settings/brief-products.json`, read on a company brief only.
- `workspace/brief/products.json`, the person's own names. It wins when both files name the same repo.

Each file is a JSON object of repo slug to product name, for example `{"web-app": "Web app", "billing-api": "Billing"}`. A file that is missing or does not parse is ignored. An unknown repo becomes its slug in plain words ("some-new-repo" becomes "Some new repo"). `scripts/brief_rank.py` (`load_product_names`) reads the files, and each PR row in `brief-data.json` already carries `product`.

### Lists

- **decisions:** only these four kinds:
  - (a) DMs from humans (not `agt_` senders) asking the user something;
  - (b) PRs where the user is the author (`authored_by_me`) or an explicitly requested reviewer (`review_requested`), or whose title starts with Release (`is_release`), or that block a release. A PR they did not author and were not asked to review is never a decision on other grounds;
  - (c) red main-branch workflows (`main_health[*].red`);
  - (d) meeting action items and questions assigned to the user (`mine: true` in `meeting_signals[*].action_items`).
  Rank by what each one unblocks (`people_waiting`, `unlocks`, `revenue`), then by age. Keep the top 5. Everything else goes to **shipped**, **incidents** or **watch**.
  Each decision also carries:
  - `blocks`: `[{who, what, kind: person|work, origin?}]`, the people and work waiting on the call: DM askers, action-item owners waiting on it, "held until" items, PR authors awaiting the user's review. Names only inside the locked company. Without named blocks the app says "unlocks N things", never "people", so leave `blocks` empty rather than guess.
  - `action`: one of `cut`, `go`, `decide`, `reply`, `prep` (see Item fields). Required.
  - `choices`: `[a, b]` when `action` is `decide`, two words each ("Ship Monday", "Hold a week").
- **waiting:** things the user asked for that have no answer yet, and the user's PRs waiting on review. At most 5. Each row is a person and a thing: `who` (the first name, or the agent's name) and `what` (what you wait for, plain: "to review the pricing page", "an answer on the memo folder"), plus `age_hours`, `kind` (`dm`, `review`, `handoff` or `other`) and `origin`. The app reads `title` as `what` when `what` is missing but drops a row with no `who`, so a wait with nobody to name is not a wait; `brief_rank.py --check` reports a row missing `who` or `what` under `field_problems`. `what` follows the title rules (no repo names, PR numbers or prefixes).
- **shipped:** merged PRs grouped by product and theme, plus releases and deploys. Mark firsts. Counts come from `prs_summary` (see Counts). Each row carries `id` (`s1..`), `product`, up to 5 `highlights` (plain lines, no PR numbers or commit prefixes, one per change or theme) and `merge_hours_median` for the rollup (copy `prs_summary.by_product[].median_merge_hours`). The app merges rollup rows onto the sweep's per-product counts by `product`, so rollup titles use the product name exactly.
- **incidents** (the app calls them problems): red main branches, agents that are not active, risk signals, and outages named in sessions. At most 5. A missing or empty `workspace/brief/` with a sibling `workspace/brief-backup-*` folder is a deliberate reset and never an incident (Step 2).
- **watch:** open PRs and threads worth knowing about that do not need the user yet. At most 5. Each carries `kind` (`ci`, `pr`, `thread` or `fleet`) and an optional `prompt`.
- **people:** the latest work-level status for each teammate, with agents labeled. Use a summary, never the message text, unless the item is marked very important. Each carries `uid` (`prs_` or `agt_`), `load` (`clear`, `steady`, `heavy` or `storm`: `storm` owns an incident or a red main, `heavy` has 3+ meetings or 2+ open asks), `owes` (plain action items they own, from meeting signals and DMs) and `thanks` (one plain line about a win, or null).
- **meetings:** only meetings whose start is inside the window (`brief-data.json.meetings[]` is already filtered to `window.attended_meetings_from..sessions_to`, deduped, and marked `attended`); a catch-up brief widens that to the gap. Each meeting item carries:
  - `attended` (copied), `duration_min` (copied), `with`: the other participants in plain words ("Robin Bell", "Alex and Jamie");
  - `decided`: up to 3 lines from `meeting_signals[*].decisions[*].text`, each shortened to one plain line;
  - `todo`: up to 3 `{text, owner, mine}` from `action_items`, the user's own first.
  The app's meeting hover shows the title, the decided lines and the to-do lines (the user's own marked), nothing else. Every action item with `mine: true` is also a decision candidate under (d), with a launch prompt, even when the meeting itself is older than the window.
- **carry:** open items from the last brief that are still open. Each carries `carried_from` (the last run id), `carried_since` (the `created_at` of the first run that listed it, from `index.jsonl`), `briefs` (consecutive runs it has appeared in, chained through `origin.url` or `origin.number`, else the normalized title, using the last brief's own `carry` rows), `item_id` (today's decision or incident that continues it, or null) and `prompt`.
- **handoffs** (new): `{id: h1.., object, from, to, me, production, since, receipts: {access, ack, active}, note, company, product, origin, prompt}`. From DM ownership verbs (owns, handed, took over, needs to acknowledge), `/delegate` events and board assignee changes. `me` is true when the user is the receiver; `production` when the object is live. Each receipt is `true`, `false` or `null` (unknown); `access` stays null unless a grants source exists. `note` is work-level, never message text. `object` follows the title rules.
- **recovered** (new): `{id: f1.., title, what, at, source: main_health|fleet|session, company, product, origin, timeline?: [{at, text}], post_incident?: {broke, did, changes}}`. From `brief-data.json.main_health[*].delta.recovered`, `fleet.delta.recovered`, and outages a session names as closed. `at` is the run's `generated_at` when nothing more precise exists.
- **releases** (new): `{product, version, released_at, pending: [{day, count, theme}], pending_count, held: [{title, why}], light: ok|warn|red, prompt, origin}`. Copy `brief-data.json.releases[]` (`merged_at` → `released_at`, `pending_by_day` → `pending`); `held` lists decisions whose `why` says the work is held until the release; `light` is `red` when the repo's main is red, `warn` when `pending_count` is 3 or more or the release is older than a day, else `ok`.
- **reminders** (new): `{id: r1.., text, said_at, where, due_at, prompt}`. From `hq dm` reminders the user sent to themselves; later from "remind me" lines once outbound DM history is in the sweep. `text` is the user's own words, verbatim, and is exempt from the title lint.
- **other_company:** a count only.

### Counts

The brief's merged and opened numbers come from `brief-data.json.prs_summary` (`merged`, `opened`, `open`): the 24-hour window (`window.hours`), the user's own PRs. The loader shows the same numbers. Never add up `days` for these: the `days` rollup buckets by local date and is only for the week arc.

### Priorities

`priorities` is an ordered list of at most 5 one-line directives for the day:

```json
"priorities":[{"rank":1,"text":"Give Alex a go/no-go on desktop 0.11.3","item_id":"d2","because":"the release waits on the answer","score":3}]
```

- Derive them strictly from decisions and incidents already in the brief. Add no new facts.
- Rank by how many people or how much revenue each unblocks, then by age, then by effort. A quick win goes last unless it unblocks someone. `brief_rank.py --check` returns this order from the item fields; follow it unless you can state the reason in `because`.
- `item_id` must be the id of an item in `items.decisions`, `items.incidents`, `items.handoffs` or `items.carry`. `--check` reports a dangling id under `dangling_priorities`; fix it or drop the priority.
- `score` is the unblock score `--check` prints under `scores` for that `item_id` (people waiting + things unlocked, revenue counts double). Copy it; `priority_problems` reports a missing or different value.
- `text` follows the title rules. `because` is one clause.
- `lead_hint` starts with priority 1's `text` verbatim, then one clause: "Sign the renewal contract first; the vendor and the launch date wait on it." The hero quotes it, so the first clause must match exactly (`--check` reports `lead_hint_problem` otherwise).

#### How the app uses priorities

Each priority pulls the card that contains its item onto the grid (the decisions card for a decision, the problems card for an incident, the handoffs or carry card for those), and the card's reason sentence quotes the priority's `text` in the writer's words: "Shown for priority 1, "Sign the renewal contract": it and 4 more calls wait on you." So `text` must be the exact directive, not a summary, and `because` one clause that reads after it. The needs rows are ordered by priority rank first, then by what they unblock, so the ranks are the order the user sees.

### Prompts

Every actionable item gets a `prompt` that starts a Claude, Codex or Grok session. The prompt must:
- name the exact repo, PR, commit or person
- say what to check first
- say what done looks like
- end by showing the result before anything irreversible

Use the user's `engine` preference as the default. Then apply the preferences: boost VIP people and repos, drop muted items, and treat `density` as a ceiling (never above 5 per list).

### Write and check

Write `brief.json` as `{run_id, generated_at, today, mode, company, window, catch_up, lead_hint, priorities, counts, week, landed_days, time_to_clear_min, items, prefs_applied, learned_notes, welcome}`, where `company` copies `brief-data.json.company` (null on a personal brief), `counts` copies `prs_summary` and `prefs_applied` holds `density`, `engine`, `vip_people`, `muted` and `widgets`. Then run:

```bash
python3 -I .claude/skills/daily-brief/scripts/brief_rank.py --check workspace/brief/<run_id>/brief.json
```

Fix every `title_problems` entry (it now covers `shipped[].title`, `shipped[].highlights`, `handoffs[].object`, `recovered[].title`, `releases[].held[].title` and `waiting[].what`; reminders are exempt), every `field_problems` entry (a decision without a valid `action`, a wait without `who` or `what`), every `over_cap` list, every `dangling_priorities` and `priority_problems` entry, `lead_hint_problem`, `widget_problems`, `today_problem` and `welcome_problems` (empty-state lines on a first run with sessions, or exception text in `welcome`), and write the file again. Write status `step: "Writing your brief"`, `progress: 0.9`.

## Step 5. Housekeeping

Housekeeping runs every time, through one script. Start it in the background at the beginning of Step 4 so it runs while you write; it never blocks `brief.json`. Do not run the checks by hand, and do not skip the script.

```bash
python3 -I .claude/skills/daily-brief/scripts/housekeeping.py \
  --company <company> --hq-root "$PWD" --run-dir workspace/brief/<run_id>
```

In person mode, run housekeeping separately for personal and each included company, writing into separate temporary run directories and copying each result into its matching section. This keeps company worktree paths within their own section. Never run company housekeeping for an excluded company. On an explicit personal brief, leave `--company` off. The doctor and sync checks need a company, so the script records both as `skipped` with the reason `needs a company` and runs only the worktree scan.

The script runs the every-run checks in parallel, each under a hard time budget, with stdin closed and every prompt pre-answered:

| Check | Command | Budget |
|---|---|---|
| `hq_doctor` | `hq doctor --json --company <company>`. Exit 1 only means some checks fail; the run still counts as finished | 40s |
| `hq_sync` | `hq sync now --company <company> --on-conflict abort --lock-timeout 0`. Never prompts, never overwrites, never waits on the HQ Sync app's lock | 30s |
| `worktree_scan` | read-only `git status` and `git log -1` in each `workspace/worktrees` checkout | 20s |

A check that reaches its budget is stopped (SIGTERM, then SIGKILL) and recorded as skipped. Every task ends with exactly one status: `ran clean`, `found N things`, `skipped (took too long)` or `failed: <reason>`. The script writes `housekeeping.json` (`tasks`, `notes`, `headline`, `proposals`) and `status.json.housekeeping`, completes the "Housekeeping" activity entry, and never prints command output or secrets. Use its `headline` as the Housekeeping card's line, unchanged. Never write "did not finish" or "not run" for a check the script reported otherwise.

The script also adds the deliberate-reset note when it applies ("Brief history was reset on purpose; the old briefs are backed up in workspace/brief-backup-…"). That one line in `notes` is the only place a reset appears.

**Optional checks.** Only when time allows, each recorded in `tasks` with one of the four statuses: search reindex (`qmd update`) when content changed since the last brief; `/garden` audit-only, weekly; stale-session scan (working state, no `/handoff`, older than 24h); orphan-process scan (HQ-related processes with no live parent, ranked by memory); error harvest (repeated failures in HQ logs and hook errors since the last brief). The error harvest ignores a missing or reset `workspace/brief/` when a `workspace/brief-backup-*` folder sits next to it.

Housekeeping never deletes files, kills processes, removes worktrees or files bugs.

**Proposals.** Anything destructive or outward-facing becomes an item in `housekeeping.json.proposals` with a launch prompt. Add proposals to the file the script wrote and keep its `tasks`, `notes` and `headline`. The brief shows these on a Housekeeping card, and the user starts each one:
- Hand off and archive stale sessions.
- Quit orphan processes. List the PID, command, memory and why each looks orphaned. Never include the user's own apps or HQ.app.
- Remove idle worktrees listed in `tasks.worktree_scan.detail.stale_paths`, after confirming each is merged and has no unpushed commits.
- File one bug per distinct repeated error through `/hq-bug`, with the log excerpt.
- Apply garden fixes.

Each proposal states, in plain words, what it frees or fixes and its risk.

## Step 6. Finish

- Write status `state: ready`, `progress: 1.0`, as soon as `brief.json` is written. Housekeeping updates `status.json.housekeeping` afterwards without changing `state`.
- Append the run to `workspace/brief/index.jsonl`.
- Print one line: `BRIEF READY <run_id> <path to brief.json>`. The desktop app watches `status.json` and shows the notification.
- When run outside the app, also send the user a short HQ DM to themselves: "Your daily brief is ready."

If any step fails, write `state: failed` with a plain-language `error` and stop. Partial files are fine, because the app shows what it has and marks what is missing.

## Learning, weekly

When `brief-log.jsonl` has 7 or more days since the last fold, fold it into `brief-prefs.yaml`:
- If a widget is dismissed 3 or more times in a row, `widget_weights[kind] -= 1` (floor -2).
- If sessions are launched from one widget 3 or more times in a week, `widget_weights[kind] += 1` (ceiling +2).
- If the user says "always show X", add the kind to `pinned_widgets`; "never show X" adds it to `muted_widgets`.
- Refuse to mute `sunrise`, `needs`, `catchup` or the priorities list: leave the prefs unchanged and add a `learned_notes` line saying why.
- If an engine is chosen 70% of the time or more, make it the default.
- If a sender's items are always launched, mark them VIP.

Add each change as one plain line to `learned_notes`, so the next brief can say what changed.

The app appends to `brief-log.jsonl` through a host command that writes only that file (`append_brief_log_line`, HQ Desktop 0.11.7 and later). One JSON object per line, keys in this order: `at` (ISO time), `event`, `run_id` (the run folder name, or null for a brief with no run), then only the fields the event carries: `kind` (the widget kind from the catalogue), `item_id`, `engine` (`claude`, `codex` or `grok`), `widgets` (a list of kinds). Events: `shown` once per run with `widgets` (the cards on the page); `dismiss` when the person cleared an item without a launch (`item_id`, `kind`); `launch` when a prompt started a session or was copied (`item_id`, `kind`, `engine`); `pin` and `hide` with `kind`. Decisions and action items log as `needs`; a prompt the catalogue does not know (a peek's resume, a thank-you) logs with `kind: null`. Skip a line that does not parse. Older desktop builds wrote nothing, so a short log is normal. The writer itself never writes `brief-log.jsonl` or the app's plan files.

## Rules

- **Company isolation.** In person mode, synthesize each `companies.<slug>` section separately and keep every item’s `company` slug. Personal rows use `company: null`. Drop any brief item whose existing company conflicts with its section and record an isolation error; never relabel a conflicting row. Tag only brief-item collections, leaving nested participant and metadata rows intact. Never move content between company headings. Excluded companies get only the exclusion notice. Explicit narrow modes retain their existing count-only treatment of other companies.
- **At most 5 per list.** Decisions, waiting, incidents, watch, priorities, carry, handoffs, recovered, releases and reminders never hold more than 5 items; the app shows "+N more" past that, never a sixth row.
- **Plain titles.** Titles follow Step 4: verb first, 8 words or fewer, product names, no repo slugs or PR numbers. The same rule covers shipped titles and highlights, handoff objects, recovered titles and held release items. Reminders are the user's own words and are exempt.
- **Unmutable widgets.** `sunrise`, `needs` and `catchup` are never written into `prefs_applied.widgets.muted`, whatever `brief-prefs.yaml` says; drop the entry with a `learned_notes` line.
- **No app files.** The writer never writes `brief-log.jsonl` or the app's plan files; it reads the log and writes `brief-prefs.yaml` only in the weekly fold.
- **Retention.** Use product usage only. Never use payments.
- **Secrets.** Never read or print secrets.
- **Read-only, except housekeeping.** Do not post, send, merge, deploy or change anything outside `workspace/brief/` and `personal/brief/`. The only exceptions are the Step 5 auto-run tasks. Destructive cleanup is always a proposal the user launches.

## Default brief-prefs.yaml

```yaml
version: 1
last_brief_at: null
density: auto            # auto | calm | full. full keeps the same 8-card ceiling as auto.
engine: claude           # claude | codex | grok
quiet_hours: "20:00-07:00"
vip_people: []
vip_repos: []
muted_repos: []
muted_senders: []
integrations: []         # extra connected apps to always check
# Widget preferences the app's picker reads (copied into brief.json prefs_applied.widgets).
# Kinds: oneThing blockedByMe incident fleetRecovery resolved risk waiting carry handoffs
# shipped firsts releaseTrain meetings decided weekArc team agenda runway focus reminders.
pinned_widgets: []       # "always show X": shown whenever it has data, below the cards a priority needs
muted_widgets: []        # "never show X": left off the grid. sunrise, catchup and needs cannot be muted
widget_weights: {}       # kind: -2..2 whole numbers; each point moves the card five score points
learned_notes: []
```

`density: full` keeps the same 8-card ceiling as `auto` (the larger templates are not shipped); `calm` lowers it.
