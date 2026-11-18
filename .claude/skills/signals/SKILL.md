---
name: signals
description: Read HQ-native company signals such as decisions, actions, risks, commitments, and wins.
allowed-tools: Bash, Read, Grep, Glob
argument-hint: "[run]"
---

# /signals — Read HQ-native signals (decisions, action items, wins, risks…)

Signals are an **HQ-native, per-company store** of meeting/comms intelligence — discrete, cited items extracted from meeting notes and other sources. This is the generic, multi-company reader. A company may also ship its own namespaced interface (e.g. `{co}:signals`, `{co}:action-items`) over the *same* store; this skill serves **all** companies.

**Canonical store:** `companies/{co}/signals/{type}/{sha256}.md` (company-wide) and `companies/{co}/signals/@{audienceKey}/{type}/{sha256}.md` (visible only to the people privy to the source — spec `core/knowledge/public/hq-core/ontology-local-spec.md`), daily index `companies/{co}/signals/_index/{YYYY-MM-DD}.json`.
**Mechanism/schema detail (read once if needed):** `core/knowledge/public/hq-core/native-knowledge-stores.md`.

## Signal types (8)

| Type | Use it for |
|---|---|
| `action_item` | tasks/to-dos assigned to an owner |
| `commitment` | explicit promises a participant made |
| `decision` | decisions reached |
| `risk` | blockers, concerns, threats raised |
| `question` | open questions, unresolved |
| `key_point` | notable discussion points |
| `participant_contribution` | what a specific person contributed |
| `summary` | per-meeting summaries |

"Wins / accomplishments" → read `decision` + `key_point` (and `summary`). "Follow-ups" → `action_item` + `commitment`.

Each signal `.md` has frontmatter: `canonical_content` (one-line normalized statement), `citations[]` (`location` timestamp, `source_ref`, verbatim `text`), `entity_refs[]` (`person/…`, `project/…`), `source_ref`, `type`, `signal_id`.

## Hard rule

HQ-native first. Read the signals store to answer these asks. **Never** default to scraping email or a third-party notetaker. If the store is empty/unactivated, steer the user to activation (below) — don't fabricate or guess.

## Resolution (run every time)

1. **Resolve company.** `bash core/scripts/hq-session.sh get company_slug`; else infer from cwd/manifest; else ask.
2. **Load preference (company over global).** Read `companies/{co}/settings/knowledge/preferences.yaml` then `personal/settings/knowledge-preferences.yaml`. Built-in default: `signals_enabled: true`. If a company has `signals_enabled: false`, tell the user it's disabled and offer to enable it (flip the flag) rather than reading.
3. **Classify the ask** via the type table (and any `aliases.signals` in the preference file): action items → `action_item`, "what did we decide" → `decision`, wins → `decision`+`key_point`, risks → `risk`, open questions → `question`, "{person} committed" → `commitment` filtered by `entity_refs` person.

## Reading

- **Recency:** use the latest `_index/{date}.json` files (newest dates first) to find recently-written signals; or list newest files under both `companies/{co}/signals/{type}/` and `companies/{co}/signals/@*/{type}/`. Skip `_candidates/` (not yet gardened). Mark each scoped item as scoped when presenting it, and never repeat a scoped item into a shared surface (a channel post, a company doc).
- **Filter:** by type (dir), by owner/person (`entity_refs` contains `person/{slug}`), by project (`project/{slug}`), by date.
- **Present:** group by type; show `canonical_content` per item with its owner/source; cite the meeting (`source_ref`) and timestamp from `citations[]` when useful. For mutable action-item tracking with status lifecycle, note that a company may ship a dedicated namespaced tracker (e.g. `{co}:action-items`); reading is read-only; `/signals run` (below) is the one write path.

## Empty / not-activated branch

If `companies/{co}/signals/` is empty or absent, signals haven't been extracted for this company yet. Surface the turnkey ladder (full version in the knowledge doc + USER-GUIDE):

