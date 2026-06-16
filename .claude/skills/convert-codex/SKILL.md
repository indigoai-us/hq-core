---
name: convert-codex
description: Add Codex support to older Claude-first HQ roots without breaking Claude setup.
allowed-tools: Read, Write, Bash, Glob, Grep
---

# /convert-codex — Repair Codex Parity for an HQ Root

Add Codex-facing files and bridges to an existing HQ that was originally built around Claude Code.

**Args:** $ARGUMENTS

## Default

Run a dry-run unless the user explicitly passes `--apply`:

```bash
bash core/scripts/convert-codex.sh $ARGUMENTS
```

## What It Adds

- `AGENTS.md` when missing.
- `.codex/config.toml` when missing.
- `.codex/claude` bridge to `.claude/`.
- `.codex/output-style.md` bridge to the active `.claude/output-styles/` file.
- `.agents/skills` exposure for Codex skills (replaces the legacy `.codex/prompts` → `.claude/commands/` bridge — commands tree is gone).
- Missing `agents/openai.yaml` metadata for existing skills.

## Safety Rules

- Do not overwrite existing files.
- Do not replace an existing `.agents/skills` directory with a symlink.
- If `.agents/skills` already exists as a real directory, only add missing skill folders.
- If a requested repair requires changing existing content, stop and ask before proceeding.

## Common Runs

Preview:

```bash
bash core/scripts/convert-codex.sh --dry-run
```

Repair current root:

```bash
bash core/scripts/convert-codex.sh --apply
```

Repair another HQ root:

```bash
bash core/scripts/convert-codex.sh --root=/path/to/hq --apply
```
