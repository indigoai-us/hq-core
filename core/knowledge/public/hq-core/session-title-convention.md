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

**No stubs.** When neither a project nor a repo resolves, every remaining
ingredient is information-free — a bare command word or a lone company token —
so the helper prints *nothing* and HQ sets no title at all. The host's own
auto-summary stands instead. This is deliberate: a stub is not merely useless,
it overwrites a written summary with a word that distinguishes nothing, and
because the stub never changes, the change-only cadence below would then keep
the session silent for the rest of its life. As soon as a project or repo does
resolve, the normal path takes the title back.

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

## Manual renames win

A title you set yourself — `claude --name "…"`, `/rename`, or the desktop
"Recents" rename — outranks HQ's computed one. As soon as the hook sees a title
it does not recognise as its own, it marks the session and stops emitting for
the rest of that session, so the manual title sticks.

Two signals feed that decision:

- **`session_title`** — the documented SessionStart hook input, populated by
  Claude Code when the session was named or renamed. This is the primary,
  version-stable signal.
- **the newest `custom-title` line in the session transcript** — how a
  mid-session `/rename` surfaces before the next SessionStart. Real lines look
  like `{"type":"custom-title","customTitle":"…","sessionId":"…"}`. The
  transcript format is internal and changes between Claude Code releases, so
  this is a labeled fallback net, not a contract.

To tell its own title apart from yours, the hook keeps a ledger of every title
it has emitted: per session in `.claude/state/session-title-<id>.emitted`, and
machine-wide in `.claude/state/session-title.hq-titles`. The machine-wide ledger
matters because `session_title` is inherited when a session is forked or
resumed while the session id is not — without it, HQ's own title coming back on
a forked session would look like a manual rename and would silently disable
titling there. If both ledgers are missing (a wiped `.claude/state`), an exact
match against the title HQ computes for that turn still identifies it as HQ's.
Per-session state files untouched for 14 days are pruned on SessionStart. A
session that is still open refreshes its own marker on every turn, so a session
you named weeks ago and never closed keeps its title.

## `sessionTitle` on UserPromptSubmit

`hookSpecificOutput.sessionTitle` is documented only for `SessionStart`, where
the docs note it takes precedence over `--name`/`/rename` and should be used
sparingly. It is *not* documented for `UserPromptSubmit`.

Observed behavior on current Claude Code is that mid-session emissions are
honored: real transcripts contain `custom-title` lines carrying HQ's computed
title well past the first turn, including a title switching to a different
project mid-session — which only a per-turn emission can produce. HQ therefore
keeps the per-turn update, but treats it as best-effort and undocumented: if a
future release ignores it, the title simply stops tracking the mode within a
session and SessionStart still sets it. Nothing else depends on it.

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
