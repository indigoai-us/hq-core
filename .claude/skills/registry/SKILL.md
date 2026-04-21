---
name: registry
description: Detect and work with a company's resource registry — check what exists before creating, update after creating or changing a resource. The registry lives as a local folder inside the company (`companies/{co}/registry/`) and is reconciled across machines by hq-sync, not git.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash(qmd:*), Bash(ls:*), Bash(yq:*), Bash(cat:*), Bash(date:*), Bash(bash:*), Bash(gh:*), Bash(grep:*)
---

# Company Resource Registry

A company's resource registry is the shared inventory of its persistent infrastructure (repos, apps, services, databases, infra, packages). This skill teaches HQ to:

1. **Detect** whether the active company has a registry.
2. **Reference** it before creating new resources (avoid duplicates, understand topology).
3. **Update** it when resources are created, renamed, or deprecated.

**User's argument:** $ARGUMENTS — one of: `check`, `list`, `show <id>`, `add`, `update <id>`, `deprecate <id>`, `help`. Default when no arg: `check`.

---

## Core concept

A registry is a **plain folder inside the company directory** containing YAML topology files — one file per resource plus an auto-generated index. The folder is provisioned by the HQ installer when a company is created and kept in sync across machines by `hq-sync` (the same mechanism that syncs the rest of the company filesystem). The skill never touches git.

**Registry layout** (inside a company folder):

```
companies/{co}/registry/
├── schema/resource.schema.yaml     # Field spec, version 1.0.0
├── resources/{id}.yaml             # One file per resource (source of truth)
├── registry.yaml                   # Auto-generated flat index (don't edit by hand)
├── scripts/generate-index.sh       # Regenerates registry.yaml
└── README.md                       # Registry-level notes
```

**Companion HQ paths:**

- `companies/{co}/settings/resource-overrides/` — gitignored; per-machine credentials/paths (the **only** place `op://` refs, endpoints, or local clone paths live)
- `companies/manifest.yaml` → company entry has `registry: companies/{co}/registry` when declared

---

## Step 1 — Detect the registry

