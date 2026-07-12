---
id: hq-no-grep-discovery
title: Never Grep for PRD or Worker Discovery
when: grep
on: [PreToolUse]
enforcement: hard
tier: 1
public: true
---

## Rule

Never use Grep to find `prd.json`, `worker.yaml`, or discover project/company/worker directories. This is hook-enforced — Grep calls with these patterns are blocked.

**Use instead:**
- **Project PRDs:** `qmd search "{name} prd.json" --json -n 5` → parse results → `Read` the file
- **Workers:** `Read core/workers/registry.yaml` → find path → `Read {path}/worker.yaml`
- **Companies:** `Read companies/manifest.yaml` — all companies listed there
- **Known exact path:** `Read companies/{co}/projects/{name}/prd.json` directly

Grep is for exact pattern matching in code (e.g. `import.*AuthService` with `glob: "*.ts"`), not for file discovery.

## Rationale

Same as Glob blocking: qmd and index files (`manifest.yaml`, `registry.yaml`) are the correct discovery tools. Grep for `prd.json` or `worker.yaml` patterns teaches the wrong habit and bypasses the indexed search system.
