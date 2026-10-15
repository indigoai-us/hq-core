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
  company service, credential, DNS zone, or deployment target. Work outside the
  session's locked company set is forbidden; for intentional multi-company work,
  add each company with `core/scripts/hq-session.sh add company <slug>`. Never
  move one locked company's information or credentials into another company's
  files, vault, or services unless the user asks for that transfer.
- Treat `core/`, `.claude/`, `.agents/`, `.codex/`, `.obsidian/`, and
  `AGENTS.md` as release-owned scaffold. Do not change them unless the user has
  explicitly requested that scoped change. Put customizations in `personal/` or
  the active company scope.
- Ask before destructive, external, or irreversible actions. Do not infer
  authorization to deploy, publish, send messages, delete data, force-push, or
  change production infrastructure.
- Do not inline large image bytes into the parent session. Cost is file size,
  not image count. The PreToolUse `image-context-guard` blocks a local image
  over 2 MB, and a new image once the parent context has inlined 8 MB of
  images (small images are charged at least 64 KB) or 32 distinct images.
  Each sub-agent has its own budget, so delegate inspection to sub-agents.

## App and SDK runtime warning

**HQ RUNTIME WARNING:** Shell-hook enforcement depends on the host actually
dispatching command hooks. The Claude Code terminal CLI and the desktop app
do dispatch `SessionStart`, `UserPromptSubmit`, `PreToolUse`, and `PostToolUse`.
Some SDK hosts still skip those events. Do not skip building a PreToolUse
guard because you assume hooks are off.

Native context (this file) is still guidance, not a security boundary, on any
host. When you need to know whether hooks ran in *this* session, use this
ordinary command, outside the hook system:

```bash
bash core/scripts/check-hq-hooks.sh --root "$PWD" --require-ledger
```

An SDK host that has its session ID should use `--session-id <id>` too, so an
older CLI session's ledger cannot be mistaken for this runtime.

If the command reports `HQ runtime enforcement: NOT OBSERVED`, either no
session has written the policy-trigger ledger yet, or this host did not
dispatch hooks. Use a host that does (desktop app or terminal CLI) or add
equivalent host-side enforcement. Do not treat a missing ledger as proof that
the desktop app never fires hooks.

## Personal additions

Add your voice, output hierarchy, and other durable personal instructions below.
Keep safety-critical rules above intact.
