# ontology / garden

Promote a company's pending candidates into its local ontology and signal
stores. Run on a routine (local `/schedule` or a cloud agent) or by hand:
`/run ontology garden --company {co}`.

Spec: `core/knowledge/public/hq-core/ontology-local-spec.md`.

## Steps

1. **Resolve the company.** Take `--company` from the invocation. Never infer it
   from the working directory, and never touch another company's folders.
2. **Dry run first.**
   ```bash
   node core/scripts/ontology-garden.mjs --company {co} --dry-run --json
   ```
   If `candidates_processed` is 0, report "nothing to garden" and stop.
3. **Promote.**
   ```bash
   node core/scripts/ontology-garden.mjs --company {co} --json
   ```
   This is deterministic: identity-only entity files, audience-scoped signals and
   facts, stopword and type-conflict rejections to `ontology/_rejected/`, the
   daily `_index`, and the `.last-run` watermark. Running it twice changes
   nothing.
4. **Grant audiences (cloud-backed companies only).** For every `@{key}` folder
   created in this run, run `core/scripts/ontology-audience-grant.sh --company
   {co}`. It grants read to exactly the principals in `_audience.yaml` and reads
   every grant back. A failed readback stops the run; leave it for a human.
   Local-only companies skip this step.
5. **Review rejections.** Read today's `ontology/_rejected/{date}.jsonl`. For a
   `type-conflict`, decide whether the existing entity's type is wrong; if so,
   fix the entity file by hand and note it in the report. Never delete a
   rejection line.
6. **Report** in one line: entities created/updated, signals promoted, facts
   written, rejections, and grants applied.

## Rules

- Entity files hold identity only (name, type, aliases, counts, dates). Fact
  text goes to `ontology/facts/@{key}/`. Never copy a scoped fact into an
  entity file, the brief, or a company-audience folder.
- Never merge signals or facts across audience keys.
- Never widen an audience. A candidate with no audience is rejected, not
  defaulted to `company`.
- Do not edit `_candidates/_done/`; it is the audit trail.
