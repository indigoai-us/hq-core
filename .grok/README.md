# Grok integration for HQ

# hq-core: public

HQ enforces its safety and lifecycle hooks through `.claude/hooks/`. This
directory makes those same policies fire under **Grok Build** (interactive +
headless `grok -p`), bringing Grok as close as possible to Claude Code and
Codex — with one Grok-specific bootstrap step.

## Architecture

| Layer | Role |
|---|---|
| `.claude/hooks/*` | Canonical policy (shared by Claude, Codex, Grok) |
| `.grok/hooks/hq-grok-hook-adapter.sh` | Normalizes Grok payloads → Claude-shaped JSON, maps tool names, translates deny to Grok's `{"decision":"deny"}` |
| `.grok/hooks/hq-grok.json` | Project-scoped registration (**PreToolUse only** — the bridge carries the rest) |
| `~/.grok/hooks/hq-hq-bridge.*` | **User-global bridge** installed by `hq reindex` — required on Grok builds that skip project hooks |
| `.grok/rules/*.md` | Grok-only always-on rules (`message-canvas`, `prefer-swarms`) |

Claude, Codex (`.codex/`), and Grok all route through the same `.claude/hooks/`
implementations. Do not fork policy into Grok-only scripts.

## Lifecycle coverage

The adapter handles:

| Event | Role |
|---|---|
| `SessionStart` | Policy inject, local context, startwork, update check, … |
| `UserPromptSubmit` | Resume sentinel, deep-plan route, session project, policy |
| `PreToolUse` | **Blocking** secrets / core-write / HQ-root git / active-run / packages / skill routing / … |
| `PostToolUse` | Checkpoint, registry capture, autocommit, journal due; **carries hook `additionalContext` to the model** |
| `Stop` | **Blocking** checkpoint gate and conduct inbox backstop; plus observe patterns, cleanup, estimates |
| `SubagentStop` | **Blocking**, same translation as `Stop`; no HQ hook is registered on it today |
| `PreCompact` | Thrashing detector, precompact checkpoint + journal |

Two Grok events are genuinely passive, and only two. `SessionStart` ignores hook
stdout outright. `UserPromptSubmit` can reject a prompt but nothing it writes
reaches the model — an allowing hook's stdout is discarded, and a block reason
goes to the operator. The adapter runs both for their side effects and surfaces
their notes as bounded stderr diagnostics.

Everywhere else Grok behaves like Claude. `PreToolUse` and `PostToolUse` deliver
`hookSpecificOutput.additionalContext` to the model next to the tool result
(10,000-character cap; a `PreToolUse` deny drops it, so the adapter folds it into
the deny reason). `Stop` and `SubagentStop` accept `{"decision":"block"}` — or
exit 2 with the feedback on stderr — and keep the agent working. Checked against
the hook reference in the Grok binary, verified for 1.0.34:

```sh
strings -n 20 "$(command -v grok)" | grep -n additionalContext
```

## One-time setup (required)

### Requires Grok >= 1.0.34

Check before anything else, and `grok update` if the build is older:

```sh
grok --version
```

On a 0.2.x build a `PreToolUse` deny does **not** block one tool call — it
cancels the whole turn (the session records
`cancellation_category: "hook_denied"`). `hq lanes` runs `grok --single`, where
the end of the turn is the end of the process, so the lane exits with
`stopReason: "Cancelled"` and never writes its envelope. Any HQ guard then
kills the worker on its first objection: two indigo lanes were lost this way on
2026-09-25, both to `block-hq-glob` correctly refusing a recursive `list_dir`
on the HQ root. On 1.0.41 the identical deny blocks only that tool call and the
turn continues.

`core/scripts/codex-preflight.sh doctor` reports the installed version and
warns when it is below the minimum.

### Converge hook trust

```sh
hq reindex
```

`hq reindex` converges Grok hook trust as part of its hook-trust step (the
installer lives in hq-cli — `src/utils/hook-trust.ts` — not a shell script):

1. Trusts this HQ root in `~/.grok/trusted_folders.toml` (and legacy
   `~/.grok/trusted-hook-projects` for older docs). **Folder trust is what
   unlocks project `.grok/hooks` loading.**
