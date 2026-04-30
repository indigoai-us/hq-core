# Codex Hook Porting Decision

Status: accepted
Date: 2026-04-30

## Decision

Do not wire Claude Code hooks directly into Codex. Keep `.claude/hooks/` as the existing Claude lifecycle implementation, and port the hook intent into Codex through three additive surfaces:

1. **Instruction parity** in `AGENTS.md` for rules Codex can follow before acting.
2. **Skill/command preflight checks** for rules that can be evaluated before a Codex workflow mutates files or runs shell commands.
3. **Future Codex hook runner** only if Codex exposes a stable project hook lifecycle with stdin schemas comparable to Claude Code.

This avoids breaking Claude Code while still making the safety model visible and executable for Codex.

## Why Not Direct Reuse

Claude hooks are event driven. They expect Claude-specific lifecycle events such as `PreToolUse`, `PostToolUse`, `SessionStart`, `Stop`, `PreCompact`, and `UserPromptSubmit`, plus JSON fields like `tool_name`, `tool_input`, `cwd`, `session_id`, and `transcript_path`.

Codex does not currently consume `.claude/settings.json#hooks` or run those event hooks automatically from the repo. Directly copying hook settings into `.codex` would create a false sense of enforcement.

## Porting Matrix

| Hook | Current Claude event | Codex port | Rationale |
|---|---:|---|---|
| `block-hq-glob.sh` | `PreToolUse` | Instruction parity + skill preflight | Codex should avoid broad root searches and use scoped `rg`/read operations. |
| `block-hq-grep.sh` | `PreToolUse` | Instruction parity + skill preflight | Same intent as above; prevent expensive or low-signal discovery. |
| `detect-secrets.sh` | `PreToolUse` | Skill preflight before shell commands | Codex cannot be intercepted automatically here, but workflows can scan commands before execution. |
| `protect-core.sh` | `PreToolUse` | Skill preflight before edits | Preserve core lock intent; do not make it an automatic repo mutation hook yet. |
| `block-on-active-run.sh` | `PreToolUse` | Skill preflight before repo edits | Use `scripts/repo-run-registry.sh` when a Codex workflow plans to edit under `repos/`. |
| `block-inline-story-impl.sh` | `PreToolUse` | Instruction parity | Codex should avoid story implementation outside orchestrated execution unless explicitly requested. |
| `warn-cross-company-settings.sh` | `PreToolUse` | Instruction parity + optional preflight | Warns are useful, but automatic enforcement would be too noisy without tool interception. |
| `inject-local-context.sh` | `SessionStart` | `AGENTS.md` orientation + manual context load | Codex can read manifest/profile files when needed; automatic injection is lifecycle-specific. |
| `load-policies-for-session.sh` | `SessionStart` | Skill preflight + AGENTS instruction | Codex skills should read relevant policy digests before high-risk work. |
| `check-repo-active-runs.sh` | `SessionStart` | Skill preflight | Codex can check active-run registry before editing a repo. |
| `check-claude-desktop-bridge-health.sh` | `SessionStart` | Claude-only | This diagnoses Claude Desktop bridge state. No Codex equivalent. |
| `rewrite-resume-sentinel.sh` | `UserPromptSubmit` | Codex-only future behavior if needed | It fixes a Claude resume prompt issue; do not port unless Codex shows the same failure mode. |
| `auto-checkpoint-trigger.sh` | `PostToolUse` | Future Codex session automation | Useful intent, but depends on tool-event stream and session ids. |
| `auto-capture-registry.sh` | `PostToolUse` | Future Codex session automation | Useful after `gh repo create` or deploy commands, but requires command-output observation. |
| `screenshot-resize-trigger.sh` | `PostToolUse` | Future Codex browser/image workflow | Codex image handling differs; keep as Claude hook until there is a concrete Codex need. |
| `context-warning-60.sh` | `Stop` | Codex app/runtime responsibility | Codex context management is not driven by Claude transcript file size. |
| `observe-patterns.sh` | `Stop` | Future retrospective skill | Better as explicit `/retro` or `/learn` style workflow in Codex. |
| `cleanup-mcp-processes.sh` | `Stop` | Future cleanup command | Codex process ownership differs; do not kill processes without a Codex-specific owner model. |
| `auto-checkpoint-precompact.sh` | `PreCompact` | Codex app/runtime responsibility | Claude autocompact lifecycle does not map directly. |
| `hook-gate.sh` | Hook router | Keep for Claude, reuse profile taxonomy | The profile concept is useful; the runner itself is Claude hook infrastructure. |

## Immediate Codex Rules

Codex should apply these rules in HQ work:

- Prefer scoped `rg` or direct reads over broad root searches.
- Read relevant policy digests before high-risk edits.
- Check active-run ownership before editing files under `repos/`.
- Treat `core.yaml.rules.locked` as protected unless the user explicitly asks for a core update.
- Do not read or print secrets from local credential files.
- Use existing HQ scripts and structured files instead of inventing alternate state.

## Explicit Preflight Script

The additive implementation is `scripts/codex-preflight.sh`, which supports explicit checks:

```bash
scripts/codex-preflight.sh search --pattern "..." --path "..."
scripts/codex-preflight.sh edit --file "..."
scripts/codex-preflight.sh bash --command "..."
scripts/codex-preflight.sh repo --path "..."
scripts/codex-preflight.sh policies --cwd "$PWD"
```

That script should call or reuse the existing hook scripts where the stdin schema can be synthesized safely. It should never modify `.claude/settings.json`, never install automatic hooks, and never claim automatic enforcement.
