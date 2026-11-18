# ontology worker

Gardens a company's local ontology and signals. Two skills:

- `process-source` — turns a declared source's new items (`sources/{channel}/`
  with a `source.yaml`) into signal and entity candidates, scoped to the people
  who were privy to each item.
- `garden` — promotes pending candidates (from sources and from session close)
  into identity-only entity files, audience-scoped facts and signals, and grants
  each audience folder to its principals on cloud-backed companies.

Specs: `core/knowledge/public/hq-core/ontology-local-spec.md`,
`core/knowledge/public/hq-core/source-yaml-spec.md`.

## Turning it on for a company

In `companies/{co}/settings/knowledge/preferences.yaml`:

```yaml
signals_capture: true
ontology_capture: true
```

Check with `hq core knowledge-prefs get {co} signals_capture`.

## Where it runs

Each source picks its runtime with `run:` in its `source.yaml`. Session-close
candidates are gardened by whichever runtime runs `garden` for the company.

### Default: the local bot job

A local bot (`hq bot create`) registers the built-in `hot-signal-sync` job,
which runs daily at 06:30 in the computer's time zone and builds signals on
that computer under the person's own logins. No cloud schedule is involved.
The job is not a `run:` value: it works from the company's connected
channels. With the engine flag on, its extract step processes declared sources
marked `run: local` and skips those marked `run: cloud`. See "Built-in
hot-signal-sync job" in `core/knowledge/public/hq-core/agents-and-bots.md`.

- With the hq-cli flag `cli.bot-signals-engine-job` off (the default), the job
  runs `hq sources sync`: it lands new source items and builds signals from
  them with Claude Code (`claude -p`), which must be installed and signed in on
  the computer whatever runtime the bot uses. It does not run `garden`.
- With the flag on, the job runs `hq signals run --trigger job`, which uses
  the main local bot's Claude or Codex login and runs `garden`
  (`core/scripts/ontology-garden.mjs`) before and after extraction.

To garden by hand on your own machine: `/run ontology garden --company {co}`.
When the bot job does not garden for the company, or the owner's computer
is not the right place, use one of the alternatives below.

### Alternative: `run: local` as a routine on the owner's Outpost

`/schedule` jobs run on the owner's Outpost, never as a timer on a laptop.
Start from `job.example.yaml` in this folder:

1. Copy it to `companies/{co}/jobs/ontology-garden.yaml` and fill `{company}`,
   `owner`, `timezone`, `created_at`.
2. `hq core jobs validate companies/{co}/jobs/ontology-garden.yaml`
3. `/schedule list` to confirm it is registered and probed.

### Alternative: `run: cloud` with a cloud agent

Use this when the owner's machine should not do the work (large sources, or
sources that only exist in the vault).

1. Provision a fleet agent with `/new-agent`, naming the company.
2. Grant it only what it needs, and nothing broader:
   - write on `ontology/`, `signals/`, `sources/{channel}/` for each source it runs;
   - read on `settings/knowledge/` if present.
   Never `--full` and never a `*` grant.
3. Verify every grant by readback before assigning work:
   ```bash
   hq files --company {co} acl ontology/ --json
   hq files --company {co} acl signals/ --json
   hq files --company {co} acl sources/{channel}/ --json
   ```
   Each must list the agent's `agt_…` id with `write`. Anything missing: stop.
4. Give the agent the same `job.example.yaml` prompt through `/schedule` on its
   own host, or dispatch it with `/delegate`.

A source marked `run: cloud` refuses to run locally: the worklist exits 4 with
"assigned to cloud agent" unless `--force` is passed. That stops the owner's
machine and the agent from processing the same items twice.

## Checks

```bash
bash core/scripts/tests/ontology-candidate.test.sh
bash core/scripts/tests/ontology-garden.test.sh
bash core/scripts/tests/ontology-audience-grant.test.sh
bash core/scripts/tests/ontology-source-worklist.test.sh
bash core/scripts/tests/ontology-brief.test.sh
```
