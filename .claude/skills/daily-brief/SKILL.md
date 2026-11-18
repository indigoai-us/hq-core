---
name: daily-brief
description: Build the user's Daily Brief across personal work and every permitted company. Reads the last brief and the user's brief preferences, sweeps sessions, PRs, CI and DMs (plus synced signals, meeting signals and fleet when a company is bound), writes brief-data.json and brief.json with a launch prompt for every action, and reports status so the desktop app can notify the user. The person's first ready brief adds a welcome edition. Run by the main local bot when the user presses Create brief, or on a schedule.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash
---

# /daily-brief

Builds one person's Daily Brief across personal work and every permitted company by default. The HQ desktop app starts this through the main local bot when the user presses **Create brief**. A person can also run it directly with `/daily-brief [--all|company|--personal] [--welcome] [--today YYYY-MM-DD]`.

An explicit personal brief (`--personal`) reads only what belongs to the person on this machine and in GitHub: work sessions, PRs, main-branch CI and personal DM messages (messages with no company). The company-only sources (meetings, synced signals, meeting signals, fleet agents and integrations) are skipped and recorded as skipped, and housekeeping skips the doctor and sync checks. A new user with no company gets a useful first brief this way.

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
| `brief.json` | Step 4 | Synthesized items with prompts, read by the generator, plus the optional `page` the card design draws (Step 4b) |
| `page-draft.json` | Step 4b | The page frame and card candidates from `brief_page.py skeleton`; a working file, not read by the app |
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

Write `status.json` before each step, and again after every source, so the app's progress bar stays truthful and keeps moving. Also keep a rolling `activity` list in `status.json`, newest last, capped at 12 entries. The app shows it under the sunrise so the user can see the run is alive:

```json
"activity":[{"at":"…","label":"Read 42 of 50 sessions","state":"done","detail":"only counted: 6 agent runs, 2 outside this brief"},{"at":"…","label":"Checking GitHub PRs","state":"running"}]
```

As each source lands, also update `findings` and `samples` in `status.json`. The app animates these as live counters and preview cards:

```json
"findings":{"signals":{"decision":0,"action_item":0,"risk":0,"commitment":0,"key_point":0},"sessions":0,"meetings":0,"dms":{"total":0,"need_you":0},"prs":{"merged":0,"opened":0,"open":0,"review_requested":0},"ci_red":0,"agents":{"total":0,"attention":0},"integrations":{}},
"samples":[{"kind":"decision","title":"Approve release-gate fix","company":"acme","at":"…"}]
```

`samples` holds at most 8 items, all from the active company only (`company` is null on a personal brief). Titles are short and plain. Never include DM body text: use the sender name and a summary instead.

`state` is `running`, `done`, `skipped` or `failed`. Labels are plain, user-facing language with real counts ("Found 31 DMs, 4 need you"), never commands or file paths. For other-company items, give counts only. Spread progress evenly across the sweep (0.25 → 0.7) by source. Read every timestamp from the clock in the same command that writes it.

## Step 0. Signals gate

When a morning job runs the signals engine on this computer, the brief waits for today's local signals run to complete for every in-scope company, up to the wait limit. A signals run that fails, or a wait that ends without fresh signals, never costs the brief: the brief still builds from every other source, with a stale-signals notice at the top and a "Try now" action (item 3). The bot's engine job is behind the hq-cli flag `cli.bot-signals-engine-job`, which is off by default. With it off, the bot's morning hot-signal-sync job runs the hot-channel sync only and writes no run record, so the gate answers `off` and the brief builds as before without starting a run.

First, unless this is an explicit `--personal` brief, ask whether the engine runs here, before reading any company. This call reads only. The one exception: when the engine is off and today's `brief-gate.json` is left in another state from earlier in the day (the engine was on, then turned off), it replaces that file once with an `off` gate (keeping the company list and retry times), so the desktop does not show "Waiting for signals" next to a finished brief. A `running` or `waiting` file checked in the last 5 minutes is left alone, since another session may still be polling it. With no file, or a file already `off`, it writes nothing:

```bash
python3 -I .claude/skills/daily-brief/scripts/brief_gate.py engine --hq-root "$PWD" --today <today>
```

When it prints `"on": false`, exits 4, or prints anything that is not JSON with an `on` field, go straight to Step 1: the brief builds as before. Only `"on": true` continues below.

In-scope companies are the companies this brief covers whose knowledge prefs have `signals_capture` or `ontology_capture` on (read with `core/scripts/knowledge-prefs.sh`). Step 0 runs before Step 1, so build the membership inventory here the way Step 1 describes it: the read-only `hq daemon sync mode list` table intersected with `bash core/scripts/hq-session.sh get company_slugs` (narrowed to the one company for `--company <slug>`). Step 1 reuses that inventory. When the inventory cannot be read, pass no `--companies` and the gate falls back to today's `summary.json`, then to the companies of the last gate written today (an error pass keeps that list), then to the companies with a record in today's run folder. When the inventory has no in-scope company, or the brief is an explicit `--personal` brief, skip this step. `<today>` is the local calendar date (not the UTC date), the same date `hq signals run` uses for its run folder. Pass company slugs only: a `--companies` value with a path part exits 4.

