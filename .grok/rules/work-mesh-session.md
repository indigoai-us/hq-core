# Grok adapter — work mesh session loop

Grok-only. When this HQ session has a company bound and the user is doing
substantive work, call the helper. Do not paraphrase. Do not ask the user to
create a task.

The live Board is work-mesh `stories[]` (`id`, `title`, `status`). Local
`prd.json` `passes` is not the Board — never orient from it.

Before reading any `prd.json` for task status, read
`.claude/state/work-mesh-board` if it exists (written each prompt by the
ground hook). That snapshot is source of truth. Local prd is spec only
when that file is missing.

```bash
bash core/scripts/work-mesh-session.sh ground --company {slug} --prompt "{user request}" --json
# If they named a project (stories[] is the Board):
bash core/scripts/work-mesh-session.sh ground --company {slug} --project {project} --json
# Fallback Board read:
bash core/scripts/work-mesh.sh check --company {slug} --project {project} --json
# Cache: ~/.hq/work-mesh/cache/projects/{companyUid}/{project}.json
# After the user picks a Board row — session is presence, do NOT report --task-title for orientation:
bash core/scripts/work-mesh-session.sh report --company {slug} --project {project} --task {id} --status doing
# Progress (no column change unless --status is set):
bash core/scripts/work-mesh-session.sh report --company {slug} --project {project} --summary "{milestone}"
# Stop:
bash core/scripts/work-mesh-session.sh report --company {slug} --project {project} --task {id} --status done
```

`--create` requires `--confirm` and creates a Board *project*, never a
company folder. `HQ_WORK_MESH_DISABLED=1` no-ops.
Session is presence. Task is the Board row. Tenant: only the bound company.
Never mkdir `companies/<slug>`. Never run `/newcompany` or designate a
tenant from filler. Company is the session bind (or a manifest slug the
user named as a whole token). If the company is unknown, ask — do not
invent one from the first word of the prompt ("ok …" is not a company).
