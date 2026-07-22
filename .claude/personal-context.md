# Durable personal context and runtime safety notice

This file is imported natively by `.claude/CLAUDE.md`, rather than injected by
a shell hook. `core/core.yaml` preserves it across `/update-hq`, so put personal
voice, output hierarchy, and standing preferences below without editing the
release-owned charter.

@../personal/CLAUDE.md

## Safety context that is always loaded

- Never expose, print, paste, commit, or transmit secrets, credentials, private
  keys, tokens, or sensitive environment values. Use the HQ secret workflows.
- Keep company context isolated. Resolve the active company before using a
  company service, credential, DNS zone, or deployment target; never reuse one
  company's information or credentials for another.
- Treat `core/`, `.claude/`, `.agents/`, `.codex/`, `.obsidian/`, and
  `AGENTS.md` as release-owned scaffold. Do not change them unless the user has
  explicitly requested that scoped change. Put customizations in `personal/` or
  the active company scope.
- Ask before destructive, external, or irreversible actions. Do not infer
  authorization to deploy, publish, send messages, delete data, force-push, or
  change production infrastructure.

## App and SDK runtime warning

**HQ RUNTIME WARNING:** Shell-hook enforcement is not available in every Claude
Code host. In the affected Claude Code app/SDK runtime, command hooks registered
for `SessionStart`, `UserPromptSubmit`, `PreToolUse`, and `PostToolUse` are not
dispatched. That means secret detection, core-write and cross-company guards,
policy injection, autocommit, and journal hooks cannot mechanically enforce
their rules there.

The safety rules above and personal context still load as native Claude context,
but they are guidance, not a security boundary. When using an app or SDK host,
assume hooks are off until this ordinary command, run outside the hook system,
reports that the policy-trigger ledger was observed:

```bash
bash core/scripts/check-hq-hooks.sh --root "$PWD" --require-ledger
```

An SDK host that has its session ID should use `--session-id <id>` too, so an
older CLI session's ledger cannot be mistaken for this runtime.

If the command reports `HQ runtime enforcement: NOT OBSERVED`, use the terminal
Claude Code CLI for hook-enforced work or add equivalent host-side enforcement.

## Personal additions

Add your voice, output hierarchy, and other durable personal instructions below.
Keep safety-critical rules above intact.
