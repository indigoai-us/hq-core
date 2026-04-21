---
description: Regenerate a company's resource-registry index (registry.yaml) from its resources/*.yaml files
allowed-tools: Bash, Read
argument-hint: [company-slug]
visibility: public
---

# /sync-registry — Regenerate registry index

Regenerates `companies/{co}/registry/registry.yaml` from the per-resource YAMLs in `companies/{co}/registry/resources/`. The registry is a plain folder synced across machines by `hq-sync` — this command does **not** push, pull, commit, or touch git. It only makes sure the flat index matches the per-resource files.

**Args:** $ARGUMENTS — optional company slug. If omitted, resolved from cwd/context.

## 1. Resolve active company

1. If an arg was provided and matches a key under `companies.*` in `companies/manifest.yaml`, use that.
2. Otherwise, infer from cwd: if `$(pwd)` starts with `companies/{slug}/`, use `{slug}`.
3. Otherwise, read `workspace/threads/handoff.json` and use the last company touched, if any.
4. Otherwise, report: `"Couldn't resolve active company. Pass one as an argument: /sync-registry my-co"` and stop.

## 2. Verify the registry exists

```bash
REG_DIR="companies/{co}/registry"
[ -d "$REG_DIR" ] || { echo "No registry at $REG_DIR"; exit 1; }
[ -x "$REG_DIR/scripts/generate-index.sh" ] || { echo "$REG_DIR/scripts/generate-index.sh not found or not executable"; exit 1; }
```

If missing:
- Folder doesn't exist → suggest bootstrapping with the `registry` skill (`.claude/skills/registry/SKILL.md` Step 6).
- Script missing → suggest copying `scripts/generate-index.sh` from the skill's templates (`.claude/skills/registry/templates/generate-index.sh`).

## 3. Regenerate the index

```bash
cd "$REG_DIR" && bash scripts/generate-index.sh
```

The script prints `Indexed: N resource(s)` on success.

## 4. Report

Summarize:

```
Registry index regenerated
  Company:   {co}
  Path:      {REG_DIR}/registry.yaml
  Resources: {count}
```

Cross-machine sync happens via `hq-sync`, independent of this command. No git actions are run.

---

## Rules

- **No git.** The registry is a plain folder in the company filesystem. Never `git add`, `git commit`, `git push`, or `git pull` from this command.
- **Per-company.** Always scope to one company at a time. Don't walk all companies looking for registries.
- **Non-destructive.** The generator script never touches `resources/*.yaml` — it only rewrites `registry.yaml`. Safe to run repeatedly.
