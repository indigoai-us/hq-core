---
description: Scaffold a new company with full infrastructure
allowed-tools: Read, Write, Edit, Bash, AskUserQuestion
argument-hint: [company-slug]
visibility: public
---

# /newcompany - Company Scaffolding

Create a new company with complete infrastructure in one operation.

**Args:** $ARGUMENTS

## Process

### 1. Get Company Slug

If no args, ask: "Company slug (lowercase, hyphens only)?"
Validate: no spaces, lowercase only, hyphens allowed, doesn't already exist in `companies/manifest.yaml`.

### 2. Interactive Setup

Ask (batch):
1. Company name (human-readable)?
2. GitHub org? (if any, or "none")
3. Existing repos to associate? (paths or "none")
4. Settings needed? (API keys, credentials — or "none for now")
5. Existing workers to assign? (or "none")

### 3. Scaffold Directory

```bash
mkdir -p companies/{slug}/{settings,data}
mkdir -p companies/{slug}/workspace/sessions
printf '# HQ workspace mirror — sessions are gitignored, index.jsonl is committed\nsessions/\n' \
  > companies/{slug}/workspace/.gitignore
: > companies/{slug}/workspace/index.jsonl
```

The `workspace/` directory is the per-company audit trail of HQ sessions that
touch this company. Sessions are hardlinked here from `workspace/threads/` by
the mirror hook (`mirror-thread-to-company.sh`); the `index.jsonl` audit log is
committed to git, individual session JSONs are gitignored.

### 4. Create Knowledge Repo

```bash
mkdir -p repos/private/knowledge-{slug}
cd repos/private/knowledge-{slug}
git init
echo "# {Name} Knowledge\n\nKnowledge base for {Name}." > README.md
git add -A && git commit -m "init: knowledge base"
```

Create symlink:
```bash
ln -s ../../repos/private/knowledge-{slug} companies/{slug}/knowledge
```

### 5. Update Registries

**manifest.yaml**: Add entry with ALL fields populated (no nulls):
```yaml
{slug}:
  prefix: {auto-computed}
  github_org: {org or omit}
  repos: [{repo paths or empty array}]
  settings: [{setting names or empty array}]
  workers: [{worker ids or empty array}]
  knowledge: companies/{slug}/knowledge/
  deploy: []
  vercel_projects: []
  qmd_collections: [{slug}]
```

**Compute `prefix`** before writing the entry:
1. Strip hyphens from `{slug}`, lowercase, take first 3 chars (e.g. `acme-corp` → `acm`).
2. Read existing prefixes: `python3 -c "import yaml; d=yaml.safe_load(open('companies/manifest.yaml')); print('\n'.join(v.get('prefix','') for v in d['companies'].values()))"`.
3. If your candidate collides, fall back to first 4 chars (no hyphens). If still collides, append `-2`, `-3`, ….
4. Surface the chosen prefix in the final report so the user notices any non-default fallback.
5. The `auto-mirror-company-skill` PostToolUse hook uses this prefix to bridge top-level skills/commands at `.claude/skills/{prefix}-{name}/` and `.claude/commands/{prefix}-{name}.md` — see `.claude/policies/company-skill-bridge.md`.

**modules.yaml**: Add knowledge module entry:
```yaml
- name: knowledge-{slug}
  repo: local
  branch: main
  strategy: link
  access: team
  paths:
    .: companies/{slug}/knowledge
```

### 6. Create qmd Collection

```bash
qmd collection add companies/{slug}/knowledge --name {slug} --mask "**/*.md"
qmd update 2>/dev/null || true
```

### 7. Write Company README

Write `companies/{slug}/README.md` with company overview (name, purpose, repos, workers).

### 8. Update Companies List

If CLAUDE.md `## Companies` line doesn't include the new slug, update it.

### 9. Reindex + Report

```bash
qmd update 2>/dev/null || true
```

Report:
```
Company {slug} scaffolded:
  Directory: companies/{slug}/
  Knowledge: companies/{slug}/knowledge/ → repos/private/knowledge-{slug}
  Manifest: updated (prefix: {chosen-prefix})
  Modules: updated
  qmd: collection "{slug}" created
```

## Rules

- All fields in manifest.yaml must be non-null (use empty arrays `[]`, not `null`)
- Knowledge repo is mandatory — always create one
- Always update manifest.yaml, modules.yaml, and qmd in same operation
- Never create a company that already exists in manifest
- Validate slug: lowercase, hyphens only, no spaces
