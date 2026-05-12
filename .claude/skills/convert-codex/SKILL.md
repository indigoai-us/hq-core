---
name: convert-codex
description: Additive conversion for older Claude-first HQ roots so Codex has first-class AGENTS.md guidance, project mirrors, skill exposure, and OpenAI metadata without disrupting Claude Code behavior.
allowed-tools: Read, Write, Bash, Glob, Grep
---

# /convert-codex — Add Codex Parity to an HQ Root

Use this when an HQ filesystem predates Codex support or was primarily set up for Claude Code.

## Safety Contract

This skill is additive only.

- Create missing Codex-facing files and bridges.
- Leave existing files, directories, and symlinks untouched.
- Never replace `.agents/skills` when it already exists as a real directory.
- Never edit an existing `AGENTS.md` or `.codex/config.toml`.
- Pause for review if the user asks for a repair that requires modifying existing content.

## Procedure

1. Resolve the HQ root. Default to the current repository when `.claude/` and `core/core.yaml` are present.
2. Run the dry-run first unless the user explicitly requested `--apply`.
3. Review blocked items. Blocked means an existing path prevented a create-only repair.
4. Apply only when the plan contains create-only actions or the user has approved the blocked behavior.

## Commands

Preview the current root:

```bash
bash core/scripts/convert-codex.sh --dry-run
```

Repair the current root:

```bash
bash core/scripts/convert-codex.sh --apply
```

Repair a separate HQ root:

```bash
bash core/scripts/convert-codex.sh --root=/path/to/hq --apply
```

## Output

The script prints:

- create actions it would take or did take;
- already-safe paths;
- blocked paths that were left untouched;
- a compact Codex parity audit.

If blocked items appear, explain them clearly and stop before trying a more invasive repair.
