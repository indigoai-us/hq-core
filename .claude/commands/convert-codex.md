---
description: Additive conversion for older Claude-first HQ roots so Codex has first-class local files, skills, and project mirrors
allowed-tools: Read, Write, Bash, Glob, Grep
argument-hint: "[--dry-run] [--apply] [--root=<path>] [--no-skill-sync] [--no-openai-yaml]"
visibility: public
---

# /convert-codex — Repair Codex Parity for an HQ Root

Add Codex-facing files and bridges to an existing HQ that was originally built around Claude Code.

**Args:** $ARGUMENTS

## Default

Run a dry-run unless the user explicitly passes `--apply`:

```bash
bash scripts/convert-codex.sh $ARGUMENTS
```

## What It Adds

- `AGENTS.md` when missing.
- `.codex/config.toml` when missing.
- `.codex/claude` bridge to `.claude/`.
- `.codex/prompts` bridge to `.claude/commands/`.
- `.agents/skills` exposure for Codex skills.
- Missing `agents/openai.yaml` metadata for existing skills.

## Safety Rules

- Do not overwrite existing files.
- Do not replace an existing `.agents/skills` directory with a symlink.
- If `.agents/skills` already exists as a real directory, only add missing skill folders.
- If a requested repair requires changing existing content, stop and ask before proceeding.

## Common Runs

Preview:

```bash
bash scripts/convert-codex.sh --dry-run
```

Repair current root:

```bash
bash scripts/convert-codex.sh --apply
```

Repair another HQ root:

```bash
bash scripts/convert-codex.sh --root=/path/to/hq --apply
```
