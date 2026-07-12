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
| `.grok/hooks/hq-grok.json` | Project-scoped registration (all lifecycle events) |
| `~/.grok/hooks/hq-hq-bridge.*` | **User-global bridge** installed by `core/scripts/grok-trust.sh` — required on Grok builds that skip project hooks |
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
| `PostToolUse` | Checkpoint, registry capture, autocommit, journal due |
| `Stop` | Observe patterns, cleanup, estimates |
| `PreCompact` | Thrashing detector, precompact checkpoint + journal |

Grok cannot inject Claude-style “additional context” from passive hooks the way
Codex can; side-effect hooks still run. Blocking safety is PreToolUse-only
(platform constraint).

## One-time setup (required)

```sh
core/scripts/grok-trust.sh
```

That script:

1. Trusts this HQ root in `~/.grok/trusted_folders.toml` (and legacy
   `~/.grok/trusted-hook-projects` for older docs). **Folder trust is what
   unlocks project `.grok/hooks` loading.**
2. Installs `~/.grok/hooks/hq-hq-bridge.sh` + `.json` (PreToolUse only) so
   blocking guards still fire if project hooks fail to load.
3. Sets `[compat.claude] hooks = false` in `~/.grok/config.toml` so Grok does
   **not** also load every project `.claude/settings.json` hook. HQ policy
   still runs via bridge → adapter → `hook-gate.sh`.

Re-run after `/update-hq` or whenever the project adapter changes.

### Why a user bridge?

On Grok Build **0.2.93**, until the HQ root is listed in
`trusted_folders.toml`, `grok inspect` can report `projectTrusted: yes` while
still loading **zero** project hooks. After `grok-trust.sh`, project
`.grok/hooks` load **and** the user bridge provides a PreToolUse safety net.
The bridge walks from cwd / `GROK_WORKSPACE_ROOT` to the nearest HQ root and
execs the project adapter; outside HQ it fails open.

Passive lifecycle events (SessionStart, PostToolUse, …) are registered on the
**project** adapter only — not the user bridge — so advisory hooks do not
triple-run once the project adapter is loaded.

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

`grok-trust.sh` writes this for you:

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

This is **guardrail + lifecycle side-effect** parity with Codex’s adapter, not
a line-for-line clone of every Claude `settings.json` hook (Claude still has
the richest event surface and context-injection path). When Grok’s project-hook
loader is fixed upstream, `hq-grok.json` is already registered for the same
events so double-firing is harmless (idempotent / fail-open advisory hooks).
