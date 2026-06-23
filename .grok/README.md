# Grok integration for HQ

HQ enforces its safety guardrails (core-write protection, secret detection,
HQ-root git-mutation block, unsafe-package block) through `.claude/hooks/`. This
directory makes those same guardrails fire under **Grok** (Grok Build / Composer),
bringing Grok to parity with Claude Code and Codex.

## How it works

- `.grok/hooks/hq-grok.json` registers a `PreToolUse` hook for Grok's file and
  shell tools (`run_terminal_command`, `search_replace`, `write`, …).
- `.grok/hooks/hq-grok-hook-adapter.sh` normalizes Grok's camelCase hook payload
  (`toolName` / `toolInput`) into the Claude-shaped JSON the existing HQ hooks
  expect, runs them through `.claude/hooks/hook-gate.sh`, and translates a block
  into Grok's `{"decision":"deny","reason":…}` response (exit 2).

This keeps a single canonical policy implementation in `.claude/hooks/` — Claude,
Codex (`.codex/`), and Grok (`.grok/`) all route through it.

## One-time trust (required)

Grok silently skips **project** hooks until the project is explicitly trusted —
a supply-chain guard so an untrusted repo can't run code on your machine. Grant
trust once by adding the HQ root's absolute path to `~/.grok/trusted-hook-projects`
(one path per line):

```sh
core/scripts/grok-trust.sh   # preferred: idempotently trusts this tree, or:
grok /hooks-trust            # from inside an interactive session, or:
printf '%s\n' "$(git rev-parse --show-toplevel)" >> ~/.grok/trusted-hook-projects
```

Until trusted, Grok runs unguarded. After trusting, HQ's guardrails enforce for
Grok exactly as they do for Claude.

## Verifying

From the HQ root, ask Grok to write to a protected path (e.g. `core/scripts/x`).
A trusted, correctly-wired setup blocks it with an HQ "protected scaffold" message;
writes to `personal/` and other non-protected paths proceed normally.

## Headless enforcement — verified working (Grok 0.2.56)

Verified empirically (2026-06-23): with the corrected adapter (real tool names
`Shell`/`StrReplace` + a match-all matcher) and the project trusted, headless
`grok -p` **executes** project `PreToolUse` hooks and honors `{"decision":"deny"}`
/ exit 2. A `grok -p` shell write into `core/` is DENIED; a write into `personal/`
is allowed.

An earlier note here claimed `grok -p` could not run PreToolUse hooks. That was
wrong — a Grok **fail-open masking two HQ bugs**: a test hook whose `command` path
didn't resolve, and stale tool names (`run_terminal_command`/`search_replace`)
that let `Shell`/`StrReplace` calls fall through unguarded. Both are fixed (commit
`2f076b9`).
