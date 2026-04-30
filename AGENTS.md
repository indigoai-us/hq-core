# HQ for Codex

This repository is an HQ filesystem. Codex should treat it as a working personal OS with Claude-era source material and Codex-facing bridges.

## Orientation
- Canonical HQ commands, skills, hooks, and policies live under `.claude/`.
- Codex skills are exposed through `.agents/skills`.
- Codex project references live under `.codex/`.
- Prefer additive repairs. Do not replace user content or remove Claude Code support.

## Safety
- Preserve existing behavior for Claude Code users.
- When adding Codex parity, create missing files and bridges without overwriting existing paths.
- If a repair requires editing existing content instead of adding new content, pause for review.

## Hook Intent
- Claude Code hooks live in `.claude/hooks/`; Codex does not run them automatically.
- Before high-risk work, apply their intent manually: scope searches, protect `core.yaml.rules.locked`, check active-run ownership before repo edits, avoid secrets, and read relevant policy digests.
- Use `scripts/codex-preflight.sh` for explicit checks before risky searches, edits, shell commands, or repo work.
- See `docs/codex-hook-porting.md` for the hook-by-hook porting decision.
