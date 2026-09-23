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

Check with `bash core/scripts/knowledge-prefs.sh get {co} signals_capture`.

## Where it runs

Each source picks its runtime with `run:` in its `source.yaml`. Session-close
candidates are gardened by whichever runtime runs `garden` for the company.

### `run: local` — a routine on the owner's Outpost

`/schedule` jobs run on the owner's Outpost, never as a timer on a laptop.
Start from `job.example.yaml` in this folder:

1. Copy it to `companies/{co}/jobs/ontology-garden.yaml` and fill `{company}`,
   `owner`, `timezone`, `created_at`.
2. `bash core/scripts/jobs-validate.sh companies/{co}/jobs/ontology-garden.yaml`
3. `/schedule list` to confirm it is registered and probed.

For a one-off run on your own machine: `/run ontology garden --company {co}`.

### `run: cloud` — a cloud agent

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
