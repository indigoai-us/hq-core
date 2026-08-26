# Grok adapter — work mesh session loop

Grok-only. When this HQ session has a company bound and the user is doing
substantive work, call the helper. Do not paraphrase. Do not ask the user to
create a task.

```bash
bash core/scripts/work-mesh-session.sh ground --company {slug} --prompt "{user request}" --json
# If they named a project:
bash core/scripts/work-mesh-session.sh ground --company {slug} --project {project} --json
# After bind:
bash core/scripts/work-mesh-session.sh report --company {slug} --project {project} --task-title "{gist}" --status doing
# Progress:
bash core/scripts/work-mesh-session.sh report --company {slug} --project {project} --summary "{milestone}"
# Stop:
bash core/scripts/work-mesh-session.sh report --company {slug} --project {project} --status done
```

`--create` requires `--confirm`. `HQ_WORK_MESH_DISABLED=1` no-ops.
Session is presence. Task is the Board row. Tenant: only the bound company.