1. `/designate-team {co}` to make the company cloud-backed.
2. Capture meetings with the HQ meeting bot (`/meeting-notes` covers this) → notes ingest.
3. Signals are extracted from ingested notes into `companies/{co}/signals/` automatically once provisioned.
4. Note: billing is live. Every HQ company can invite the HQ meeting bot. On HQ Workforce (legacy) recorded meeting time is billed at \$1/hour, counted by the minute, and a company that kept its meeting-hours item through the switch to usage pricing keeps being billed \$1/hour. If HQ refuses an invite or asks for a card, relay its message. Signals extraction runs on HQ cloud over the notes that arrive. Plan details: `core/knowledge/public/hq-core/plans-and-pricing.md`.

## Output

Quiet, plain, grouped summary of the signals the user asked for — decisions, action items, wins, risks, etc. — with light citations.

## `/signals run` (local signals pass on the main bot)

`/signals run` runs the local signals pass, `hq signals run`, and replies with the run result. It runs on the member's main local bot, the same bot that builds the daily brief. One run covers every company whose knowledge prefs have `signals_capture` or `ontology_capture` on; other companies are skipped with reason `prefs-off`. The reply shapes below follow hq-cli's own run reply (`src/lib/signals/reply.ts`): prose first, then one `hq-block` fence as the last thing in the message, the JSON on one line. Keep every number from the run record and drop a row the record does not carry.

### Which command

| The member says or the job fires | Run |
|---|---|
| The scheduled job fires (`/signals run`) | `hq signals run --trigger job --json` |
| "Try now", "run signals now" | `hq signals run --trigger chat --force --json` |

`--json` prints the run record when `--company` names one company, and otherwise the whole result (`date`, `records[]` with one record per company, `locked[]`, `summary`). Exit codes: 0 complete, partial, skipped, or the job already ran today; 1 a company failed; 2 usage or config error; 3 another run holds a company's lock. When the only company is locked, stdout is `{"status":"running","startedAt":...,"trigger":...}` and nothing was started: reply "Signals are already running. I reply with the result when they finish." and do not start another run. The records are also on disk: `workspace/signals/runs/<date>/{company}.json` per company (the source of truth for that company's day) and `workspace/signals/runs/<date>/summary.json` for the member. Defaults (`maxTurns`, `maxBudgetUsd`, `lateStartHour`, `briefWaitMinutes`) come from `core/settings/signals.yaml`; adapters are gated by `core/settings/signals-adapters.yaml`.

A job run on a day the job already ran (the returned record says `alreadyRanToday: true`) runs no steps: reply "Morning signals already ran today, at <h:mm AM>. Nothing new to do." with the badge `{"kind":"badge","label":"Already ran today","tone":"neutral","icon":"check"}`. `jobRanAt` alone also occurs on fresh runs and does not identify a no-op.

Time guardrail: a job run that starts at or after `lateStartHour` (22:00 local) runs the garden step only and the record carries `status: "partial"` with `partialReason: "late-start"` (older records: `partial: "late-start"`). The command enforces this; the skill reports it with the late-start reply.

### Creating the morning job

hq-cli registers a built-in job of kind `hot-signal-sync` on the local bot bound to each company (06:30 daily). What it runs depends on the hq-cli flag `cli.bot-signals-engine-job`, which is off by default:

- Flag on: the job runs the full `hq signals run` engine with trigger `job` (garden, adapters, extract, garden, upload) and replies in the formats below. It is the canonical morning signals job: keep it, and change its time instead of adding a second job.
- Flag off: the job runs the hot-channel sync alone (`hq sources sync`), writes no run record and starts no signals run. Moving it does not give the member a morning signals run.

Engine check. Run `python3 -I .claude/skills/daily-brief/scripts/brief_gate.py engine --hq-root "$PWD" --today <today>`, the same check the daily brief uses. It prints `{"on": true|false, "source": ...}`: on when `HQ_FLAG_CLI_BOT_SIGNALS_ENGINE_JOB` is `true` or `1` for this computer, or when a `--trigger job` run is recorded today or yesterday.

