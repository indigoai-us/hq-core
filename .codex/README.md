# Codex Hooks

HQ enables Codex lifecycle hooks through `.codex/config.toml` and routes them
through `.codex/hooks/hq-codex-hook-adapter.sh`.

The adapter keeps hook policy centralized in `.claude/hooks/`:

- `SessionStart` injects HQ policy context.
- `PreToolUse` enforces Bash secret detection, active-run coordination, and
  protected-core checks for `apply_patch` edits.
- `PostToolUse` forwards checkpoint and registry-capture nudges back to Codex
  as hook context.
- `Stop` runs the existing pattern-observation hook and surfaces its output as
  a Codex system message.

Codex hook coverage is a guardrail, not a complete security boundary. Codex can
intercept Bash, `apply_patch`, and MCP tool calls, but not every possible tool
path. Keep critical policies in deterministic scripts and CI gates as well.
