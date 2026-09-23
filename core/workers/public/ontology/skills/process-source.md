# ontology / process-source

Turn a declared source's new items into signal and entity candidates, scoped to
the people who were privy to each item. `garden` promotes them afterwards.

Invocation: `/run ontology process-source --company {co} --channel {channel} [--dry-run] [--force]`

Specs: `core/knowledge/public/hq-core/source-yaml-spec.md`,
`core/knowledge/public/hq-core/ontology-local-spec.md`.

## Steps

1. **Validate the source.** `bash core/scripts/source-yaml-validate.sh
   companies/{co}/sources/{channel}/source.yaml`. Invalid: stop and report the
   violations.
2. **Honour `run:`.** If the source says `run: cloud` and you are running on the
   owner's machine, stop with "assigned to cloud agent" unless `--force` was
   passed. The worklist script enforces this (exit 4).
3. **Get the worklist.**
   ```bash
   bash core/scripts/ontology-source-worklist.sh --company {co} --channel {channel} --limit 20
   ```
   Each line is either `{file, audience_key, audience}` or `{file, skip}`.
   - `skip: no-audience` — log it in the report and move on. Never process an
     item as `company` because its audience was missing.
   - For meetings, the audience comes from the attendee list on the file or,
     failing that, from the direct read grants on the item's vault key, which
     is how the meeting bot records who was on the call.
4. **Dry run** (`--dry-run`): for each item, print the file, its audience key,
   and the candidates you would write. Write nothing and mark nothing done.
5. **Extract.** For each item, read it and write at most 8 signal candidates
   and 8 entity candidates with `core/scripts/ontology-candidate.sh`, passing
   `--audience` as the item's audience joined by commas and
   `--source-ref {channel}:{file basename}`. Signals: decisions, commitments,
   risks, open questions, action items, key points. Entities: the people,
   projects, companies, and concepts the item names. One plain line each; no
   quotes longer than one sentence.
6. **Mark done** only after the item's candidates are written:
   `bash core/scripts/ontology-source-worklist.sh --company {co} --channel {channel} --mark-done <file>`.
7. **Report** in one line: items processed, skipped (with reasons), candidates
   written. Suggest running `garden` next, or run it when invoked with `--garden`.

## Rules

- The audience of every candidate is the item's audience. Never widen it, merge
  audiences across items, or copy scoped text into a company-audience file.
- Candidate capture switches (`signals_capture`, `ontology_capture`) apply here
  too; if the writer prints `disabled for {co}`, report it and stop.
- One company per run. Never read another company's sources.
