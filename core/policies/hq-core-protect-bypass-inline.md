---
id: hq-core-protect-bypass-inline
title: Core Protection Bypass Requires Inline Env Var
scope: global
trigger: when editing locked core files (core/core.yaml locked list)
enforcement: hard
tier: 1
version: 2
created: 2026-04-12
updated: 2026-04-22
source: session-learning
public: true
---

## Rule

The `HQ_BYPASS_CORE_PROTECT=1` env var must be passed **inline** with the command that modifies the file (e.g., `HQ_BYPASS_CORE_PROTECT=1 sed -i '' '...' .claude/CLAUDE.md`). Setting it via `export` in a prior Bash tool call has no effect — each hook runs in its own subprocess spawned by the harness, not from prior shell sessions.

**Neither Write nor Edit can carry the bypass.** The PreToolUse core-protect hook only observes env vars on Bash invocations; the same vars attached to a Write or Edit call are ignored and the edit is blocked. When the locked target is `core/scripts/`, `.claude/hooks/`, `.claude/CLAUDE.md`, or `.claude/settings.json`, write via Bash using one of:

1. `sed -i '' '...'` for line-anchored single-file edits
2. `cat > file <<'EOF' ... EOF` heredoc for whole-file rewrites
3. `python3 -c` with anchor-based `str.replace` for surgical multi-line edits

All three must have `HQ_BYPASS_CORE_PROTECT=1` prefixed inline on the same Bash call.

## Rationale

Session 2026-04-12: attempted `export HQ_BYPASS_CORE_PROTECT=1` followed by Edit tool — blocked three times. Bash tool calls don't share shell state. Hooks inherit from the harness process environment, not from user shell sessions. Inline env var on a Bash command is the only reliable bypass path.

Session 2026-04-22: confirmed Write tool is also blocked under the same conditions (bypass env vars on non-Bash tools are silently ignored by the PreToolUse hook). Added explicit write-path recipes so the next agent doesn't re-discover this by trial-and-error.