1. Check the gate:

   ```bash
   python3 -I .claude/skills/daily-brief/scripts/brief_gate.py check \
     --hq-root "$PWD" --today <today> --companies <slug,slug>
   ```

   The script reads `workspace/signals/runs/<today>/{company}.json` and `{company}.lock` (and `summary.json` when `--companies` is empty), writes `workspace/signals/runs/<today>/brief-gate.json` and prints the same JSON. A company is ready when its record has `status: complete`, `status: partial` with any `partialReason` other than `late-start` (when the adapters or extract step failed, only while the extract step still finished: the engine keeps going after a failed step, so signals are fresh for every source that synced, and the failure is listed in `brief-gate.json.warnings`; when extract did not finish, the company counts as failed), or `status: skipped` with any `skipReason` other than `late-start`. A record that holds only an incremental pass (no garden or adapters step) is ready only when it carries `jobRanAt`. A live `{company}.lock` means a run is going, whatever the record says. The exit code says what to do next:

   | Exit | `state` | Meaning | Do |
   |---|---|---|---|
   | 0 | `ready` | every in-scope company is ready | go to Step 1 |
   | 0 | `off` | no morning job runs the signals engine here | go to Step 1; do not start a run |
   | 1 | `waiting` | no record, a stale lock, a late-start or incremental-only record, or a retry time that has come (this check reads the retry time and does not use it) | wait with a run (2 below) |
   | 2 | `failed` | a run failed and its retry time has not come, it needs the person (`retry: manual`), or an earlier wait timed out on a run that still holds its lock | build with stale signals (3 below) |
   | 3 | `running` | a run holds the company lock | wait (2 below) |
   | 4 | `error` | the gate itself failed | go to Step 1 and build as before, as with `off` |

   The gate fails open. Any exit not in this table, or output that is not gate JSON with a `state`, counts as exit 4: build the brief as before. You add no stale-signals notice, because the gate could not tell whether signals are stale; the sweep writes one only when today's `brief-gate.json` carries one for the company. When the brief builds with `brief-gate.json.warnings` set, write each warning once near the top in one plain sentence (for example "Slack needs to be reconnected, so today's signals leave it out.").

   The gate counts the engine as on when `HQ_FLAG_CLI_BOT_SIGNALS_ENGINE_JOB` is `true` or `1` in the environment, or, when that variable is unset, when today's run folder holds a record or lock from a `--trigger job` run, or yesterday's does and today's job time (yesterday's job time plus 2 hours) has not passed. So after the flag is turned off, the gate turns off once the morning job time passes without a job record. `false` or `0` turns it off at once. A run started by the brief or from chat does not turn it on. `brief-gate.json.engine` says which (`{"on": false, "source": "no-job-record"}`).
2. On exit 1 or 3, write `status.json` with `state: running` and `step: "Waiting for signals"`, then:

   ```bash
   python3 -I .claude/skills/daily-brief/scripts/brief_gate.py check \
     --hq-root "$PWD" --today <today> --companies <slug,slug> --start-run --max-seconds 90
   ```

   Each call returns within about 90 seconds, below a 2-minute command timeout, so do not raise the timeout or run it in the background; the wait limit holds across calls. The exit code of this call says what to do next:

   | Exit | `state` | Meaning | Do |
   |---|---|---|---|
   | 0 | `ready` or `off` | signals are ready, or the engine was turned off | go to Step 1 |
   | 1 | `waiting` | an earlier call's run ended and a company still has no usable record | run this item's command once more; a second exit 1 in a row goes to 3 |
   | 2 | `failed` | the run failed, wrote no usable record, could not be started, or the wait timed out | build with stale signals (3 below) |
   | 3 | `running` | the run is still going | run the same command again |
   | 4 | `error` | the gate itself failed | go to Step 1 and build as before |

   The wait call fails open like the check in item 1. Exit 4, any other exit (for example 127 when `python3` is missing, or a command the timeout killed), or output that is not gate JSON with a `state`, means go to Step 1 and build the brief as before; you add no notice, and the sweep writes one only when today's `brief-gate.json` carries one for the company. Only exit 2, or a second exit 1 in a row, goes to 3.

   `--start-run` starts `hq signals run --trigger brief --json --company <slug>` in the background for each company that is `waiting` (with no `--companies`, one run for every company), only when the gate is `waiting` and at most once; when a run already holds the lock, or an earlier call's run is still going, it only waits. Each start writes its output to a new file pair under `brief-runs/` in the run folder, listed in `brief-gate.json.runOutput`. The script polls every 15 seconds and keeps `brief-gate.json` current (`state: running` with `currentStep`, `runPids` and `waitStartedAt`). The wait is limited to `briefWaitMinutes` from `core/settings/signals.yaml` (default 20), counted from `waitStartedAt`, the first call that saw the run going. A wait nobody polled for 5 minutes, or one whose runs have all ended with no lock held, starts fresh on the next call. It returns as soon as the state is `ready` or `failed`. A run still going at the limit is left running and the gate is written as `failed` with reason `timed out after 20 minutes`. While that same run still holds its lock, later calls (item 1 and this one) answer `failed` at once instead of waiting another 20 minutes, so a hung run costs one wait and not one per pass; when the run finishes the gate reads its record, and when its lock goes stale (3 hours) the gate asks for a new run. A run that ends with no usable record, exits 2 (usage or config error), or cannot be started is written as `failed` with a retry time. Never run `hq signals run` yourself in this step: the script starts each company's run at most once per call.
3. On exit 2 from item 1 or item 2, or a second exit 1 in a row from item 2: build the brief with stale signals. Start no run and wait no longer: go to Step 1 and build the brief from every other source. No other exit comes here: a gate error always builds the brief as before, and you add no notice.

   The gate JSON of that last call (also in `brief-gate.json`) carries the notice as data in `signals_stale`, and `action` is `build-stale` on exit 2 (`start-run` on a second exit 1; the notice is there all the same):

   ```json
   {"code":"auth","reason":"today's signals run could not sign in to a connected account","detail":"acme: You are signed out of HQ.","last_good_run":{"date":"2026-10-30","finished_at":"2026-10-30T13:05:00Z"},"try_now":true,"retry":"manual","next_retry_at":null,"line":"Signals are stale: today's signals run could not sign in to a connected account. This brief uses signals from the last good run on Oct 30. Sign in again to clear it.","try_now_line":"Sign in again, then press Try now to re-run signals and rebuild the brief.","section_line":"From the last good signals run on Oct 30, not from today.","companies":{"acme":{"code":"auth","reason":"…","last_good_run":{"date":"2026-10-30","finished_at":"…"},"try_now":true,"line":"…","try_now_line":"…","section_line":"…"}}}
   ```

   | `code` | When |
   |---|---|
   | `auth`, `config` | the run failed with that `errorKind` and needs the person (`retry: manual`, `next_retry_at` null); the gate starts no run on its own, since a new run would fail the same way |
   | `run-failed` | the run failed, or its retry failed too; `next_retry_at` is the next automatic retry |
   | `start-failed` | the run could not be started, or refused to start (exit 2) |
   | `timed-out` | the wait reached `briefWaitMinutes` and the run is still going |
   | `no-record` | the run ended without a finished record |
   | `not-run` | the gate is still `waiting` (a second exit 1 in a row) |

   `last_good_run` is the newest earlier run folder, up to 30 days back, in which the company was ready and the extract step finished, so a skipped run is not a good run (null when there is none; with several companies the gate-level value is the oldest of theirs). `companies` holds the same fields for each company that has no fresh signals; a company that is ready today is not in it. `detail` is the gate's own `reason` and may name a company, so it stays in `brief-gate.json` and is not shown in a brief.

   Dates in the sentences are written the way a person reads them, by one helper (`brief_gate.human_date`): "Oct 30", with the year only when it is not this year's ("Oct 30, 2025"). The machine fields (`last_good_run.date`, `finished_at`) keep the ISO date; never show those to the reader, and never reformat a date yourself. `line` names no control, because the brief page has none for this: it says what is stale, since when, and, for `auth` and `config`, what clears it. `try_now_line` is the sentence that names "Try now"; it is used only in the closing reply, where that option is offered.

   You never write the notice yourself, and you never reword it. Code carries it the whole way: the gate keeps each company's notice in `brief-gate.json.staleCompanies`; Step 3's sweep writes that company's entry to `brief-data.json.signals_stale` (`companies.<slug>.signals_stale` in person mode); Step 4's `brief_page.py notice` writes `brief.json.signals_notices` and a page that shows it; and Step 4b's `brief_page.py attach` puts each stale company's notice card at the top of your page and labels the cards that come from that company's signals. A stale brief ships a valid page with the notice cards: when your page is missing or invalid, a page code builds from `brief-data.json` and validates takes its place (Step 4b covers the one exit where none can be built). Your only copy is the closing reply in Step 6, taken as given. When `brief-data.json` has no `signals_stale`, the brief has no notice.

   `brief-gate.json` is one file per day for every session on this computer. Every gate write keeps the `staleCompanies` entries of companies outside that call's scope, so a check for another company (whatever it answers) does not drop this company's notice; a company's entry changes only when a check judges that company again. An `off` gate has none.

   `brief-gate.json.nextRetryAt` is the retry time the desktop shows. The gate keeps that time in `brief-gate.json`. Item 1's check only reads it: at or after that time it exits 1 and leaves the time as it is, and item 2's call then starts one run for that retry and sets the next retry time 15 minutes on. So the first brief pass at or after the retry time starts the retry run, and nothing else runs the brief again at that time.

