# Work Mesh Live — trusted bind (US-011)

Before the first tool call that does project work, bind this session explicitly.
Do **not** rely on prompt classifiers or `auto-session-project`.

## Steps (in order)

1. Resolve `{co}` (company slug), `{project}` (project id/slug), and `{task}` when known.
2. Write session meta **and** reconcile with trusted context in one call:

```bash
bash core/scripts/work-mesh-live-bind-trusted.sh \
  --company "{co}" --project "{project}" --task "{task}"
```

That helper runs `hq-session.sh set` for `company_slug` / `project` / `task` (writes
`workspace/sessions/<sid>/meta.yaml`) then detaches
`hq mesh context reconcile` with `observation.trustedContext`
(there is no `--trusted` CLI flag).

Or equivalently: write an observation JSON with `trustedContext.{companySlug,project,task}`
and run `hq mesh context reconcile --observation-file <path> --machine` detached after
the `hq-session.sh set` calls.

Skip company bind only when the skill truly has no company (rare). Skip task when unknown.