When the member asks for a morning signals job ("run signals every morning at 6"):

1. Run the engine check. When it says `off`, create no job and change no job. Reply in plain words: "I could not confirm that the signals engine is on for this computer yet, so I did not set up a job. Nothing else changed: your daily brief builds as before. Ask me again after the next morning signals run, or ask your HQ admin if it stays off." A signals job added while the engine is off would run the full engine for this member alone and make the daily brief wait on it. Stop here.
2. Find the main bot name with `hq bot list` and list its jobs with `hq bot jobs <bot> --json`.
3. If the list shows a `hot-signal-sync` job, move it to the asked hour (cron for the asked hour, here 6:00):

   ```bash
   hq bot jobs <bot> --reschedule <jobId> --cron "0 6 * * *" --json
   ```

   `hq sources schedule --company <slug> --at 06:00` does the same for one company's job. If the list also shows an older prompt-driven `/signals run` job, remove it with `hq bot jobs <bot> --rm <jobId>` so only one job runs the engine each morning.
4. Only when the bot has no `hot-signal-sync` job (it was removed earlier, and hq-cli does not add a removed one again), add a prompt-driven job:

   ```bash
   hq bot jobs <bot> --add "/signals run. Run hq signals run --trigger job --json and reply with the run result. When the scheduled-run message for this job says the run is late, add --catch-up to the command so the run is recorded as a catch-up. If it is after 22:00 local, the run does the garden step only and is recorded partial with partialReason late-start." --cron "0 6 * * *" --json
   ```

   On the classic CLI bot runtime, a job that fires late gets a notice saying it is late, so the job adds `--catch-up` and the record carries `catchUp: true`. HQ Fleet Runtime jobs get no such notice, so their late runs are recorded as normal runs. Do not promise the member that a late run is marked a catch-up.

   Leave `--tz` off so the job takes this computer's time zone (HQ Fleet bots refuse `--tz`). Local bot jobs live with the bot (the HQ Fleet Runtime schedule, or `jobs.json` for a legacy-runner bot) and run while the bot runs; never write a cron entry or launchd unit on the laptop.
5. Read the job back from `hq bot jobs <bot> --json` and take its time zone from the job record. Write it in words ("Pacific time", "Mountain time", "Central European time"); never assume a fixed zone.

Job-created reply. `Covers` lists the in-scope companies. Keep the `Then` row only when a daily-brief job exists on the same bot.

````
Done. I set up a job called Morning signals.

```hq-block
{"v":1,"blocks":[{"kind":"keyValue","items":[{"key":"Runs","value":"Every day at <h:mm AM>, <zone in words>","icon":"clock"},{"key":"Covers","value":"<Company, Company>","icon":"folder"},{"key":"Then","value":"Your daily brief, which now waits for it","icon":"calendar"}]},{"kind":"callout","tone":"info","body":"If your Mac is asleep at <h:mm AM>, I run it as soon as it wakes. The job and its last run are under Bot jobs on my profile."}]}
```
````

When the built-in job was moved, say "I set up a job called Morning signals" as "I moved your Morning signals job". When an older prompt-driven `/signals run` job was removed, add one sentence to the prose: "It replaces the older Morning signals job, so signals run once each morning."

### Run replies

Values come from the run records (fold the company records; `summary.json` has the totals):

- finish time: `finishedAt` in local time.
- `Companies`: companies that ran (not skipped).
- `Sources read`: the extract step's `itemsIn`, with the adapters step's `byAdapter` counts in brackets.
- `Signals found`: the extract step's `itemsOut`.
- `Candidates tidied`: the garden step's `itemsIn`, then `itemsOut` left waiting ("none left waiting" when zero).
- progress `value`: `round(estimatedSpendUsd / maxBudgetUsd * 100)`, both numbers in the label.
- `<date>` in questionIds: the run folder date, `YYYY-MM-DD`.