2. Installs `~/.grok/hooks/hq-hq-bridge.sh` + `.json` (**all lifecycle events**)
   so guards still fire if project hooks fail to load.
3. Sets `[compat.claude] hooks = false` in `~/.grok/config.toml` so Grok does
   **not** also load every project `.claude/settings.json` hook. HQ policy
   still runs via bridge → adapter → `hook-gate.sh`.

Re-run after `/update-hq` or whenever the project adapter changes.

### Why a user bridge?

On Grok Build **0.2.93**, until the HQ root is listed in
`trusted_folders.toml`, `grok inspect` can report `projectTrusted: yes` while
still loading **zero** project hooks. After `hq reindex`, project
`.grok/hooks` load **and** the user bridge provides a PreToolUse safety net.
The bridge walks from cwd / `GROK_WORKSPACE_ROOT` to the nearest HQ root and
execs the project adapter; outside HQ it fails open.

The user bridge registers EVERY lifecycle event and is the reliable path. The
project registration (`hq-grok.json`) is **PreToolUse only**, so passive /
side-effect events (PostToolUse, Stop, SessionEnd, …) fire exactly once — via the
bridge — and never double-run when a build loads both. Blocking PreToolUse is on
both paths on purpose (idempotent, so redundant enforcement is safe).

### Quieting noisy hook annotations

Grok’s TUI draws a green check per hook under each tool call. If Claude
compat still loads `.claude/settings.json`, you get ~50 `project/settings:…`
lines **plus** the bridge/adapter on every tool use — messy and slow.

HQ’s intended Grok path is thin:

| Keep | Role |
|---|---|
| `~/.grok/hooks/hq-hq-bridge` | User PreToolUse safety net |
| project `.grok/hooks/hq-grok*` | Full lifecycle → adapter → gate |

| Turn off | Why |
|---|---|
| `[compat.claude] hooks = true` (default) | Duplicates the adapter with individual settings handlers |

`hq reindex` writes this for you:

```toml
# ~/.grok/config.toml
[compat.claude]
hooks = false
```

Optional (hides remaining annotations + `/hooks` UI entirely):

```toml
disable_plugins = true
```

Restart the Grok session (or `/hooks` → `r`) after changing `config.toml`.

## Verifying

```sh
# Doctor (Codex + Grok)
bash core/scripts/codex-preflight.sh doctor

# Inspect: should list hq-hq-bridge under user hooks
grok inspect | sed -n '/Hooks/,/^$/p'

# Adapter unit checks (no network)
bash core/scripts/tests/hq-grok-hook-adapter.test.sh
```

Manual: from the HQ root, ask Grok to `git push` without `git -C` / `gh -R`,
or to write a secret-bearing command. A correctly-wired setup denies with an
HQ guard message. Writes under `personal/` proceed (unless other policies fire).

> Note: if `.claude/settings.local.json` sets `env.HQ_BYPASS_CORE_PROTECT=1`,
> core-write guards intentionally no-op. That is an operator choice, not a Grok
> gap.

## Headless invocation

Policy: `core/policies/grok-build-cli-headless-invocation.md`

```sh
grok -p "<prompt>" --permission-mode acceptEdits --cwd <repo> --no-alt-screen --output-format plain
```

With the user bridge installed, PreToolUse still enforces under `bypassPermissions`
(explicit hook denies win).

## Skills and charter

- Skills: `.agents/skills` → `.claude/skills` (Grok discovers both).
- Charter: root `AGENTS.md` → `.claude/CLAUDE.md`.
- Grok-only UI guidance: `.grok/rules/message-canvas.md`.
- Grok-only swarm doctrine: `.grok/rules/prefer-swarms.md` (worker-backed
  background swarms + durable `workspace/orchestrator/` handoffs).

## Parity note

This is **guardrail + lifecycle** parity with Codex’s adapter, not a
line-for-line clone of every Claude `settings.json` hook. The remaining gaps are
`SessionStart` and `UserPromptSubmit` context injection, and the tools Grok has
no equivalent for (`ExitPlanMode`, `AskUserQuestion`, `WebFetch`). When Grok’s
project-hook loader is fixed upstream, `hq-grok.json` is already registered for
the same events so double-firing is harmless (idempotent / fail-open advisory
hooks).