Determine the active company from context (cwd, recent edits, user's message). Then check in order:

```bash
# 1. Manifest declaration (soft hint)
yq ".companies.\"{co}\".registry // \"none\"" companies/manifest.yaml

# 2. Physical folder (authoritative)
[ -d "companies/{co}/registry" ] && echo "FOUND" || echo "MISSING"
```

Outcomes:

- **Folder exists** → registry is active. Continue.
- **Manifest declares it but folder is missing** → `hq-sync` hasn't reconciled yet on this machine. Report `"Registry declared for {co} but not present locally — run hq-sync, or ask the installer to reprovision the company filesystem."` and stop.
- **Neither** → no registry for this company. Report `"No registry for {co} — see Step 6 to bootstrap one if desired."` and stop unless the user explicitly asks to create one.

If the folder exists, verify the index is present:

```bash
[ -f companies/{co}/registry/registry.yaml ] || echo "MISSING_INDEX — regenerate with: cd companies/{co}/registry && bash scripts/generate-index.sh"
```

---

## Step 2 — Reference (read) the registry

### 2a. List all resources

```bash
yq '.resources[] | "  " + .id + " — " + .name + " (" + .type + ", " + .status + ")"' \
  companies/{co}/registry/registry.yaml
```

Flat table: id, name, type, status. Answers "what do we have?" without loading every full YAML.

### 2b. Look up by type or tag

```bash
# All active repos
yq '.resources[] | select(.type == "repo" and .status == "active") | .id' \
  companies/{co}/registry/registry.yaml

# Full details for a single resource
cat companies/{co}/registry/resources/{id}.yaml
```

### 2c. Search semantically (if qmd-indexed)

If the registry has a qmd collection declared in the company's `qmd_collections` list, use qmd:

```bash
qmd search "<query>" -c {co}-registry --json -n 10
qmd vsearch "<concept>" -c {co}-registry --json -n 10
```

Use qmd when the user asks conceptually ("what handles auth?", "any vector DBs?"). Use `yq`/`Read` when you have a specific id or type filter.

### 2d. Inspect local override (if exists)

When you need access details (credentials, endpoints, local paths), read the **local override**, not the shared topology:

```bash
ls companies/{co}/settings/resource-overrides/{id}.local.yaml 2>/dev/null && \
  cat companies/{co}/settings/resource-overrides/{id}.local.yaml
```

Override files are gitignored. They're the **only** place `op://` refs, endpoints, or local clone paths live.

---

## Step 3 — Before creating a new resource (pre-flight check)

When the user asks you to create a new repo, app, service, database, or infra component, **first check the registry**:

1. List resources of that type: `yq '.resources[] | select(.type == "{type}") | .name' companies/{co}/registry/registry.yaml`
2. Search for similar names: `grep -ri "{keyword}" companies/{co}/registry/resources/`
3. If a match exists: report it and ask whether to reuse, fork, or genuinely create new. Do not silently duplicate.

**Why this matters:** Registries drift from reality when new resources get created without being registered. The pre-flight check is the counter-force — every creation event funnels through registry awareness.

---

## Step 4 — Update (add / modify / deprecate)

### 4a. Add a new resource

1. **Pick an id.** Convention: `{type}-{slug}` (e.g. `repo-my-service`, `app-marketing-site`, `db-primary-postgres`). Kebab-case, globally unique across the registry.
2. **Read the schema** at `companies/{co}/registry/schema/resource.schema.yaml` — confirm current field spec.
3. **Write** `companies/{co}/registry/resources/{id}.yaml` with required fields:
   - `id`, `name`, `type` (enum: repo/app/service/infra/database/ai/package), `purpose` (1-2 sentences)
   - `owner`, `status` (active/deprecated/planned)
   - `created_at`, `updated_at` (YYYY-MM-DD or ISO)
   - `dependencies: []`, `used_by: []`, `constraints: []`, `tags: []` (optional, default empty)
   - Type-specific: `repo_url`, `language`, `runtime` (include when known)
4. **Forbidden fields in topology**: `op://` refs, API keys, passwords, connection strings, IP:port, private keys, `ghp_`/`xoxb-` tokens. If you need to capture credentials, write them to `companies/{co}/settings/resource-overrides/{id}.local.yaml` instead.
5. **Update cross-refs** on related resources — add this id to their `used_by` or `dependencies` list.
6. **Regenerate the index:**
   ```bash
   cd companies/{co}/registry && bash scripts/generate-index.sh
   ```
7. **That's it.** The file sits in the company filesystem; `hq-sync` reconciles it across teammates' machines on the next sync cycle. No git commit, no push — the registry is not a standalone repo.

### 4b. Update an existing resource

- Edit the specific `resources/{id}.yaml`. Bump `updated_at` to today.
- If the change alters cross-references (renames, new deps), update affected resources' `used_by` / `dependencies`.
- Regenerate the index.

### 4c. Deprecate a resource

- Change `status: active` → `status: deprecated`. Bump `updated_at`.
- Optionally add a `constraints` note: `"Scheduled for removal {date} — use {replacement-id} instead."`
- Remove the deprecated id from other resources' `dependencies` lists (direct deps must resolve to active resources).
- Regenerate the index.

### 4d. Delete (rare)

Only delete when the resource **never existed** (phantom entry) or was fully removed from infrastructure with no history value. Otherwise prefer `status: deprecated`. If deleting, also grep for the id across `resources/` and remove it from any `dependencies`/`used_by` lists, then regenerate the index.

---

## Step 5 — Sync (hands-off)

The registry folder is part of the company filesystem. Cross-machine sync is handled by `hq-sync` — the same mechanism that reconciles everything else under `companies/{co}/`. This skill does **not** run git commands, push, pull, or commit.

**What this means in practice:**

- After you edit a resource, save the file and regenerate the index. You're done.
- A teammate's next `hq-sync` pull will bring your changes to their machine.
- Conflict resolution (if two teammates edit the same file between syncs) happens inside `hq-sync`, not here.
- If something looks stale on your machine, run the standard `hq-sync` command — the skill has no say in how or when that runs.

If you ever see a `companies/{co}/registry/.git/` directory, you're on a legacy setup (pre-migration). Treat it as read-only for this skill; migration out of the separate-repo model is a one-time operation.

---

## Step 6 — Bootstrap a registry for a new company (rare, on request)

If the active company has no registry and the user wants one, use the templates that ship with this skill:

1. **Confirm scope.** Registries are valuable when a company has ≥3 shared resources AND ≥2 teammates. Single-person companies usually don't need one yet.
2. **Create the folder structure and copy the templates:**
   ```bash
   mkdir -p companies/{co}/registry/{schema,resources,scripts}
   cp .claude/skills/registry/templates/resource.schema.yaml companies/{co}/registry/schema/
   cp .claude/skills/registry/templates/generate-index.sh    companies/{co}/registry/scripts/
   cp .claude/skills/registry/templates/README.md            companies/{co}/registry/
   chmod +x companies/{co}/registry/scripts/generate-index.sh
   ```
3. **Declare in manifest** — add `registry: companies/{co}/registry` to the company's entry in `companies/manifest.yaml`. If the company also has a GitHub org or Vercel team that should drive auto-capture, set `github_org:` / `vercel_team:` on the same entry.
4. **Populate initial resources** — one YAML under `resources/` per existing repo/app/service the company operates.
5. **Generate the index:**
   ```bash
   cd companies/{co}/registry && bash scripts/generate-index.sh
   ```
6. **(Optional) Add a qmd collection** for semantic search — add `{co}-registry` to the company's `qmd_collections` list in `companies/manifest.yaml`, then run `qmd update`.

No separate git repo, no pre-commit hook, no branch protection — the registry lives in the company filesystem and inherits its sync mechanism.

---

## Step 7 — Auto-capture awareness

Some events trigger automatic resource capture via `.claude/hooks/auto-capture-registry.sh`:

| Event | Hook action |
|---|---|
| `gh repo create` with a known company org | Writes `companies/{co}/registry/resources/repo-{name}.yaml` stub + regenerates index |
| `vercel deploy` with a known company scope | Writes/updates `companies/{co}/registry/resources/vercel-{project}.yaml` + regenerates index |

Auto-captured stubs have `purpose: "Auto-captured — update this description"` and tag `auto-captured`. **After auto-capture, enrich the stub** — fill in purpose, owner, dependencies, constraints. Unresolved stubs rot the registry.

Hooks are gated to `HQ_HOOK_PROFILE=standard` (not minimal). Failures are non-blocking. Matching is manifest-driven: the hook resolves the active company by looking up `companies.{co}.github_org` or `companies.{co}.vercel_team` and only writes if that company declares `registry:` in the manifest.

---

## Decision guide — when to invoke this skill

| Signal | Action |
|---|---|
| User says "what repos/apps/services does {co} have?" | Step 2a/2c (list/search) |
| User asks to create a new repo/app/service/DB | Step 3 (pre-flight) → then normal creation → Step 4a (register) |
| User renames or deprecates a resource | Step 4b/4c |
| After `gh repo create` or `vercel deploy` | Check if auto-capture fired; enrich stub |
| User asks "how do we access {resource}?" | Step 2d (read local override — never leak shared topology with creds) |
| User asks to bootstrap a registry for a new company | Step 6 |

---

## Rules

- **Never write secrets into the shared topology.** Credentials, endpoints, and local paths live only in `companies/{co}/settings/resource-overrides/` (gitignored). Mixing them into `resources/*.yaml` is the failure mode the topology/overrides split is designed to prevent.
- **One file per resource.** Never merge multiple resources into one YAML (breaks cross-references, makes diffs noisy, causes sync conflicts).
- **Kebab-case ids, globally unique.** Never change an id after creation — downstream resources reference it.
- **`registry.yaml` is derived.** Don't edit it by hand — always regenerate via `scripts/generate-index.sh`.
- **No git in this skill.** The registry is a folder synced by `hq-sync`, not a standalone repo. Don't `git add`, `git commit`, `git push`, or run `/sync-registry` from this skill — they don't apply.
- **Registry is authoritative over manifest for resource detail.** If `manifest.yaml` says a repo exists but the registry doesn't, either the registry is stale (register it) or the manifest is stale (remove it). Resolve the gap, don't ignore it.
- **When a company has no registry, say so.** Don't invent one or fall back to manifest as a substitute.
