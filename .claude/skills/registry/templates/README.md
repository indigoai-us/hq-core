# Company Resource Registry

This folder is the shared inventory of a company's persistent infrastructure — repos, apps, services, databases, infra, and packages. It is **topology only** (what exists, why, who owns it, what depends on what). Credentials, endpoints, and local clone paths live in `companies/{co}/settings/resource-overrides/` (gitignored) — never in this folder.

## Layout

```
registry/
├── schema/resource.schema.yaml     Field spec (v1.0.0 — do not edit lightly)
├── resources/{id}.yaml             One file per resource (source of truth)
├── registry.yaml                   Auto-generated flat index — do NOT edit by hand
├── scripts/generate-index.sh       Regenerates registry.yaml
└── README.md                       This file
```

## Adding a resource

1. Create `resources/{id}.yaml`. Pick a kebab-case id of the form `{type}-{slug}` (e.g. `repo-api-server`, `app-marketing-site`, `db-primary-postgres`). Ids are globally unique within this registry and **never change** — other resources reference them.
2. Fill the required fields per `schema/resource.schema.yaml`: `id`, `name`, `type`, `purpose`, `owner`, `status`, `created_at`, `updated_at`. Optional: `dependencies`, `used_by`, `constraints`, `tags`, `repo_url`, `language`, `runtime`.
3. Update cross-references — add this id to the `used_by` or `dependencies` field of any related resource.
4. Regenerate the index:
   ```bash
   bash scripts/generate-index.sh
   ```

## Do not put here

- `op://` references, API keys, tokens, passwords
- Database connection strings or full URLs with auth
- Internal IP addresses, port assignments
- Environment variable values
- PEM blocks, private keys, certificates

These live in the matching local override at `companies/{co}/settings/resource-overrides/{id}.local.yaml` — gitignored, per-machine.

## Syncing across teammates

This folder rides the same reconciliation path as the rest of the company filesystem — `hq-sync` handles propagation. This folder is **not** its own git repo. Don't `git add` inside it; save your changes and `hq-sync` will bring them to the rest of the team on the next cycle.

## In-session helpers

When working inside HQ with Claude or Codex:

- The `registry` skill (`.claude/skills/registry/`) detects this folder, lists resources, and walks you through add/update/deprecate flows.
- `/sync-registry [company]` regenerates this registry's index. It never touches git.
- The `auto-capture-registry` hook writes stub entries for `gh repo create` and `vercel deploy` events when the company declares `github_org` / `vercel_team` in `companies/manifest.yaml`.
