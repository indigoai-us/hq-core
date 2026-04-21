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
```

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
  github_org: {org or omit}
  repos: [{repo paths or empty array}]
  settings: [{setting names or empty array}]
  workers: [{worker ids or empty array}]
  knowledge: companies/{slug}/knowledge/
  deploy: []
  vercel_projects: []
  qmd_collections: [{slug}]
```

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
  Manifest: updated
  Modules: updated
  qmd: collection "{slug}" created
```

## Rules

- All fields in manifest.yaml must be non-null (use empty arrays `[]`, not `null`)
- Knowledge repo is mandatory — always create one
- Always update manifest.yaml, modules.yaml, and qmd in same operation
- Never create a company that already exists in manifest
- Validate slug: lowercase, hyphens only, no spaces
