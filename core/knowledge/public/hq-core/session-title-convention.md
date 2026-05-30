# Session Title Convention

HQ automatically renames each Claude Code session so the desktop sidebar
("Recents"), the terminal tab title, and the `/resume` picker double as a
status dashboard. Instead of an opaque auto-summary, every session reads as
*which company, which project, which mode, and whether work is live*.

This is driven by two files:

- `core/scripts/session-title.sh` — pure compute. Given a session id and an
  optional command word, it reads existing session/orchestrator state and
  prints one title string.
- `.claude/hooks/session-title.sh` — a SessionStart + UserPromptSubmit hook.
  It detects the active slash command, persists it across turns, calls the
  helper, and emits `hookSpecificOutput.sessionTitle` — but only when the
  computed title actually changes (a live, change-only cadence).

## Format

```
{status-emoji }{company} · {project} · {command}
```

Each segment is included only when it carries information:

- **status-emoji** — a status flag, *not* a per-mode decoration. It is
  prepended only when it adds signal the command word does not already convey,
  and is otherwise omitted:
  - `▶️` — the session's project is actively running (orchestrator state
    `IN_PROGRESS`).
  - `✅` — the project's run completed recently (orchestrator state
    `COMPLETED`, updated within the last 24 hours).
- **company** — the company slug resolved from the active project path
  (`companies/{slug}/projects/...`), or `hq-core` for HQ builder work, or the
  sole company on a single-company HQ. Personal projects show no company
  segment. Dropped entirely when nothing resolves.
- **project** — the active project slug. Dropped when there is no project.
- **command** — the active slash command / mode word with the leading slash and
  any namespace prefix removed (`/{company}:crm-management` → `crm-management`).
  The command persists across turns until a new slash command is issued. It
  falls back to `chat` when no command is active.

The title is capped at 44 characters. When over budget, the company segment is
dropped first (the project implies it).

### Examples

```
{company} · pmm-release-radar · brainstorm
{company} · hq-access-funnel · plan
▶️ {company} · hq-access-funnel · run-project
✅ {company} · hq-access-funnel · run-project
hq-core · hooks · hqwork
{company} · crm-management
{company} · chat
```

## How it updates

- On a fresh **SessionStart** (`source` `startup`/`resume`), the hook sets an
  initial title. Claude Code ignores `sessionTitle` on `clear`/`compact`, so
  the hook skips those sources — the next user prompt re-asserts the title.
- On every **UserPromptSubmit**, the hook recomputes the title and re-emits it
  only if it changed. This is what lets the title track a session as it moves
  `brainstorm → plan → run-project`.

## Opting out

- Per session / environment: `HQ_SESSION_TITLE=off` (also accepts
  `0`/`false`/`no`).
- Via the hook gate: add `session-title` to `HQ_DISABLED_HOOKS`. The hook runs
  in the `standard` and `strict` profiles only.

## Known limitations (v1)

- Entering plan mode via the keyboard toggle (rather than `/plan`,
  `/brainstorm`, or `/deep-plan`) produces no hook signal, so the command
  segment will not flip to a planning mode in that case. Explicit plan commands
  are detected.
- A `⚠️` blocked / awaiting-input flag is intentionally deferred until there is
  a reliable "blocked" signal to key it on.
- Mode is detected by sniffing the leading slash command from the prompt; no
  skill files write explicit mode markers. This keeps the feature zero-touch on
  the skill tree at the cost of not catching mode changes that happen without a
  slash command.