Run complete (`status: "complete"`, `catchUp` false; older records: no failed step):

````
Morning signals finished at <h:mm AM>.

```hq-block
{"v":1,"blocks":[{"kind":"badge","label":"Complete","tone":"success","icon":"check"},{"kind":"keyValue","items":[{"key":"Companies","value":"<Company, Company>"},{"key":"Sources read","value":"<n> items (<adapter> <n>, <adapter> <n>)"},{"key":"Signals found","value":"<n>"},{"key":"Candidates tidied","value":"<n>, none left waiting"}]},{"kind":"progress","value":<pct>,"label":"Spend $<spend> of the $<cap> cap","tone":"neutral"},{"kind":"decision","questionId":"signals-run-<date>-open-brief","question":"Your brief builds next.","options":[{"id":"open-brief","label":"Create today's brief","recommended":true}],"allowOther":false}]}
```
````

Catch-up (`catchUp: true`, set by `--catch-up` on a late job run): the same fence with the badge `{"kind":"badge","label":"Catch-up","tone":"warning","icon":"clock"}` and the prose "Morning signals finished at <h:mm AM> instead of <scheduled time>. Your Mac was asleep at <scheduled time>, so I ran it when it woke."

Late start (`partialReason: "late-start"`; older records: `partial: "late-start"`): the same fence without the decision, with the badge `{"kind":"badge","label":"Late start, garden only","tone":"warning","icon":"clock"}` and the prose "Morning signals started after 10 PM, so I only tidied candidates tonight. The full run happens at <scheduled time>."

Finished with problems (`status: "partial"` with any other `partialReason`): the same fence with the badge `{"kind":"badge","label":"Finished with problems","tone":"warning"}`, then a warning callout whose title is the record's `failureReason` in one plain sentence (leave the title out when the record has none) and whose body ends "Your brief builds with what came in. Say \"Try now\" to run signals again." The prose is "Morning signals finished with problems at <h:mm AM>."

Run failed (`status: "failed"`; older records: a step has `status: failed`). The callout title is the failed step's `error` (else the record's `failureReason`) in one plain sentence. The body says what the member can do from `errorKind`: `config` (reconnect that app or fix the setting the reason names), `auth` (sign in with `hq login`), `transient` (nothing to do). Older records use `reconnect`, `signed-out` and `other` for the same three cases. Then say the brief still builds: a failed signals run never stops the daily brief, which builds from every other source with a note that signals are out of date (`.claude/skills/daily-brief/SKILL.md` Step 0). `Finished`, `Stopped at` and `Not run` come from the step list in order.

This skill schedules no retry: a record's `nextRetryAt` is the earliest time a retry may run, not a promise that one is scheduled. So the reply says "I do not retry this on my own." and offers only "Try now". Only the built-in `hot-signal-sync` job schedules a retry, and hq-cli writes that job's reply itself (with "I try again at <time>" and a "Wait for <time>" option).

````
Morning signals stopped at <h:mm AM>.

```hq-block
{"v":1,"blocks":[{"kind":"callout","tone":"danger","title":"<error in one sentence>","body":"<what to do>. Your brief still builds, with a note that signals are out of date. I do not retry this on my own."},{"kind":"keyValue","items":[{"key":"Finished","value":"<completed steps with counts>"},{"key":"Stopped at","value":"<failed step in words>"},{"key":"Not run","value":"<remaining steps>"}]},{"kind":"decision","questionId":"signals-run-<date>-retry","question":"Try again now?","options":[{"id":"try-now","label":"Try now","recommended":true}],"allowOther":false}]}
```
````

"Try now" (the `try-now` answer to `signals-run-<date>-retry`) runs `hq signals run --trigger chat --force --json` and replies with the run reply again. "Create today's brief" (the `open-brief` answer) starts the daily-brief job, the same action as the Daily Brief page's Create brief button.

## See also

- `/meeting-notes` — the source meeting notes
- `/ontology` — entities behind the signals