The stale reply. When the finished `brief.json.signals_notices` is not empty, the reply that ends the run (Step 6 says when) is one line per entry, in the list's order, then one `hq-block` fence, last and on one line. Each line is that entry's `line` followed by its `try_now_line`, both as given (`line` is the same sentence as the gate's `signals_stale.line` for that company), with the company's name and a colon in front when the brief covers more than one company, so no line reads as if it spoke for another company. The reply is the only place `try_now_line` is used: the reply offers "Try now", the brief page does not. `try_now` is true for every code today; if it is false on every entry, leave out the decision block:

````
<company name>: <that entry's line> <that entry's try_now_line>

```hq-block
{"v":1,"blocks":[{"kind":"callout","tone":"warning","title":"Signals are stale","body":"<each stale company's line, without try_now_line>"},{"kind":"keyValue","items":[{"key":"<company name>: last good signals run","value":"<the date as it reads in that entry's line, for example Oct 30>"},{"key":"Next retry","value":"<h:mm AM>"}]},{"kind":"decision","questionId":"signals-run-<today>-retry","question":"Re-run signals and rebuild the brief?","options":[{"id":"try-now","label":"Try now","recommended":true},{"id":"keep","label":"Keep this brief"}],"allowOther":false}]}
```
````

Write one "last good signals run" row per stale company and drop it for an entry whose `last_good_run` is null; its value is the short date from that entry's `line`, never the ISO date. "Next retry" is `brief-gate.json.nextRetryAt` in local time; drop the row when it is null (it is null for `retry: manual`). Nothing rebuilds the brief at that time by itself: the retry happens on the next brief pass or on "Try now". "Keep this brief" does nothing: the brief stays as built.

"Try now" re-runs signals and, when they come back ready, rebuilds the brief. It runs the same short-call wait as item 2, with `--retry-now`, which starts one run at once for each company the gate shows as `failed` (whatever its retry time) and no other. That includes a company whose run wrote no record, exited 2 or could not be started, and the no-company case, where it starts one run for every company. A `failed` company holding a `retry: manual` record is started too, since the person pressed "Try now" after fixing the cause. After a wait that timed out on a run still going, it waits for that run again. A company that is only waiting (no record yet) is not started by the `--retry-now` call itself; the item 2 command that follows an exit 1 starts it:

```bash
python3 -I .claude/skills/daily-brief/scripts/brief_gate.py check \
  --hq-root "$PWD" --today <today> --companies <slug,slug> --start-run --retry-now --max-seconds 90
```

Run the `--retry-now` command once. Every later call of this "Try now" is the item 2 command, without `--retry-now`: repeat it while it exits 3, and on exit 1 run it as item 2's table says. Then:

| Result | Do |
|---|---|
| exit 0 | rebuild the brief as a new run from Step 1. The gate now carries no `signals_stale`, so the sweep writes none and the rebuilt brief has no notice. When the state is `ready`, the sections Step 3 writes "only when Step 0 ended `ready`" are written |
| exit 2, or a second exit 1 in a row from the item 2 command | do not rebuild: the stale brief already built stays. Reply with the stale reply above, filled from this call's `signals_stale.companies` entries (the gate-level `signals_stale` when that is empty) |
| exit 4, any other exit, or output that is not gate JSON with a `state` | rebuild the brief as a new run from Step 1 as before; you add no notice |

Never run `hq signals run` in the foreground for "Try now".

## Step 1. Start

Write `status.json` with `state: running`, `step: "Checking your setup"` and `progress: 0.05`.

Check the session's company (`bash core/scripts/hq-session.sh current`). Never sweep a company the session is not locked to. The sweep reads the lock with `bash core/scripts/hq-session.sh get company_slugs` and refuses `--company` when that slug is outside the locked set.

- Default to a person brief (`--all`), including personal work and a section for each permitted company. `--company <slug>` and `--personal` remain explicit narrow modes.
- Membership inventory comes from the read-only `hq daemon sync mode list` table (the caller's memberships), intersected with `hq-session.sh get company_slugs`. Never widen the lock. Show every excluded membership as "not included: open HQ in that company to include it". Inventory/lock failures are visible source failures, never an invented empty membership list.

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

On a company brief, PR search is limited to the company's GitHub owner: `--org <owner>`, or else the company's `github_org` in `companies/manifest.yaml`. With neither, and on a personal brief, it covers every owner the user's `gh` login can see (one search, shared by every section of a person brief). Each PR row is then tagged with its company from the manifest (`scripts/brief_company.py`), reading git remotes only for the repos of companies in the session lock: a locked company's `repos:` entries and their `origin` remotes map an owner-qualified repo to that company. A whole GitHub owner maps to a company only when it is an organization (checked with `gh api`; never a personal account and never the person's own login) whose known repos all belong to that company, or when it is the company's explicit `github_org`. Otherwise a PR matches on its full owner/name only, and an unmatched PR is the person's own. A repo listed under two companies belongs to neither section, and a PR in a repo whose folder name the manifest lists under a company outside the lock is kept out of the personal section. A company section keeps only its own rows; the personal section keeps only rows mapped to no company. Everything else is dropped and only counted in `prs_other`. The worktree scan treats worktrees the same way: they count in `detail.other` and their paths are never listed. Main-branch CI checks the repos of the user's own PRs in the window (most PRs first, at most 8); `--repos a,b` names them instead, as bare names (owner from `--org` or the PR rows) or owner-qualified names.

The script covers these sources:

| Source | Read through |
|---|---|
| Work sessions | Sessions come from `workspace/sessions` meta files plus the Claude and Codex transcripts (title, and kind you, agent or lane), for the last 24 hours (`--hours`). Other-company sessions are a count only. |
| Recorded meetings (company only) | `hq meetings list`. The list row supplies the title, start and participants |
| Synced signals (company only) | The company vault's signal index, `signals/_index/{UTC day}.json`, for the last 24 hours (`--hours`); a catch-up brief reads back to `window.attended_meetings_from`, the same span as its meetings, so older meetings in the gap keep their signals. No integration or meeting service is called. Index rows in both shapes are read: `{key, written_at}` from the hot-channel pass and `{path, audience_key}` from `hq signals run`, which keeps the time in the signal file's `created_at`. Read: the company folders (`signals/{type}/`), the person's own folders (`signals/@{key}/{type}/`, keys from the HQ login via `hq whoami --json`: key(email), also used for the sync ledger and cursors, and key(personUid); when `hq whoami` reports no personUid, it comes from `hq members --company <slug> list --json` by email; `--email` or `git config user.email` only when `hq whoami` is unavailable; the result records `identity_source`), and group folders whose `_audience.yaml` principals include the person's uid or email (email compared case-insensitively). A folder whose audience does not include the person is never read. Each line carries the `company` it was read from. A day with no index file falls back to the type folders, including the older `signals/slack-dm/{type}/`. Code: `scripts/brief_signals.py` |
| Meeting signals (company only) | Built from the synced signals whose `source_ref` is a meeting pointer (`sources/meeting-events/…`), grouped by the pointer's transcript id. Per meeting, up to 5 decisions and 5 action items carry `text` (the signal's summary line, never transcript text), `owner`, `mine` (the owner is the user, matched against `--me` or `git config user.name`), `source_ref` and `cite` |
| DM inbox | `hq dm inbox`, then only this company's messages. A personal brief keeps messages with no company. Another company's messages are dropped and never written. Agent senders, with `agt_` IDs, are labeled. A message's company is its slug field (`company`, `companySlug` or `company_slug` on the message or its channel); an explicit field always wins. In person mode, a message with no such field is attributed by its sender: a sender who is an active member of exactly one included company (`hq members --company <slug> list --json`, read for the included companies only) belongs to that company, and the row records `company_basis: "sender"` (`"tag"` for an explicit field). A sender in two included companies, or in none, stays personal. If any included roster cannot be read, sender attribution is off for the run and `sources.dm_attribution` says so. On a company brief with attribution off, if the inbox page has messages and none carry a company slug field, the source is skipped with `skipped_reason: "inbox has no company tag"`. `companyUid` is an id, not that field. An empty inbox is a real empty result, not a skip. |
| Fleet agents (company only) | `hq agents list` |
| The user's PRs | `gh search prs --author @me` (with `author`), plus open PRs where the user is a requested reviewer (`--review-requested @me`, marked `review_requested: true` and `reviewRequests: ["@me"]`). Each row has `product`, `repo`, `repo_full` (the owner-qualified name), `authored_by_me` and `is_release`. Read-only |
| Main-branch CI health | `gh run list` |

Every source has an entry in `brief-data.json.sources` with `state`: `ok` (it ran), `failed` (it ran and broke; `note` and `error` hold one plain line such as "Couldn't read DMs."; the exception text goes to stderr only) or `skipped` (left out on purpose; `skipped_reason` says why). On a personal brief the company-only sources use `needs a company`. On a company brief, DMs use `inbox has no company tag` when the inbox page cannot be filtered by company. `ok` is true only for `state: ok`. A skipped source's top-level key is null. The top-level `mode` is `person`, `company` or `personal`. In person mode, `personal` holds personal sources and `companies.<slug>` holds each company sweep; `company` is null at the root. Each section has its own sources, window, derived summaries and deltas. Person history compares only previous `mode: person` runs, matching company sections by slug.

A skipped source is not a failure and not an empty result. The sweep writes its activity entry with `state: skipped`, a plain label (`Skipped DMs` for the inbox) and `detail` set to `skipped_reason`. It does not write `findings.dms` as `{total: 0}`, and it does not say there were no messages. The brief copies that: when `sources.dms.state` is `skipped`, write no DM decisions, waits or people from the inbox, and do not say the inbox was empty. One clause is enough: "DMs were skipped; the inbox has no company tag."

The script also writes `window.today`, `window.hours`, `window.prs_from`/`prs_to`, `window.attended_meetings_from` (= `sessions_from`, or the first catch-up day), `window.signals_from` (the start of the synced-signals read, never later than `attended_meetings_from`), and a top-level `prs_summary: {merged, opened, open, review_requested, median_merge_hours, by_product}` for the 24-hour window, counting only the user's own PRs. The loader's PR line uses the same function, so the app and the brief show the same numbers.

Derived data the sweep adds for the app's widgets (all computed, never estimated; every helper has a unit test in `scripts/test_brief_additions.py`):

| Block | What it carries |
|---|---|
| `sessions[]` | `project` (repo from the cwd), `product` (its human name), `cwd`, `last_activity`, `has_handoff` (a handoff thread record exists). Other-company rows keep only times and counts. On a personal brief the person's own rows, the ones bound to no company, carry `company: "personal"`; rows bound to any company count as `other` |
| `prs[]` | `closed` is null on open rows, `isDraft`, `merge_hours` on merged rows, `reviewDecision` and `reviewers` on open rows (a bounded `gh pr view`, null when it did not run) |
| `prs_summary.by_product[]` | `{product, merged, opened, open, median_merge_hours}` for the window |
| `releases[]` | `{product, repo, version, merged_at, url, pending_count, pending_by_day: [{day, count, theme}]}`: the latest merged Release PR per repo and the merges that landed after it |
| `main_health[repo].red[]` | `{workflow, since, merges_on_top}`; `since` is the first red run found (carried back to the previous run's value when it was already red). `delta: {newly_red, still_red, recovered}` against the previous ready run, null when there is none |
| `fleet` | `stuck: [{name, status, phase, since}]` (setup failed or waiting, or a status that is not resting; dormant is not stuck), `delta: {newly_stuck, still_stuck, recovered}` by name, `series: [{generated_at, stuck}]` one bucket per prior ready run. `sources.fleet.count` is the agent count |
| `meetings[]` | only meetings whose start is inside the window, deduped by title and start (`duplicate_ids` keeps the folded ids), with `participants` (names when the list row has them), `end` and `duration_min` (null when the list row has none), `attended` (the user's own recorder took it, or the user is in the participants, the title or owns one of its synced signals) and `whose` (`mine` when attended, else `team`). The `days` rollup counts the same way: `days[d].meetings` is the user's own meetings that day and `days[d].team_meetings` the teammates' ones, never added together |
| `meeting_signals[]` | `{meeting, title, meeting_id, start, counts, decisions[], action_items[]}`; each item is `{text, owner, mine, source_ref, cite}` |
| `synced_signals` | `lines[]` (`{signal_id, type, text, owner, source_ref, cite, written_at, key, company}`, plus `meeting: {title, transcript_id}` for meeting refs; a row with no `source_ref` is dropped and counted in `dropped_uncited`), `lag` (null when today's index exists, else `{newest_index_date, days_behind, last_run, line}` with the last sync run from `sources/_runs/@{key}/`), `freshness[]` (`{adapter, connection, last_synced, source}` per sync cursor: `source` is `cursor` when the cursor has `updatedAt`, `mtime` when the file time was used), `legacy_days`, `keys` (own keys), `group_keys` (group folders read), and `meetings_without_signals` (`{count, line}` when meetings fall in the window but no meeting signals were synced, else null) |
| `timings` | wall seconds per source, for finding a slow sweep. Independent sources (sessions, meetings, synced signals, DMs, fleet, PRs) run at the same time, so their seconds overlap and add up to more than the run |
| `dms[]` | `need_you` (looks like an ask: "?", "can you", "please", "need you", "waiting on"; the writer confirms each one by reading the preview), `direction` and `thread_id` (null until the inbox exposes them). `sources.dms` records `truncated` and a `note` when the 40-message page did not reach back to the window start. When the source is skipped, `dms` is null and there is no truncation note |
| `previous_run` | `{run_id, generated_at}` of the previous ready run, found through `index.jsonl`; null for a first brief |
| `signals_stale` | The signals gate's stale notice for this company, copied by the sweep from the company's entry in today's `brief-gate.json.staleCompanies` (or the gate-level `signals_stale` when the gate judged no company list at all): `{code, reason, last_good_run: {date, finished_at} or null, try_now, line, try_now_line, section_line}` (Step 0, item 3). Null on a personal brief, when the gate file is missing, from another day or has no entry for the company, and for a company that is ready today. In person mode each company section has its own, and one company's notice never appears in another's |
| `welcome` | The welcome edition (below), or null |

On a company brief, read connected apps through `brief-data.json.synced_signals` only. The sync service has already turned Slack, Gmail, meetings and the other connected apps into signals, so the brief makes no live integration calls. Record `sources.integrations` as `{ok: false, state: "skipped", skipped_reason: "read from synced signals"}`. Use the synced data this way:
- Every line the brief writes from a signal keeps its `source_ref`, and shows its short `cite` so the user can find the source.
- When `synced_signals.lag` is set, write its `line` once near the top, as given ("Signals are behind: newest index is 2026-10-25 (last sync run 2026-10-25, gmail, error)."). Do not fill the gap by calling the apps.
- Show `synced_signals.freshness` as one "last synced" marker per app.
- When `brief-data.json.signals_stale` is set (`companies.<slug>.signals_stale` in person mode), today's signals run did not finish for that company. The notice itself is placed by code (`brief.json.signals_notices` in Step 4, the page's notice card and card labels in Step 4b), so you write neither `line` nor `section_line` into any item. What you do:
  - Items you write from `synced_signals` or `meeting_signals` for that company (decisions, action items, waits) keep their `source_ref` and `cite`, and their `title` and `why` never say or imply the signal is from today. When `signals_stale.last_good_run` is null, write no item from that company's signals at all.
  - `signals_stale.line` and `signals_stale.section_line` are fixed sentences. `section_line` says the signals are from the last good run and gives its date, or that no good run was found. On the page, code gives every card that comes from that company's signals the corner tag "From <date>" ("From Oct 1") and starts its `why` with `section_line`; a company whose signals are fresh is never marked.
  - Write no line from today's local signals and no "Yesterday's signals run" section: both are for a Step 0 that ended `ready`.
  - Every other source (sessions, PRs, CI, DMs, meetings, agents) is written as on any other day.
- Only when Step 0 ended `ready` (not `off`, not skipped, not item 3): read today's local signals for each in-scope company with `node core/scripts/ontology-brief.mjs --company <slug> --hq-root "$PWD" --days 1 --json`, and add only signals whose `source_ref` is not already in `synced_signals.lines[].source_ref`. Every brief line taken from a signal cites its source document (the signal's `source_ref`), the same as `synced_signals.lines[].cite`. A line with no source document is dropped. With the gate `off` or skipped, or after item 3, the brief reads signals through `synced_signals` only.
- Only when Step 0 ended `ready`: write a "Yesterday's signals run" section from:

  ```bash
  python3 -I .claude/skills/daily-brief/scripts/brief_gate.py summary \
    --hq-root "$PWD" --today <today> --companies <slug,slug>
  ```

  It prints `itemsIn`, `signalsOut`, `catchUp`, `estimatedSpendUsd`, `maxBudgetUsd`, `byAdapter`, `freshness[]` (one stored cursor per adapter from `workspace/signals/watermarks/{company}/`) and `status` for yesterday's run folder. Render one line: "Yesterday's run read <itemsIn> items and found <signalsOut> signals. Spend $<estimatedSpendUsd> of the $<maxBudgetUsd> cap.", add "It ran as a catch-up." when `catchUp` is true, and cite the run folder (`source`). When `found` is false, write "No signals run yesterday." only.
- When `synced_signals.meetings_without_signals` is set, write its `line` once in the meetings part ("Signals not yet generated for 2 meetings."). Never show those meetings as having no decisions.

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

`age_hours` is always computed from a timestamp in `brief-data.json`, never estimated: the meeting start, the PR `created`, the earliest matching DM `at`, or the `since` of a red workflow (the first prior run that listed it red). `source` is required on decisions and incidents: `meeting_signals`, `synced_signals`, `dms`, `main_health`, `prs` or `fleet`. An item from a signal also carries its `source_ref`. The app folds the sweep's own red-main risk into the decision or incident with `source: main_health` on the same repo or product, so write exactly one item per red repo.

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
- `signals_notices`: the stale-signals notices of this brief, written by code only (`brief_page.py notice`, below). A list with one entry per company whose `brief-data.json` section has `signals_stale`, by company slug, each `{company, code, reason, last_good_run: {date, finished_at} or null, try_now, line, try_now_line, section_line}` copied from that section; `[]` when no company is stale, in every mode. The same command puts each `line` first in `learned_notes`. Never set, edit or drop either by hand.
- `mode`: `company` or `personal`, copied from `brief-data.json.mode`. Write `mode` and `company` on the run's `index.jsonl` line too.
- `welcome`: copied from `brief-data.json.welcome` when it is set; omit it or write null otherwise. The writer may shorten each `next_steps[].reason` but adds no new steps. On a first run where `welcome.sessions.total` is above 0, the brief writes no empty-state lines anywhere: no "Nothing owed", "No sessions", "Nothing needs a call from you today" or similar. Lead with the person's own work from `headline`, `top_projects` and `recent_work`, and turn quiet lists into the `actions` (primary first). The first brief has no technical sentences.
- `week`: `[{date, sessions, meetings, merged, opened, beat?}]`, the last 7 local days of the active company (or of the person's own work on a personal brief), copied from `brief-data.json.days` (that is what `--days 7` is for). `meetings` there is the user's own meetings only; never add `team_meetings` into it. `beat` is optional: `{kind: turn|crisis|resolution|push, label, evidence}` where `crisis` is the day an incident opened, `resolution` the day something in `items.recovered` recovered, `push` the day with the most merges, and `turn` the event that led into the crisis. One beat per day at most.
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
- **meetings:** lead with the user's own meetings (`whose: mine`). Teammates' meetings (`whose: team`) get no item of their own; mention them only as one plain count line ("4 team meetings you weren't in") or when one carries an action item the user owns. Only meetings whose start is inside the window (`brief-data.json.meetings[]` is already filtered to `window.attended_meetings_from..sessions_to`, deduped, and marked `attended`); a catch-up brief widens that to the gap. Each meeting item carries:
  - `attended` (copied), `duration_min` (copied), `with`: the other participants in plain words ("Robin Bell", "Alex and Jamie");
  - `decided`: up to 3 lines from `meeting_signals[*].decisions[*].text`, each shortened to one plain line;
  - `todo`: up to 3 `{text, owner, mine}` from `action_items`, the user's own first.
  The app's meeting hover shows the title, the decided lines and the to-do lines (the user's own marked), nothing else. Every action item with `mine: true` is also a decision candidate under (d), with a launch prompt. Meeting signals cover only signals synced inside the window, so an older meeting's action items appear only while they are inside it.
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

Write `brief.json` as `{run_id, generated_at, today, mode, company, window, catch_up, lead_hint, priorities, counts, week, landed_days, time_to_clear_min, items, prefs_applied, learned_notes, welcome}`, where `company` copies `brief-data.json.company` (null on a personal brief), `counts` copies `prs_summary` and `prefs_applied` holds `density`, `engine`, `vip_people`, `muted` and `widgets`. Then run these two, in this order, every time you write the file:

```bash
python3 -I .claude/skills/daily-brief/scripts/brief_page.py notice --brief workspace/brief/<run_id>/brief.json
python3 -I .claude/skills/daily-brief/scripts/brief_rank.py --check workspace/brief/<run_id>/brief.json
```

`notice` reads the `brief-data.json` beside `brief.json` and writes `signals_notices` (and the notice lines in `learned_notes`); it runs on every brief and writes `[]` when signals are not stale. When a company is stale and `brief.json` has no valid page yet, it also writes `brief.json.page`: a page built by code alone from `brief-data.json` (the lead, one notice card per stale company, and the computed cards with fixed titles), checked with the page validator before it is written, so a stale brief has a page that shows the notice even if Step 4b never runs. Step 4b's `attach` replaces it with your page. Exit 1 with a `problem` in the output means `brief-data.json` could not be read and nothing was written: pass `--data <path to brief-data.json>` and run it again; do not go on without it. Exit 2 means no valid page could be built; Step 4b says what to do (one terminal action, no retry). `--check` compares both with `brief-data.json` and reports `signals_notice_problems` when the field is missing or was edited, or when a company is stale and `brief.json` has no valid page carrying each stale company's notice card and signal-card labels: fix it by running `notice` (or Step 4b's `attach`) again, never by typing the notice.

Fix every `title_problems` entry (it now covers `shipped[].title`, `shipped[].highlights`, `handoffs[].object`, `recovered[].title`, `releases[].held[].title` and `waiting[].what`; reminders are exempt), every `field_problems` entry (a decision without a valid `action`, a wait without `who` or `what`), every `over_cap` list, every `dangling_priorities` and `priority_problems` entry, `lead_hint_problem`, `widget_problems`, `today_problem`, `signals_notice_problems` and `welcome_problems` (empty-state lines on a first run with sessions, or exception text in `welcome`), and write the file again. Write status `step: "Writing your brief"`, `progress: 0.9`.

## Step 4b. Write the page

The desktop app draws the brief as cards from `brief.json.page`, a BriefPage. Write it after `brief.json` passes `brief_rank.py --check`, from the same data. The page is additive: everything in Step 4 stays as it is. It is optional only while `brief.json.signals_notices` is empty. When a company's signals are stale the brief must have a page, because the page is where the app shows the notice; code guarantees one (Step 4's `notice`, and `attach` below), and you still write the full page here so the reader gets your cards.

### Frame and candidates (deterministic)

```bash
python3 -I .claude/skills/daily-brief/scripts/brief_page.py skeleton \
  --data workspace/brief/<run_id>/brief-data.json --person "<first name>" \
  --hq-root "$PWD" --out workspace/brief/<run_id>/page-draft.json
```

`page-draft.json` holds `page` (the frame) and `candidates`. The frame already has `version`, `companies` (each included company by slug with its manifest name, plus `personal`), `person`, `window` (`from` is the previous brief, `hoursAway`, `zoom` and a plain `label`), `theme: {style: "merged"}`, the lead card with the window's real numbers (your meetings, people waiting on you in DMs, your to-dos when there are any, the "your day" line of your meetings, work sessions and asks, and chart labels in local time such as "Fri morning" or "Mon 3 pm"), and the cards beside the lead with real data and empty titles. Each candidate is one card's worth of computed facts: `company`, `type`, `kind`, `size`, `symbol`, `data` (hours from timestamps, counts from rows, people), `drill.signals`, `facts`, `rank`, and for asks `dropped_candidate` (waited a day or more) and `basis` (`sender` when the DM's company came from its sender). Candidates come ranked, most important first: cards about people, meetings and tasks first (dropped-ball candidates by longest wait, then asks, your tasks, meetings, broke), then cards whose evidence is only PRs or CI (review requests, red builds, stalled and merged PRs). Most people do not run builds: keep PR and CI cards in the stream, never the lead or the summary band, and write the lead's headline about people, meetings and decisions rather than merges. A suggested `data.visual` is kept only when the card holds what that drawing reads.

When a section of `brief-data.json` has `signals_stale`, the frame already shows it. Each stale company has its own notice card, first beside the lead in slug order: id `signals-stale-<slug>` (every notice card's id starts with `signals-stale`), that company's slug in `company` (the app draws its badge), kind `note`, type `broke`, symbol `warning`, corner tag `label: "Stale signals"`. The app draws the tag and the `title` on a closed card and the `why` only when the card is opened, so each part says something the others do not. The title, drawn on the closed card and again, larger, on the opened one, says how old the signals are, date first: "Last updated <date>" ("Last updated Oct 1", the date kept on one line), under the tag "Stale signals". The date is the last good run, which is when the signals were last updated, not the day anything broke. When the brief covers more than one company (the company sections of `brief-data.json`, whether or not each has cards today), the title names the company after the date: "Last updated Oct 1 · Acme Inc"; a brief for one company keeps "Last updated Oct 1". When no signals run has ever finished the title is "No signals yet · Acme Inc" in every brief. The date always comes first because the app draws at most two lines of title: at the narrowest S card a line surely holds 17 characters, so "Last updated" fills line 1 and the date (at most "Sep 30, 2025") line 2, and only the name, kept with its "·" as one block of at most 17 characters, can be clipped. On the opened card a line holds 19 characters, so the title takes two lines, except a named title with a date from last year, which takes three ("Last updated" / "Sep 30, 2025" / "· Acme Inc"): the date block cannot share a line with "Last updated", and the name cannot leave the title without leaving the closed card unnamed. A title is at most 43 characters. The notice names its company in words, because the app draws a company badge only when the cards on the page span more than one company. The `why`, on the opened card, says why today's signals are missing, in one plain sentence led by the company's name: "Acme Inc: sign-in to a connected account failed.", "Acme Inc: today's signals run has not finished yet." (a wait that timed out and a run not yet finished read the same, since to the reader both mean the run is still under way). When no run has ever finished, the title already names the company, so the `why` says what that means and then why: "No run has finished yet, so signal cards are hidden. Sign-in failed." It does not repeat the title, and it is at most 76 characters so the opened card shows all of it in its two lines. The card also sets `drill.bot`, the message Ask my bot sends, as one statement with nothing said twice: "From my Daily Brief: Signals for Acme Inc were last updated Oct 1. Sign-in to a connected account failed. What should I do about it?", or "From my Daily Brief: No signals run has finished yet for Acme Inc, so its signal cards are not shown. …". No sentence uses a possessive of a company name. A long name is cut with an ellipsis: in the `why` at 27 characters, between words; in the title at 15 characters and two words. The date and the reason are never cut. The year is left off a date when it is this year's by `brief-data.json.window.today`, the local day the gate also uses. Nothing on the page mentions "Try now", because the page has no such control. With one stale company the band keeps one more card; with two, both notice cards fill it; with three, all three; any further ones head the stream. The lead has no to-do count. To-do candidates of a stale company carry `facts.signals_from` (the `section_line`); when that company has no good run, its to-do candidates are not offered at all. A company whose signals are fresh has no notice card and its candidates are as on any other day.

People's names are display first names. The sweep resolves each DM sender (`from_name`) and PR author (`author_name`) from the member list of that section's own company only (the personal section uses none), the GitHub profile name of a login, a full name on a member list whose login shape matches, or an email of the form first.last. A handle is kept only when nothing resolves.

### What you write

Turn candidates into cards. You choose which cards appear, their title, `why`, kind, size and order, and you may merge candidates (two asks from one person) or drop them. You never add a number or a fact that is not in a candidate or in `brief-data.json`.

- **The lead.** `summary[0]` is the frame's lead card: kind `focus`, size `XL`, type `summary`. Write its `title` and `data.headline` (one short line about where today's attention goes, with an `accent` word) and up to three `data.bets` (`{label, symbol, share, itemId}`, shares summing to at most 1, `itemId` naming a card on the page). Keep its stats, spark and chart labels. Chart labels anywhere on the page read like "Fri morning" or "Mon 3 pm", never a timestamp.
- **Beside the lead.** The lead takes four of the six columns and two rows, so the summary band needs cards that fill the other two columns by two rows with no gap: M + S + S, M + M, or one L (S is 1 cell, M 2, L 4; 4 in all). The frame already has them: the people waiting on you in one company, and counts that span the page. Write their titles. You may swap one for a better card from the candidates, but keep the band at exactly 4 cells. A count-only summary card may leave `company` out; a card that names a person or quotes anyone carries its company.
- **Stale signals.** Keep every notice card exactly as the frame has it, in the frame's place (`summary[1]` onward): do not retitle, retag, resize, move, merge or drop one, and add no other card beside the lead unless the frame has one there. Write signal cards (to-dos, decisions, dropped balls owed from a meeting, anything that cites a meeting or an email) as usual under their own company, without wording the staleness yourself. `attach` gives each one from a stale company the corner tag `label: "From <date>"` ("From Oct 1"; at most 17 characters, "From Sep 30, 2025", so it fits the smallest card with a company badge), which the app draws on the closed card, and starts its `why` with that company's `section_line`; it removes the card when that company has no good run; it leaves the cards of a company with fresh signals alone; it removes a signal card that has no company or sits under `personal`, which has no signals of its own; and it restores a notice card that is missing or changed.
- **Caps are hard.** The app draws at most 5 dropped balls and 12 stream cards and drops the rest without a "+N more", so fill each band in rank order and leave out what does not fit.
- **Dropped balls.** At most 5, longest wait first: asks where this person is the one not moving (`dropped_candidate`, carry-over items still open, owed meeting actions). Each is kind `ball`, type `dropped`, size `M`, with `data.pickup` (the one-press action in plain words, such as "Reply to Ann about the memo"), `data.hours` and `data.people`. Zero dropped balls is a real result: leave the band empty.
- **The stream.** At most 12 cards, ranked by how much this person would care, size following rank (L for the top one or two, then M, then S). At most 3 per type.
- **Colour is meaning, so do not set `field`.** The type picks the colour, one meaning each: pink dropped, sunset broke or due (a launch, or a task due within 7 days), violet your move (asks, client, your tasks), teal landed or learned, graphite for the record (decided, moved, stalled, meetings, waiting on someone else). A card whose type does not fit its meaning gets a different type, never a different colour.
- **Every card carries its company:** the candidate's slug (`personal` for the person's own work), which must be a key of `page.companies`. A card holds one company's facts only. Never name one company's people, work or words on another company's card, and never merge candidates from two companies into one card. Treat a `basis: sender` ask with care: if its words are clearly about another of the person's companies, leave it out.
- **A drawing holds real information.** Set `data.visual` only to a recipe the card can fill: `clock`, `dial` and `tide` need `hours`; `letters` and `lock` need a person (`mailbox`, `constellation` and `drawers` two or more); `tally` and `stack` a whole `value`; `sparkline` 3 or more `spark` points (`skyline` 4 or more); `checklist` 2 or more `steps`; `track`, `fuse` and `rocket` steps, milestones or days; `compare` hours with `usual`, or 2 to 5 `bars`; `trace` and `breaker` a `to`; `agenda` a meeting; `fork` and `switch` a decided or moved note; `bell` a landed note; `book` a learning note; `siren` and `lighthouse` a broke `value`. Leave `visual` out when unsure, and the app picks one and varies the page. Name the same drawing at most twice a page, and at most 3 pixel scenes and 2 iso objects.
- **Names.** Use the candidate's people names as given (resolved first names). Never write a login or handle when the candidate, `from_name` or `author_name` has a name; `check` warns on handle-looking names.
- **Titles** follow the Step 4 title rules: verb first, 8 words or fewer, product names, no repo names, PR numbers, prefixes or paths. `why` is one sentence for this reader.
- **Drill-in.** `drill.signals` (at most 4, `{source, text, at}`, `source` one of dm, meeting, session, pr, ci, calendar, task, email, analytics, doc), `drill.prompt` (the item's launch prompt from Step 4, same rules) and `drill.bot` (one line for Ask my bot). Summarize DM text in your own words; quote at most a short phrase in `data.quote`.

### Check and attach (fail soft)

Write the page to `workspace/brief/<run_id>/page.json`, then:

```bash
python3 -I .claude/skills/daily-brief/scripts/brief_page.py check workspace/brief/<run_id>/page.json
```

Fix every error and check again, at most twice. Then attach it:

```bash
python3 -I .claude/skills/daily-brief/scripts/brief_page.py attach \
  --brief workspace/brief/<run_id>/brief.json --page workspace/brief/<run_id>/page.json
```

`attach` reads the `brief-data.json` beside `brief.json`. It writes `brief.json.signals_notices` again, and when a company's signals are stale it first applies the notice to your page (each stale company's notice card from `summary[1]`, the tag and `section_line` on that company's signal cards or the cards removed, the to-do count removed), whatever the page said. Then it validates. A valid page is written into `brief.json` as `page`. An invalid or missing page is left out, every other field of `brief.json` stays as it was, and the reasons go to `brief.json.page_problems` and stderr. Never fail the brief because of the page; add a `learned_notes` line when it was left out. When signals are stale and your page is invalid or missing, `attach` does not leave the brief without a page: it attaches the page built by code (the lead, the notice cards and the computed cards with fixed titles; it greets the reader by `brief-data.json.person.name` when the data has one; with none the headline reads "Good morning, here is your brief.", because the app always writes a comma and the name field after the greeting) and prints `"fallback_page": true`; `page_problems` still lists what was wrong with yours, and you may fix your page and run `attach` again. The app draws neither `signals_notices` nor `learned_notes`, so the page is the only place the reader sees the notice.

`attach` exits 0 on every brief whose signals are not stale, as it always has. When its output has a `problem` saying `brief-data.json` could not be read, the page was attached as written, with no notice and no labels: pass `--data <path to brief-data.json>` and run `attach` again before you go on. (Step 4's `notice` exits 1 for the same cause, so you normally meet it there first.)

The page code writes never reads `page.json` or `page-draft.json`: it is built from `brief-data.json` alone and checked with the same validator before it is written, so neither command can leave an invalid page in `brief.json`. Exit 2 from `notice` or `attach`, with a `problem` saying no valid page could be built, is the one case where a stale brief has no page. It is terminal: do not run either command again and do not write a page by hand. Go on to Step 6, add the `learned_notes` line "The brief page could not be built, so the stale-signals notice is in the reply only.", and end with the stale reply, which then carries the notice.

After `attach`, run `brief_rank.py --check` once more. If `signals_notice_problems` is not empty, run `attach` one more time and check again. If it is still not empty, or either command exited 2, stop there: do not repeat, and take the terminal action above (Step 6 with the stale reply). Never edit `brief.json.page`, `signals_notices` or the notice lines by hand, here or later. `brief_rank.py --check` also reports `page_problems` for a page already in `brief.json`.

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

- Write status `state: ready`, `progress: 1.0`, as soon as `brief.json` is written and Step 4b's `attach` has run (it never blocks: a failed page is simply left out). Housekeeping updates `status.json.housekeeping` afterwards without changing `state`.
- Append the run to `workspace/brief/index.jsonl`.
- Print one line: `BRIEF READY <run_id> <path to brief.json>`. The desktop app watches `status.json` and shows the notification.
- When `brief.json.signals_notices` is not empty (the brief was built with stale signals), end with the stale reply from Step 0: after the `BRIEF READY` line, one line per stale company (each entry's `line`, the same sentence as the gate's `signals_stale.line`, then its `try_now_line`, both as given), then the `hq-block` fence with "Try now", last. This follows the file, not the path Step 0 took, so the reply and the page always agree. A brief with an empty `signals_notices` has no such reply. A stale brief is still a `ready` run: status, index line and `BRIEF READY` are written as for any brief.
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
- **The page is additive.** `brief.json.page` is optional, except on a brief with stale signals (`signals_notices` not empty), where code always writes one because the notice is shown there. Never drop or rename an existing field to make room for it; an app that does not read `page` keeps working from the rest of the file.
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
