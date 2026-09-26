# HQ Migration Guide

Newest release first. `## Release: TBD` collects promotions staged for the next
release; the release workflow stamps it with the version at tag time.

## Release: v15.0.172-beta.1

- fix 2026-09-26 (Grok hook capabilities): the v15.0.127-beta.5 entry below says
  a Grok lane cannot be handed context and that its `Stop` cannot block. Both
  are wrong, checked against the hook reference embedded in Grok 1.0.34. Grok
  delivers `hookSpecificOutput.additionalContext` on `PreToolUse` and
  `PostToolUse`, and its `Stop`/`SubagentStop` gates block on
  `{"decision":"block"}` or exit 2. So a `/conduct` message now reaches a Grok
  lane the same way it reaches a Codex or Claude lane — as context on
  `PostToolUse`, with `Stop` as the backstop — and no longer costs the lane a
  denied tool call. The Grok adapter translates a Stop hook's block into Grok's
  stop protocol and forwards `stopHookActive` as `stop_hook_active`, so a gate
  that blocks keeps its one-block-per-chain guard. The gates that hold a Grok
  turn today are the CLI checkpoint gate and the conduct inbox backstop.
  `enforce-humanize-before-send` and `enforce-capability-link-render` still
  no-op under Grok: they read the session transcript, and Grok writes an
  `updates.jsonl` in its own schema rather than Claude's, so their parse finds
  no assistant records. The adapter now forwards `transcript_path` and
  `last_assistant_message` so that gap can be closed without another payload
  change. `HQ_GROK_STOP_BLOCK_MAX` (default 3) caps consecutive
  adapter-emitted Stop blocks, and the session-close Stop neither blocks nor
  lets a delivery hook drain its queue. `SessionStart` and `UserPromptSubmit`
  remain diagnostics-only under Grok. No action beyond `/update-hq`.

## Release: v15.0.171-beta.4

- promote 2026-09-25 (hq monitor policy and hooks): `hq-core-staging` now guides
  Claude, Codex, and Grok toward `hq monitor` for long waits, with check-ins
  every 55 minutes. The guard and hook registrations query `monitor.enabled`
  through hq-cli; hq-cli owns the flag value. Event delivery requires
  hq-cli 5.203.0 or later.

- promote 2026-09-25 (`/deploy` owner comment routes): the deploy skill now
  documents the owner comment routes on hq-deploy —
  `GET/POST /api/apps/:id/manage/comments` and
  `PATCH /api/apps/:id/manage/comments/:commentId` — so an agent or CLI can
  read, add, and resolve comments with the normal HQ login, including on gated
  deploys. It warns that `/api/apps/:id/comments` is the in-page widget route
  and always returns 403 outside a browser, and that `commentsEnabled` must be
  set before the upload for the current deploy to include the widget. No action
  beyond `/update-hq`.
## Release: v15.0.166-beta.1

- fix 2026-09-24 (vault prefix grants + work-mesh notes): hq-pro #3662 made
  the server echo the requested ACL pattern verbatim and treat a bare
  trailing-slash `foo/` as a private create-only folder, so `/delegate` grants,
  ontology audience grants, and the `/newcompany` group share now always send
  the recursive `foo/*` pattern and read it back by that exact pattern. The
  vault write-access hook and `refresh-vault-access.sh` now understand
  private-folder `foo/` rows (write/admin covers direct children only; read
  covers none). `hq mesh session note|blocked|task-status` calls in
  `/delegate`, `run-project.sh`, and the `/idea`, `/run`, and Grok rule
  examples use `--session-id` (hq-cli 5.157+ rejects `--session`). No action
  beyond `/update-hq`. A `/delegate` that stopped at "ACL preflight failed"
  since 2026-09-23 can be re-run.

## Release: v15.0.158-beta.1

- promote 2026-09-23 (local ontology + signals): opt-in session-close capture.
  New switches in `settings/knowledge/preferences.yaml`: `signals_capture`,
  `ontology_capture` (default false; resolve with
  `core/scripts/knowledge-prefs.sh`). When on, `/handoff`, `/checkpoint`, and
  `/learn` write candidates under `signals/_candidates/` and
  `ontology/_candidates/`; the new `ontology` worker (`garden`,
  `process-source`) promotes them into identity-only entity files,
  audience-scoped facts (`ontology/facts/@{key}/`), and signals
  (`signals/@{key}/`). Every scoped item is readable only by people privy to its
  source (email chain, Slack channel, meeting attendees). Sources are declared
  with `sources/{channel}/source.yaml` (spec `source-yaml-spec.md`). `/ontology`
  renders from the local tree first. `.hqignore` keeps `_candidates/`,
  `_rejected/`, and `.processed` local. Installs that sync through an
  `.hqinclude` allowlist should add `companies/*/ontology/`,
  `companies/*/signals/`, `companies/*/sources/` to it. No action needed for
  companies that leave capture off.

- promote 2026-09-22 (member access baseline + `/team-access`): `/designate-team`
  now writes four `@all write` prefix grants (`knowledge/`, `projects/`,
  `policies/`, `skills/`) right after provisioning, so plain members can push
  what they create and pull what teammates wrote. Members hold no implicit
  file access; only owner/admin bypass the ACL walk. Never a bucket-wide `*`.
  New skill `/team-access <slug>` lets an owner narrow that baseline to chosen
  subfolders (grant new paths first, revoke the broad one last, readback
  verification on every grant) and records the intent in the company's
  `settings/team-access.yaml`. Companies cloud-backed before this release have
  no baseline; run `/team-access <slug>` once to set it.
- promote 2026-09-22 (full company seed): the company template gains
  `signals/`, `sources/{meetings,_index}/`,
  `ontology/entities/{person,project,company,concept}/`, and
  `settings/knowledge/preferences.yaml`. `/newcompany` Phase 0 now mirrors the
  whole template layout (policies, workers, skills, projects, people, data,
  settings, the three native stores) instead of a hand-picked subset, and its
  Phase 6 no longer suggests a second `@all read` baseline. No action needed
  for existing companies; create missing folders by hand if a skill expects them.

## Release: v15.0.155-beta.1

- promote 2026-09-21 (conduct default: no preset engine): `conduct.default_engine`
  is removed from `core/settings/orchestrator.yaml`. When `conduct.default_enabled`
  is on, `.claude/hooks/auto-conduct.sh` now tells the assistant to run `/conduct`
  with no engine, and `/conduct` asks which engine to use (codex, grok, or
  claude) unless one is named in the argument. A leftover `default_engine` key
  in a personal override is ignored.

## Release: v15.0.153-beta.1

- promote 2026-09-20 (conduct as the session default): new `conduct:` block in
  `core/settings/orchestrator.yaml` (`default_enabled`, `default_engine`). When
  enabled, the new SessionStart hook `.claude/hooks/auto-conduct.sh` persists
  `conduct_engine` for the fresh session and instructs the assistant to run
  `/conduct <engine>` first, so every task goes to detached worker lanes. Off by
  default; override per machine in `personal/settings/orchestrator.yaml`, per
  session with `HQ_AUTO_CONDUCT=1|0` or `HQ_DISABLED_HOOKS=auto-conduct`. No
  action needed after `/update-hq` unless you want the default on.

## Release: v15.0.151-beta.4

- **Device default company fallback (US-008).** Set a default on each human device with `hq mesh context default set <slug>`. HQ SessionStart, `/plan`, `/prd`, `/deep-plan`, `/startwork`, and natural-language routing use it only when no explicit company or bound session company exists. Fleet dispatches never use this fallback. Use `hq mesh context default clear` to return to the company picker.

## Release: v15.0.148-beta.18

- fix 2026-09-19 (feedback_ca842a26, DEF-026 follow-up): `block-env-dump.sh`
  now blocks a dump regardless of what follows it: redirected to a file
  (`>`, `>>`, `2>`, `&>`), piped to `tee`, captured with `$(...)` or backticks,
  or run in a subshell. v15.0.148 only caught the bare and piped shapes, so a
  dump written to disk passed and left secrets on disk. `printenv VAR > file`
  and `env VAR=x cmd > file` still work.
- fix 2026-09-19 (DEF-026 env dumps): `block-env-dump.sh` is now on the live
  PreToolUse path. Bare `printenv` / `env` / `set` / `export -p` / `declare -x`
  and env dumps piped into other commands are blocked (exit 2) under every
  hook profile. `printenv VAR` and `env VAR=x cmd` still work. After
  `/update-hq` or a create-hq from this template, those dumps no longer reach
  chat output. Also adds `.cursor/rules/hq.mdc` so Cursor loads the same
  charter as Claude Code (DEF-002).

## Release: v15.0.148-beta.15

- promote 2026-09-18 (dm-bind always mentions): `core/scripts/hq-dm-bind.sh post`
  no longer accepts `--no-mention`; every post @-mentions someone. New
  `--to <name>` (repeatable) narrows the mention line to named channel members,
  matched case-insensitively against the roster. `post` now exits 2 instead of
  posting unmentioned when the roster cannot be read or a `--to` name does not
  match exactly one member. Callers that passed `--no-mention` must drop it or
  switch to `--to`.
  Posts also thread by topic now: the first post on a topic (`--topic`, else the
  title) is a root and later posts on it go out as replies (`rootEventId`);
  `--new-thread` starts a new root. `post` sends through the notify API directly
  (the `hq` CLI has no thread flag), so it needs `node` and a signed-in session.

## Release: v15.0.148-beta.13

- fix 2026-09-18 (Auto hatch): shipped `permissions.defaultMode` is `auto`
  again and rescue no longer rewrites it to `plan`. Claude Code still ignores
  `auto` from project and `.claude/settings.local.json`. Operators still in
  Plan after `/update-hq` should use the mode picker or set
  `permissions.defaultMode: "auto"` in `~/.claude/settings.json`. Do not put
  Auto only in the local file. Policy `hq-claude-code-default-mode-plan-not-auto`
  v4 documents that hatch.

## Release: v15.0.148-beta.9

- fix 2026-09-18 (Google Docs canvas clicks): browser MCP screenshot-coordinate
  clicks miss canvas apps (Google Docs) and unscoped `type` can insert into the
  live document body. Policy `hq-prefer-agent-browser` v4 plus
  `core/knowledge/public/agent-browser/` now require refs/keyboard on canvas
  apps, warn that type follows focus, and note that agent-browser cannot reuse
  a logged-in Chrome Google session (headed sign-in, then `state save`). The
  PreToolUse MCP nudge fires even when agent-browser is missing. Nothing to do
  on update except `/update-hq`; existing Google Chrome logins are still not
  inherited.

## Release: v15.0.148-beta.4

- promote 2026-09-18 (/conduct owner-facing surface): `/conduct` now routes every
  owner-facing need through `/decision-queue` — one `AskUserQuestion` per
  decision, recommended option first, on every surface (status ticks, loop
  wakeups, lane completions, cross-session requests), never a markdown list of
  questions. When two or more lanes are live, every status reply also renders the
  board widget from the new template `.claude/skills/conduct/status-board.html`;
  a text-only status with multiple lanes running is a defect. Adds
  `mcp__visualize__read_me` / `mcp__visualize__show_widget` to the skill's
  allowed tools. Documentation + template only; no script or hook behaviour
  changes.

## Release: v15.0.148-beta.2

- promote 2026-09-17 (/pin): new core skill `/pin`
  (`.claude/skills/pin/SKILL.md`) and helper `core/scripts/hq-pin.sh` (`set`,
  `show`, `check`, `note`, `done`, `clear`). Anchors a session to one goal with
  done criteria, re-read at every wake, loop tick and resume so a long session
  does not drift or stop early. Bash only; stores `workspace/sessions/<sid>/pin.md`
  plus a `pin:` key in the session meta via `hq-session.sh`. Additive.
- fix 2026-09-17 (hq-sync reporting): the `/hq-sync` skill no longer reads
  `expiresAt` out of `~/.hq/cognito-tokens.json`. `CognitoTokens.expiresAt` is
  `string | number`, so on the ISO-string form the numeric comparison errored
  and `set -euo pipefail` killed the script with `integer expression expected` —
  on a perfectly valid token. The engine already refreshes an expired access
  token from the stored refresh token, so the check was also wrong in principle.
  Step 2 now checks only that the token file exists; the runner's `auth-error`
  event is the signal that the user is actually signed out. Partial and
  conflicted syncs are reported honestly rather than as success.
- fix 2026-09-17 (hook timeout warnings): the timeout-warning fingerprint now
  hashes the hook path normalized against the HQ root, falling back to the hook
  basename when the path is outside it. Warnings for the same hook group
  together across installs instead of fragmenting on absolute paths.

## Release: v15.0.148-beta.1

- promote 2026-09-17 (dm-bind mentions): `core/scripts/hq-dm-bind.sh post` now
  opens every post with an @-mention of every other channel member (read from
  the channel roster at bind time and refreshed per post; `--no-mention` opts
  out) and gains a `roster` subcommand. Mentions are resolved by the `hq` CLI
  into structured mentions, so members are notified. Needs `node` on PATH and
  a signed-in `hq` session; without either, posts go out unmentioned with a
  warning on stderr.

## Release: v15.0.147-beta.1

- promote 2026-09-17 (workflow-runner claude effort): `core/scripts/workflow-runner.mjs`
  now passes `--effort <level>` to the `claude` engine (the CLI has taken it since
  2.1). The claude default is `low`, set by new env `HQ_WORKFLOW_CLAUDE_EFFORT`;
  `opts.effort` on an `agent()` call still wins. `HQ_WORKFLOW_EFFORT` keeps its
  meaning for codex and grok and is no longer read for claude. Claude lanes that
  relied on the CLI's implicit default now run at low effort; set
  `HQ_WORKFLOW_CLAUDE_EFFORT=high` (or pass `effort`) to restore the old cost.

## Release: v15.0.146-beta.2

- promote 2026-09-17 (dm-bind): new core skill `/dm-bind`
  (`.claude/skills/dm-bind/SKILL.md`) and helper `core/scripts/hq-dm-bind.sh`.
  Binds a session to one HQ DM channel, posts status updates in a fixed shape
  (title and state, short bullets, `Next:` / `Need from you:` lines), and
  listens for replies as steering input. Additive; nothing to do on update.

## Release: v15.0.144-beta.1

- promote 2026-09-17 (starter-plan-hard-limits landing): `.gitignore` now
  excludes `/workspace/.session-logs/`, which the HQ desktop git-mirror also
  excludes to keep the pushed repo under its size cap. No action needed;
  installs that had session logs tracked stop tracking them on the next update.
- promote 2026-09-17 (packages): `core/packages/README.md` documents that packs
  are sourced from `indigoai-us/hq-packages` via `github:` shorthand, lists the
  `diagrams`, `charts` and `engineering` packs, and points at
  `core/scripts/scan-packages.sh` as the wiring ground truth. Documentation only.
- staging hygiene: `.claude/state/active-session-project` and
  `.claude/state/auto-session-project-*` were tracked in core by mistake. They
  are per-machine pointers written by `core/scripts/session-project.sh`; they
  are now untracked and ignored. `.staging-deletion-list.txt` (added by #755) is
  removed: nothing reads it, and six of its seven paths were never tracked.
  Existing installs keep their local copies; the next update stops shipping them.

## Release: v15.0.142-beta.4

- promote 2026-09-16 (hooks, exit status): **A hook that exits before reading
  its payload is no longer reported as having failed.** Every HQ dispatch path
  fed the payload through a pipe (`printf '%s' "$payload" | "$hook"`). A hook
  that exits early — `conduct-lane-inbox.sh`'s
  `[ -n "${HQ_CONDUCT_RUN_DIR:-}" ] || exit 0` guard is the canonical shape —
  closes the read end while `printf` is still writing, so `printf` dies of
  SIGPIPE and the `pipefail` set by `hook-gate.sh`, `master-hook.sh`, and both
  cross-runtime adapters promotes 141 to the pipeline status. A hook that exited
  0 was then reported as failing with 141. The race needs the payload to exceed
  the pipe buffer (64 KiB on Linux, 8 KiB on stock macOS), which made it
  intermittent: on an untouched v1 fleet box the citizenship probe failed 2 of 3
  runs with `PROBE_FAIL - pre-bind: first company read on a fresh session was
  refused (rc=141): Hook 'conduct-lane-inbox' exited 141`, blocking the v1->v2
  migration. Only exit-0 hooks were corrupted: `pipefail` returns the rightmost
  non-zero status, so a genuine block (2) or error already won over the writer's
  141.

  Fixed on both halves. Every dispatcher now records `PIPESTATUS[1]` — the
  hook's own element — instead of `$?`: `core/scripts/hook-lib.sh`
  (`hq_launch_shell_path`, exec path and bash-fallback path),
  `.claude/hooks/hook-gate.sh` (inline fallback), `.claude/hooks/master-hook.sh`
  (`run_child`, the in-process registry and directory dispatch), and the
  `.codex/` and `.grok/` adapter fallbacks. Payload bytes are unchanged — the
  pipe stays, only the status read moves. Separately, hooks that can exit before
  their `cat` now drain stdin first, so they stay safe under an OLD dispatcher
  they cannot upgrade: `conduct-lane-inbox.sh`, `checkpoint-stop-gate.sh`,
  `block-foreground-timeout-over-harness-ceiling.sh`,
  `inject-codex-checkpoint-reprompt.sh`, and the usage guards in
  `hook-gate.sh` and `master-hook.sh`.

  Regression coverage: `core/scripts/tests/hook-launch-sigpipe-status.test.sh`
  (1 MiB payload through hook-lib's two paths, hook-gate, and master-hook's
  registry dispatch, plus guards that a genuine 2 or 3 still propagates) and
  `core/scripts/tests/hooks-drain-stdin-before-early-exit.test.sh` (each
  early-exit hook under a bare `printf | hook` pipeline with `pipefail`). Both
  run in the new `hook-launch-status` CI job.

  **Fleet rollout:** boxes do not pick this up automatically. After this release
  ships, run on each box:
  `hq rescue --hq-root /home/ec2-user/hq-agent --yes`.

## Release: v15.0.142-beta.2

- promote 2026-09-16 (voice, mannered prose): **HQ now has an explicit rule
  against the aphoristic register, and it is enforced on outbound sends.**
  Plain-language guidance already existed, but it covered vocabulary, not
  cadence. Output could be free of jargon and still read as an essay: antithesis
  ("not a bug, a boundary problem"), closers that land a note instead of a fact,
  three adjectives where one was needed, portentous fragments, metaphor standing
  in for the mechanism. It is the strongest default on Opus-class models, and it
  reached users through chat, Slack bot replies, and email drafts alike.

  New policy `core/policies/hq-no-mannered-prose.md` (soft, SessionStart) is the
  canonical rule. Both output styles gained a "No mannered prose" section plus a
  table of `/humanize` tells that leak into conversation (sycophancy,
  signposting, filler, over-hedging, AI vocabulary, copula avoidance, elegant
  variation, false ranges, generic closes, boldface scatter, inline-header
  lists). The charter's Communication section points at the rule. `/humanize`
  gained a MANNERED PROSE group, patterns 31-39, with before/after pairs.

  Enforcement: the `enforce-humanize-before-send` Stop hook previously watched
  `hq dm`, `hq cowork dm`, Slack `chat.postMessage`, Post-Bridge, and
  `mcp__hq__hq_dm`. It now also covers email (Superhuman and Gmail draft/send),
  WhatsApp, SMS/Twilio, iMessage, Telegram, and social publishers, matching
  either the tool verb after the final `__` or a channel name in the server
  segment, so a channel added later is covered without another edit. Four tell
  categories were added (antithesis, rhythm triads, portentous fragments,
  throat-clearing) on top of the existing six. The two-distinct-category cluster
  bar is unchanged, so a single em dash or one plain three-item list still does
  not trip it. Regression coverage grew from 9 cases to 16.

  The Slack bot worker system prompt
  (`core/packages/hq-pack-slack-bot/workers/slack-mention-worker/system-prompt.md`)
  gained a Voice section carrying the same rules inline, because bot workers run
  with an appended system prompt and never load an output style.

  No migration action required. Sessions pick up the new styles at next start.
  Operators who find the hook too strict can widen the cluster bar in
  `.claude/hooks/enforce-humanize-before-send.sh`; it fails open on any error
  and never blocks more than once per stop chain.

## Release: v15.0.142-beta.1

- promote 2026-09-16 (conduct lanes, machine load): **detached conduct lanes
  whose orchestrating session has exited are now swept up instead of running
  forever.** `hq-detach.sh` deliberately starts a lane in its own POSIX
  session so a parent turn sweep cannot reap it — a lane has to outlive the
  turn that launched it. Nothing existed on the other side of that door, so a
  lane whose owner exited was reparented to launchd and kept working
  unsupervised, each one fanning out a test suite at roughly one process per
  core. They accumulated silently across days. Measured on an 18-core macOS
  host before this change: load average 246, 99 node processes, a runner
  orphaned mid-task, a pool lane idle for 15h51m, and node processes orphaned
  for three days; one single orphaned lane held 20 processes. The desktop app
  was blamed first and was using 55 MB at 0.2% CPU.

  New `core/scripts/conduct-reap.sh` classifies every registered lane and
  reports by default; `--apply` clears the liveness markers of finished lanes
  (logs and args are deliberately kept — they are the only record of what a
  lane did), and `--apply --kill` additionally stops orphaned ones. Ownership
  is tested by walking the whole ancestor chain for a live `claude` process,
  not by checking the immediate parent: a lane is a small tree, so its parent
  is usually just another piece of the same orphaned lane. **A lane whose
  owning session is alive is never touched, at any age.** An age gate
  (`--min-age`, default 30 minutes) keeps a just-started lane out of scope.

  New `core/hooks/SessionStart/40-conduct-reap.sh` runs the sweep when a
  session opens — the best available signal that an earlier one ended. It is
  detached so session start never waits on it, single-flighted via an atomic
  `mkdir` lock so a burst of sessions cannot race to signal the same pids, and
  rate-limited to one sweep per 30 minutes. Disable with
  `HQ_DISABLED_HOOKS=conduct-reap`; tune the gate with
  `HQ_CONDUCT_REAP_MIN_AGE`.

  Note for anyone extending this: `promote-hq-core-scan.sh` does not walk
  `core/hooks/`, so hooks in that directory do not appear in a promotion scan
  and have to be carried across deliberately.

## Release: v15.0.140-beta.1

- promote 2026-09-16 (hook dispatch, Windows performance): **the gated
  project hooks now run in-process from `.claude/hooks/hook-registry.json`
  instead of one `settings.json` registration each.** Every registration
  cost a gate bash, a watchdog and a body bash before the hook did any
  work; on Windows Git Bash that floor is about a second per hook and a
  Bash tool call carried 34 of them (66 s measured per tool call on a
  Windows Server VM, 3.5 s on macOS). `settings.json` keeps one
  `master-hook.sh` line per event; `master-hook.sh` reads stdin once,
  evaluates profile and `HQ_DISABLED_HOOKS` in-process (`hook-gate.sh
  --lib`), skips hooks whose prefilter cannot match the tool input, skips
  the policy injector when the tool text contains none of the tokens any
  tool-event policy requires, caches the worktree guard verdict per
  session, and runs each child under its registry timeout. Codex and Grok
  adapters read the registry through `hook-adapter-core.sh` and keep
  dispatching each gated hook through `hook-gate.sh`. Measured per Bash
  tool call: macOS 3500 to 131 ms, Windows 66,450 to under 5,000 ms. New:
  `core/scripts/bench-hooks.sh` (replays one tool call through the real
  hook wiring), `HQ_HOOK_TRACE=1` (per-hook run/skip lines with timing).
  Operators who registered extra hooks by hand in `settings.json` should
  move them to the registry (same event/matcher shape, plus `id`, `script`,
  `timeout`); `settings.local.json` hooks are unchanged. Found and left
  as-is: four gated ids were already absent from every profile list and
  never ran (`capture-estimates`, `check-core-yaml-parity`,
  `env-file-no-trailing-newline`, `record-policy-retrieval`).

## Release: v15.0.139-beta.2

- promote 2026-09-15 (dispatch-lane tests): **the prose assertions no longer
  depend on the caller's locale.** Three checks matched the protocol's em-arrow
  separator with a bare `.`. That is one character under a UTF-8 locale and one
  BYTE under C, and the arrow is three bytes — so the suite passed on CI
  (`LANG=C.UTF-8`) and failed on a stock macOS shell, where `LANG` is unset and
  a non-interactive shell falls back to C. The suite was therefore green in CI
  and unrunnable on the machine most likely to be editing the protocol.
  `.\{1,3\}` matches either way. Verified 38/38 both with `LANG` unset and under
  `en_US.UTF-8`.

## Release: v15.0.139-beta.1

- promote 2026-09-15 (lane dispatch): **lanes launch through
  `core/scripts/hq-detach.sh`, never through a bare `setsid`.** §4 called
  `setsid nohup bash -c ...` literally. Stock macOS ships no `setsid(1)` at all,
  and when Homebrew util-linux supplies one it is keg-only — deliberately left
  out of the PATH — so the launch died with `command not found` on every Mac,
  in a log nobody was watching yet, which reads as a lane that silently never
  started. The launch is now `bash core/scripts/hq-detach.sh -- bash -c '...'`;
  the helper redirects stdin/stdout and detaches on its own, so the trailing
  `> /dev/null 2>&1 < /dev/null &` and `disown` are gone. The proof-of-escape
  check is unchanged and still passes: the wrapper is its own group leader
  (`pgid == pid`) on both paths.

- promote 2026-09-15 (`hq-detach.sh`): **the `setsid(1)` probe now covers the
  Homebrew keg prefixes.** It tested `command -v setsid` only, so a Mac with
  util-linux installed still fell through to the node path, and a caller that
  had put the keg on an interactive PATH got different behaviour than a hook or
  detached process did. It now probes `setsid`, then
  `/opt/homebrew/opt/util-linux/bin/setsid`, then
  `/usr/local/opt/util-linux/bin/setsid`, and falls back to node
  `child.detached` when none resolve. Both paths were verified to produce a
  session leader. `HQ_DETACH_FORCE_NODE=1` still forces the node path.

- promote 2026-09-15 (`/run-project`): **the engine, model and reasoning effort
  are confirmed with the user before the first dispatch.** Resolution picks a
  default; it is not a decision the user made, and a run is many hours of lane
  time on whatever that default is. Ask once, up front, unless the invocation
  named one. Includes the per-engine model/effort forwarding table and the
  caveat that `effort` is not wired for claude lanes — it must be passed as
  `extraArgs: ["--effort", ...]`.

## Release: v15.0.130-beta.2

- promote 2026-09-12 (lane dispatch): **the detached launch body is
  single-quoted and interpolates nothing.** It was a double-quoted `bash -c`
  string with `$PWD`, `$RUN_DIR` and `$SID` substituted into single-quoted
  values inside it. An apostrophe anywhere in the HQ checkout path — the one
  value here a user genuinely controls — closes those quotes early. Verified
  empirically from a path containing one: the old form dies with
  `unexpected EOF while looking for matching \`'\`` and writes no `lane.log` at
  all, so the lane fails before it exists and the error lands where nothing is
  watching. Everything the body needs now goes through the environment
  (`LANE_RUN_DIR`, `LANE_RUN_DIR_ABS`, `LANE_TIMEOUT`, `HQ_SESSION_ID`,
  `HQ_CONDUCT_ENGINE`); the same path runs clean. This also removes the
  two-level escaping that made this the most error-prone block in the protocol.

- promote 2026-09-12 (lane dispatch): **`$SID` is the run's owner, not whoever
  is dispatching.** The mint site recomputed it from the current session, which
  undid the recovery fix one entry above: a resumed story would export the new
  session's id, mint its run dir there, and an unqualified `record` would write
  into a pool that never assigned the slot — a live lane untracked, the original
  slot stuck `claimed`. A caller holding an owning session id uses it at the
  mint site and passes `--session-id <owner>` on every pool call for the lane.
  One session id per run, chosen once, end to end.

- promote 2026-09-12 (lane dispatch): **both callers withhold release on an
  unconfirmed engine, on every outcome.** The shared protocol confirms the
  engine group after every exit, but `/conduct` Step 6 and `/run-project`'s
  recycle gate still described the carve-out as timeout-only — so a coordinator
  could mark a `died` lane idle and retry on top of a live engine. Both now gate
  on `engine_gone`.

- promote 2026-09-12 (lane dispatch): **the engine-group confirmation observes
  first and only forces after a refused request.** Generalising the check last
  entry put it *before* the branch handling and had it SIGKILL on sight, which
  meant the deadline branch never got to ask the runner politely — the graceful
  path it exists to protect became unreachable and a timed-out worker was torn
  down mid-write. The block is now ordered after any branch teardown and gated
  on `graceful_attempted`, which only the deadline branch sets, and only after
  the runner has had its 30 seconds. On `exited`, `died` and `never-started`
  there was no request to refuse, so a survivor is observed and reported —
  never killed — and the slot parks as unconfirmed for a human to decide.

- promote 2026-09-12 (lane dispatch): **a run records the session that owns its
  lanes, and recovery passes it back.** `conduct-pool.sh` resolves the session
  from the environment and run dirs are minted under the session id, so a new
  session resuming a project read *its own* empty pool, concluded there were no
  live lanes, and could re-dispatch a story whose original lane was still
  committing. `/run-project` now writes `session_id` into `state.json` beside
  `engine` before the first dispatch and never rewrites it on a resume, records
  each story's run dir at dispatch rather than on return, and resumes with
  `conduct-pool.sh --session-id <sid>`. A story marked incomplete whose lane is
  still up is a story mid-flight, not a story to start again.

- promote 2026-09-12 (lane dispatch): **`args.json` is built with `jq -n
  --arg`, not `printf`.** A double quote or backslash anywhere in the HQ install
  path or the target work dir made the `%s` substitution emit invalid JSON, and
  the runner then failed on `--args` before the lane existed — in a log nobody
  was watching yet.

- promote 2026-09-12 (lane dispatch): **the engine-group confirmation applies to
  every waiter outcome, not just the timeout.** The previous entry added the
  check to the `deadline` branch only, which left the more common one wrong:
  `died` and `never-started` are statements about the *wrapper* process, and a
  SIGKILLed wrapper cannot take its runner's detached child with it. Releasing
  the slot on `died` therefore started a replacement worker on top of a live
  engine still committing to the same repo. The confirmation is now one block
  that runs on whatever outcome the waiter produced and sets `engine_gone`; the
  deadline branch folds that result in rather than keeping its own copy, and the
  pool protocol's unconfirmed-lane carve-out is reworded to cover every outcome.
  "Gone", for the purpose of releasing a slot, now means both halves: the waiter
  reached an outcome *and* the engine group is empty.

- promote 2026-09-12 (lane dispatch): **`/run-project` no longer claims a run
  that drives itself after its session ends.** Detaching the stories made the
  in-flight story survive a compaction or a restart, and the skill generalised
  that into "a run survives the parent session". Only the story does. The
  waiter, the result validation, the slot release and the dispatch of story N+1
  are all parent-side, so a session that ends mid-run finishes one story and
  then stops — it does not auto-advance. The frontmatter, Step 3's rationale
  and the Ralph/headless section now say exactly that, and name what the
  stronger guarantee would take (the coordinator loop dispatched as its own
  lane, which does not exist). "Unattended" is scoped to no prompts between
  stories *within* a session, and the recovery note says a new session picks
  the run back up rather than implying it resumes itself.

- promote 2026-09-12 (lane dispatch): **a lane's result is read from
  `agent-1.result.json`, never from `lane.log`.** `lane.log` is the runner's
  whole stdout — narration plus `JSON.stringify(result)` — and a schema-less
  `agent()` returns the engine's reply as *text*, so the value there is a JSON
  **string** containing the worker's JSON, not the worker's object. `jq -e .`
  against it succeeds while `.status`, `.workers_run` and `.evidence` all come
  back empty: `/run-project` would have waved through a story it never read, and
  its worker-proof gate would have rejected a worker that did run its phases.
  The protocol now names the runner's result envelope
  (`workflow-runner.mjs:1169-1173`) and shows the two-step unwrap — `jq -r
  '.value'` to strip the envelope, then parse the contract — with
  `agent-1.last.md` as the fallback when a lane died before the envelope was
  written. `/conduct`'s outcome table and all three `/run-project` call sites
  point at the same file.

- promote 2026-09-12 (lane dispatch): **the runner journals the engine's process
  group, and the deadline handler verifies it before authorising a recycle.**
  `CONDUCT_EXIT=` proves the *runner* exited; it does not prove the tree is
  down. If the engine's group leader dies on SIGTERM but a descendant ignores
  it, `child.on('close')` (`workflow-runner.mjs:1057-1061`) removes the child and
  calls `onAllChildrenGone` immediately — retiring the runner before its own
  five-second SIGKILL escalation (`:1462-1465`) ever fires, so the survivor
  outlives the marker. Nothing outside the runner can name that group, because
  the runner is what spawned it detached. It now writes
  `{ event: 'agent-spawned', pgid }` to `journal.jsonl`, and the handler reads
  that pgid back, kills the group if it is still populated, and downgrades the
  stop to unconfirmed if anything survives. An unconfirmed stop still blocks the
  recycle rather than authorising it.

- promote 2026-09-12 (lane dispatch): **every dispatch mints a fresh run dir,
  including a resume.** Relaunching into a completed lane's directory looked
  tidy and was a race: the old `lane.log` still held `CONDUCT_EXIT=` and the pid
  files still named the finished process, while the new child does not truncate
  that log until it is already detached. A waiter armed in between read the
  *old* marker, called the new lane finished, and released a slot that was still
  live. Clearing the files first only narrows the window. Lane continuity never
  needed the directory anyway — it lives in the slot's `handoffs.jsonl`, which
  is keyed by worker and outlives any single run. `/conduct`'s resume branch now
  reuses the **slot**, not the directory, and records the new run id against it.

- promote 2026-09-12 (lane dispatch): **no caller spells its own run-dir path.**
  The previous entry moved the run dir into the protocol but left three call
  sites still naming `workspace/tmp/workflow-runner/{caller}-{lane}-$TS` — against
  a `$TS` that no longer existed — so a reader following the more specific
  instruction recreated the exact cross-session collision the fix removed.
  Callers now supply `{caller}` and `{lane}` only; the protocol mints the path.
  A check fails the build if either skill contains a `workspace/tmp/workflow-runner/`
  path at all, because a caller-side copy is the drift, not a particular wrong
  value.

- promote 2026-09-12 (lane dispatch): **run directories are session-scoped and
  minted with `mktemp -d`.** The path was
  `workspace/tmp/workflow-runner/{caller}-{lane}-$TS` at second resolution, and
  `explorer` / `regression-gate` are constant lane ids while story ids like
  `US-001` repeat across projects — so two sessions dispatching in the same
  second computed the *same* path and the second overwrote the first's brief,
  `args.json`, pids, deadline and log. Pools are session-scoped, so nothing
  serialised those launches. The consequence is a lane executing another tenant's
  brief, not merely a clobbered log. `$SID` separates sessions; `mktemp -d`
  closes the race inside one. Existing run dirs are unaffected; the change
  applies to newly minted ones.
- promote 2026-09-12 (conduct): **`/conduct` releases its slot before verifying
  and retrying.** Step 6 verified the result, re-`assign`ed the same worker on
  failure, and only then recorded the slot idle — so the retry hit exit 4 and
  recovery stalled on a lane that had already exited. The release is now step 1,
  matching `pool-lane-protocol.md` §6 and the two other callers. Its hung-lane
  row also stopped recommending `kill -- -<pid>` on the group named in the
  runner's warning: the engine runs detached in a group of its own, so that
  leaves it alive while appearing to succeed. It now routes to the dispatch
  protocol's stop procedure.

- promote 2026-09-12 (lane dispatch): **stopping a timed-out lane goes through
  the runner, not through the process group.** `workflow-runner.mjs` spawns the
  engine CLI with `detached: true`, so the engine leads its *own* process group —
  signalling the wrapper's group never reaches it, and `pgrep -g` on the wrapper
  cannot see it, so an "empty" group proved nothing. Worse, the runner's own
  SIGTERM handler escalates to SIGKILL after exactly 5 seconds, which the
  previous handler's 5-second sleep raced: SIGKILLing the runner at t=5s could
  stop that escalation from ever firing and orphan the engine mid-write. The
  launch now records `runner.pid` alongside `lane.pid`, and the deadline handler
  signals the runner and waits up to 30s for the wrapper's `CONDUCT_EXIT` marker
  — the runner's `killTree` is the only code that holds the engine's group id,
  and its exit is the only honest proof the tree is down.
- promote 2026-09-12 (lane dispatch): **an unconfirmed stop no longer authorises
  a recycle.** If the marker never arrives, SIGKILLing the wrapper group is a
  last resort that explicitly does not clear the engine (a SIGKILLed runner
  cannot run `killTree`). The slot stays `running`, the operator is told the
  engine may still be live, and a human decides. Only a clean stop earns
  `recycle --force`. `pool-lane-protocol.md` §6 carries the same carve-out.
- promote 2026-09-12 (pool protocol): **§6 now says release on process
  completion, not on result validation.** It still read "once the reply is back
  and validated", which contradicted both callers: `/run-project`'s one retry on
  malformed JSON and `/execute-task`'s debugger recovery both re-`assign` the
  same worker, so a slot released only after the JSON validated sent exactly
  those retries to exit 4, stalling instead of producing `INVALID_RETURN_FORMAT`.
  One ordering now, stated in the file both callers read: release first, then
  parse.

- promote 2026-09-12 (lane dispatch): **the deadline is persisted to
  `{run dir}/deadline`.** Launch and wait are two separate calls in two
  processes, so the previous shell variable was empty in the waiter and
  `[ "$(date +%s)" -ge "" ]` errored on every iteration — an inert guard that
  read as a working one. On disk it also survives a parent restart re-arming a
  waiter against a lane already in flight. A waiter that finds no deadline file
  now refuses to start rather than degrading to an unbounded wait.
- promote 2026-09-12 (lane dispatch): **the deadline handler signals the process
  group, not the recorded pid.** `lane.pid` is the wrapper `bash -c`;
  `workflow-runner.mjs` and the engine CLI are its descendants. `kill -TERM
  "$pid"` removed the wrapper and left the runner working, after which
  `kill -0 "$pid"` failed and the lane was reported gone — a false clearance that
  authorised recycling a slot whose agent was still writing to the repo. Verified
  directly: killing a `setsid` wrapper left both children running while the
  liveness check said "gone". Now `kill -- -"$pgid"` and `pgrep -g "$pgid"`, and
  the slot may only be retired once the **group** is confirmed empty. This is
  what the existing proof-of-escape check (pgid == sid == pid) was always for.
- promote 2026-09-12 (lane dispatch): **the engine roster moved into the dispatch
  protocol, with a deterministic rule.** `/run-project` pointed at "the dispatch
  protocol's roster", which did not exist there — the roster lived only in
  `/conduct`, so a bare `/run-project` on a host with several CLIs had no defined
  choice and could reach the launch with `{engine}` unexpanded. Resolution is now
  stated once: an engine the user named, else the caller's declared default, else
  the first of `codex`/`grok`/`claude` that resolves — **resolved once per run and
  reused for every lane in it**, recorded in `state.json`. Mixed engines across
  one run's stories give results that are not comparable and a failure you cannot
  attribute. `/conduct`'s roster section now references the shared one.

- promote 2026-09-12 (lane dispatch): **the waiter now enforces a wall-clock
  deadline.** `workflow-runner.mjs`'s `timeoutSecs` is a *soft* timeout — it
  prints a repeating `TIMEOUT WARNING` and explicitly does not kill the child —
  so a waiter looping for the `CONDUCT_EXIT` marker waited forever on a hung
  lane, and `/run-project --ralph-mode`'s `blocked: TIMEOUT` contract could never
  fire. The waiter now exits with one of three outcomes (`exited`, `died`,
  `deadline`), and `deadline` is the only one that leaves a live process: stop
  it, **confirm the pid is gone**, and only then `recycle --force` its slot.
  Retiring a slot on an unverified pid puts two workers in one lane, which is
  exactly what the running-lane guard exists to prevent. `--timeout N` is wired
  to this deadline, not to `timeoutSecs`.
- promote 2026-09-12 (lane dispatch): **the lane tier is a caller-supplied
  placeholder.** It was hardcoded `exec`, so `/run-project`'s preflight explorer
  — which the skill requires to run at `plan` — silently did its analysis on the
  throughput model. Every caller now names its tier, and both skills say why it
  is never implicit.
- promote 2026-09-12 (lane dispatch): `/run-project`'s Step 1 reconciled with the
  detached default. `--inline` still meant "story-level Codex sub-agent
  execution" and the legacy note still read "Ralph now runs inline in the active
  session" — both false, and a reader following Step 1 would have kept the old
  in-session path alive. `--inline` now means *story-delegated* (as opposed to
  `--interactive`'s parent-driven editing), and the legacy note distinguishes the
  retired `nohup run-project.sh --engine claude` subprocess from today's pooled,
  capped, worker-authoritative lanes.

- promote 2026-09-12 (run-project detached lanes): **`/run-project` now dispatches
  each story as a detached lane, not an in-session sub-agent.** The default path
  claims its `story:{worker-id}` pool slot exactly as before, then launches a
  `setsid` `workflow-runner.mjs` process per
  `.claude/skills/_shared/lane-dispatch-protocol.md` — the same mechanism
  `/conduct` has always used. Three consequences, in order of how much they
  matter: a run now **survives the parent session** (compaction, restart, or an
  ended session used to kill work mid-story, leaving the slot marked running); a
  story can be **corrected while it runs** through the lane's drop box instead of
  being killed and relaunched; and a host with **no in-session sub-agent
  primitive** can run a project at all. The preflight explorer and the regression
  gate moved the same way. Ralph/headless is the same loop unattended, and its
  old claim that it "does not launch a detached subprocess" is now false and has
  been removed.
- promote 2026-09-12 (run-project detached lanes): **in-session `spawn_agent` is
  now the documented fallback, not the default.** It is correct only where no
  `codex`/`grok`/`claude` CLI resolves. Probe once per run, before the first
  dispatch, and say which path you took — the failure this ordering prevents is
  discovering a missing engine once per story, halfway through a PRD. Everything
  around the dispatch is identical on both paths: the pool claim, the
  `RETURN CONTRACT: json`, the one retry on malformed JSON, the worker-proof
  gate, and the evidence check. Operator action: none, unless you run HQ on a box
  with no coding-agent CLI installed, in which case behaviour is unchanged.
- promote 2026-09-12 (run-project detached lanes): new
  `.claude/skills/_shared/lane-dispatch-protocol.md` owns the launch mechanism —
  brief on disk, `args.json`, the `setsid` block with its proof-of-escape check,
  `record --status running` against the run-dir basename, the background waiter
  with its liveness clause, the drop box, and reading the outcome. `/conduct`
  Step 5 collapsed to a reference plus its own specifics. Two skills performing
  the same protocol from two copies is the exact shape that produced three review
  rounds of drift on the pool work; this is the same structural fix.
- promote 2026-09-12 (run-project detached lanes): **a lane now exports
  `HQ_SESSION_ID`.** The runner passes its environment to the engine, and
  anything the lane runs that touches the pool — `/execute-task` claiming phase
  slots inside a story lane, above all — resolves its session from that variable
  first and the `.current` file only as a fallback. Without the export a lane
  that outlived its parent session claimed slots in whatever session `.current`
  named by then, so the cap silently stopped holding. This also fixes the same
  latent gap in `/conduct`, whose launch block never exported it.
- promote 2026-09-12 (run-project detached lanes): the two launch-quoting checks
  moved from `conduct-worker-selection.test.sh` to the new
  `orchestrator-skills-dispatch-lanes.test.sh`, which is where the launch block
  now lives. The block is validated once, at its definition, rather than from
  whichever caller happens to quote it. New CI step: **Orchestrator skills
  dispatch detached lanes (run-project + conduct)**.

## Release: v15.0.128-beta.3

- promote 2026-09-11 (conduct pool): **`record` no longer accepts `--status recycled`.** That path
  marked a running slot recycled and cleared its sub-agent id directly, routing around both the
  running-lane guard and the handoff purge — a caller could retire a live lane and be granted its
  replacement while the original kept working. Retirement is `recycle` (with `--force` only after a
  confirmed stop) or `cancel`.
- promote 2026-09-11 (orchestrator skills use the pool): the dispatch sequence is now executable on
  both runtimes, and says which is which. Codex gets an id between `spawn_agent` and `wait_agent`, so
  `record --status running` goes there. Claude Code's `Task` dispatches and blocks in one call, so
  record first with `--subagent-id pending` and replace it on return. Recording *after* the wait
  would leave live work marked `claimed` for its whole duration — exactly the state `cancel` is
  allowed to retire.

- promote 2026-09-11 (conduct pool): **a slot now has four states, not three.** `assign` grants a
  lane as `claimed`; `record --status running` is what attaches a sub-agent and makes it `running`.
  `cancel` keys on `claimed`, and on nothing else. The emptiness of `subagent_id` would not have
  worked as the test: a
  *resume* claim keeps the previous lane's id while it waits to be dispatched, so keying on
  emptiness refused exactly the cross-tenant reset `cancel` exists for. `claimed` counts against the
  cap and makes a second `assign` for that worker exit 4, so the slot is held from the moment it is
  granted. `recycle` still works on a `claimed` lane — there is no sub-agent to strand — so the
  guard does not block its own remedy.
- promote 2026-09-11 (conduct pool): `assign`'s own exit-3 and exit-4 diagnostics no longer
  recommend an unforced `recycle`, which the running-lane guard makes fail deterministically. They
  now say to wait, and name `--force` (after a confirmed stop) or `cancel` (for an undispatched
  claim) as the applicable escapes.
- promote 2026-09-11 (conduct pool): **`/conduct` lanes are namespaced `conduct:{worker-id}`.** A
  `/conduct` lane stores a workflow-runner run directory as its `subagent_id` while an
  `/execute-task` phase lane stores a `Task` / `spawn_agent` handle, and only the latter carries an
  `owner.json` stamp. Sharing the bare worker id meant a session that used both would hand one
  runtime's handle to the other's adapter, and let `/conduct` resume a phase lane with no ownership
  check. Three namespaces now: bare id for phases, `story:` for coordinators, `conduct:` for
  `/conduct`.

- promote 2026-09-11 (conduct pool): new verb `conduct-pool.sh cancel --worker-id <id>` — retire a
  claim that was never dispatched. `assign` grants every slot as `claimed`, so a caller that backs
  out (most often because the slot's ownership stamp names another tenant) hit the running-lane
  refusal and the ownership reset had no way to complete. `cancel` keys solely on `status ==
  claimed`, and refuses with exit 5 for anything else. It does **not** test whether `subagent_id` is
  empty: a resume claim keeps the previous lane's id, so emptiness would refuse exactly the reset
  this verb exists for. Status is a fact the helper records at grant time rather than an assertion
  it accepts, which is why `cancel` needs no `--force` and cannot abandon a live lane. It clears the
  slot's `handoffs.jsonl` and `owner.json` like `recycle` does.
- promote 2026-09-11 (conduct pool): `/conduct` step 3's exit-3 guidance no longer advertises an
  unforced `recycle`, which the new guard makes exit 5 deterministically. It offers waiting, or
  `--force` once the user has stopped the lane, or `cancel` for a claim it never launched.

- promote 2026-09-11 (conduct pool): **`conduct-pool.sh recycle` now refuses a running lane with
  exit 5.** Retiring a slot frees the pool entry and leaves the sub-agent alone — the pool records
  ids, it does not own processes — so retiring a live lane put the real child count over the cap and
  let the next claimant share a run directory with a process still writing to it. Wait for the lane
  and mark it `idle`, or stop it and pass `--force` to assert you did. The exit-3 guidance no longer
  points at `recycle` as an escape hatch.
- promote 2026-09-11 (conduct pool): recycling now **clears the lane's `handoffs.jsonl` and
  `owner.json`**, on both the explicit path and the LRU retirement inside `assign`. Recycling is how
  a fat lane is discarded; leaving the file behind meant the next claim of the same worker — same
  company, same project, so the ownership stamp matched — read back the whole transcript the recycle
  was meant to drop, growing without bound across recycles. A recycled lane always restarts cold.
- promote 2026-09-11 (orchestrator skills use the pool): the coordinator budget is
  `max(1, (CONDUCT_POOL_CAP - 2) / 2)`. The bare formula yields 0 at a cap of 2 or 3 — both accepted
  by the helper — which would permit no coordinator and stall `/run-project` before its first story.
  At those caps the reserved explorer/gate pair is what does not fit: recycle those slots once used
  and run one coordinator serially. A cap of 1 cannot host a coordinator and its phase at all, so the
  skill stops and offers a higher cap or `--interactive` rather than improvising.

- promote 2026-09-11 (orchestrator skills use the pool): the lane protocol is now stated **once**, in
  `.claude/skills/_shared/pool-lane-protocol.md`, and `/execute-task` and `/run-project` follow it
  rather than restating it. Every time the two descriptions drifted during review, one of them was
  wrong — a coordinator id the pool rejects outright, an ownership check that existed on only one
  dispatch path, a resume branch with no executable body. The protocol covers namespaces and the id
  charset, the `assign` exit codes, `mkdir -p` before any slot-directory access (`assign` writes a
  pool entry in `meta.yaml` and nothing on disk, so the first use has no directory), the ownership
  stamp, the disk-backed restart for runtimes with no resume primitive, release, and the nesting
  budget.
- promote 2026-09-11 (orchestrator skills use the pool): `/run-project`'s own lanes are
  ownership-checked too. `explorer` and `regression-gate` are constant ids shared across every
  project and company, which makes them the lanes most likely to hand one tenant's context to
  another — a second `/run-project` in one session would otherwise resume the first one's planning
  transcript, or a gate lane carrying another company's repo list.
- promote 2026-09-11 (orchestrator skills use the pool): the coordinator `resume` branch has a
  concrete body. Codex `spawn_agent` always starts a new agent, and `assign` has already marked the
  slot `running` by the time `resume` comes back, so a coordinator that could not act on it left the
  lane stuck and every later claim for that worker at exit 4.

- promote 2026-09-11 (orchestrator skills use the pool): story coordinator lanes are namespaced
  `story:{worker-id}` (a colon, because the pool rejects ids outside `[A-Za-z0-9._:-]`); the phases inside them claim the bare worker id. A coordinator holding
  `backend-dev` would send its own `api_development` phase to `assign` exit 4 — waiting on a lane the
  coordinator itself holds, with the coordinator waiting on that phase. Neither ever finishes.
  Concurrent stories are capped at `(CONDUCT_POOL_CAP - 2) / 2` (**3** at the default cap of 8) so
  every live coordinator can still claim the one phase lane it needs; fill the pool with coordinators
  and every one blocks on exit 3 with nothing running that could release a slot.
- promote 2026-09-11 (orchestrator skills use the pool): lane continuity moved from
  `workspace/orchestrator/{project}/pool/…` to `workspace/sessions/{session-id}/pool/…`, beside the
  pool state that owns the slot. A project slug is not unique across companies, and a project-keyed
  file outlives the session that wrote it — either way a lane reads another tenant's or another day's
  history as its own and skips live work. The directory carries an `owner.json` stamp (company,
  project, session); a missing or mismatched stamp means `cancel` the claim, delete its
  `handoffs.jsonl`, re-stamp, and dispatch cold. The check runs before the spawn/resume split, so a
  runtime with a native resume primitive cannot skip it, and the reinitialise matters because 6d's
  append is unconditional — leaving the file would file this owner's phases under the previous
  owner's stamp.

- promote 2026-09-11 (orchestrator skills use the pool): `/execute-task` step 6c no longer spawns a
  sub-agent per phase. It claims the worker's lane with `conduct-pool.sh assign --worker-id <id>`
  first, resumes on `action=resume`, and records the lane `running` around the blocking call and
  `idle` once the phase JSON validates. `assign` exit 3 (pool at cap, all running) and exit 4 (this
  worker's lane is already running) both mean wait — neither changes the pool, so dispatching past
  them is how a run exceeds the cap or relaunches into a directory a live process still owns.
- promote 2026-09-11 (orchestrator skills use the pool): neither Claude Code's `Task` nor Codex
  `spawn_agent` can re-enter an existing sub-agent, so 6c documents the honest fallback instead of a
  fake resume — dispatch afresh, point the worker at
  `workspace/sessions/{session-id}/pool/{worker.id}/handoffs.jsonl`, and record the new sub-agent id
  against the **same** slot. The cap counts lanes, not restarts. The inline codex-reviewer path is
  unchanged and takes no slot, because it runs in the parent.
- promote 2026-09-11 (orchestrator skills use the pool): `/run-project` fan-out is now bounded by the
  pool rather than by the story count. The preflight explorer, each story's classified worker, and
  the regression gate are named slots that resume. **Typical run: 3-4 live lanes. Worst case:
  `CONDUCT_POOL_CAP`, default 8** — a 40-story PRD opens no more lanes than a 4-story one. Stories
  that classify to the same worker id serialize on that one lane. Parallel swarming survives but is
  capped at the pool's remaining capacity instead of dispatching one worker per story.
- promote 2026-09-11 (orchestrator skills use the pool): `--interactive` is unchanged — it runs in
  the parent and claims no slots. The JSON return path is unchanged and pinned by a test:
  `RETURN CONTRACT: json`, `jq -e` validation, `INVALID_RETURN_FORMAT`, the `workers_run` proof gate
  and `verify-story-deliverables.sh` all still apply.

- promote 2026-09-11 (ralph orchestrator policy): the hard policy
  `ralph-orchestrator-context-discipline` no longer mandates a fresh worker per story. Rules 6 and 8
  previously required "one preflight explorer, one story worker per story" — which directly
  contradicted the session worker pool the orchestrator skills now use. They now require **one live
  slot per HQ worker id**, claimed through `core/scripts/conduct-pool.sh` and reused across stories,
  with compaction or recycling at cap rather than a new child each time. Two stories that classify
  to the same worker **serialize on that slot**; they do not get one each.
- promote 2026-09-11 (ralph orchestrator policy): everything that made the policy worth having is
  unchanged and is pinned by a test — `RETURN CONTRACT: json`, `jq` parsing, one retry,
  `INVALID_RETURN_FORMAT`, one-line narration, no parent phase simulation, bounded parent log reads,
  and budget-aware regression gates. Extra slots beyond one per worker still require a high-risk
  trigger or an explicit user opt-in after stating the token and runtime cost.
- promote 2026-09-11 (ralph orchestrator policy): the rationale is rewritten. Fresh-context-per-story
  is no longer presented as the token-saving mechanism; parent thinness, JSON returns and the pool
  cap are. Resuming a slot is now the point rather than a compromise — it reuses the prompt cache and
  keeps the worker identity the operator chose, where a cold start pays for both again every story.
- promote 2026-09-11 (ralph orchestrator policy): the policy `when:` trigger now covers `/conduct`
  and `/execute-task` alongside `/run-project` and `/run-pipeline`, so the JSON contract applies
  everywhere the pool is used to orchestrate.
- promote 2026-09-11 (ralph orchestrator policy): `core/knowledge/public/workers/README.md` records
  the divergence rather than leaving "Fresh context per task (no context rot)" reading as absolute.
  `/run-project --interactive` is unaffected and stays parent-driven.

## Release: v15.0.128-beta.1

- promote 2026-09-10 (Grok HQ execution): Grok sessions auto-bind `company_slug` + scope-capability on SessionStart from a safe source only (parent session, `HQ_SPAWN_COMPANY`, or already-written meta — never cwd guessing). Unbound company-path tools were the dominant Grok failure (mandatory-scope denials).
- promote 2026-09-10 (Grok HQ execution): `GROK_SESSION_ID` is a first-class session-id env var. Empty Glob/`list_dir` deny with "pass a scoped path" instead of the HQ-root timeout dump. SessionStart writes `workspace/sessions/<sid>/skill-catalog.txt`.
- promote 2026-09-10 (Grok HQ execution): headless Grok spawn (workflow-runner + fleet adapter) uses `--always-approve`, `--output-format json`, and `--json-schema` when the CLI supports it. `/conduct` detaches with `core/scripts/hq-detach.sh` (Python `os.setsid` on macOS; stock Darwin has no `setsid(1)`).
- promote 2026-09-10 (Grok HQ execution): new `.grok/rules/` notes for skill catalog, prompt-queue `task_already_running`, worktrees vs `repos/`, session bind, and MCP default-on (`hq-work` only in the project file). Operator action: disable or auth unused Superhuman MCP profiles in user Grok config if start banners bother you.
- promote 2026-09-11 (supply-chain guard): the `npm/pnpm/yarn/bun` install guard
  (`.claude/hooks/block-unsafe-package-install.sh`) no longer mis-reads the value
  of a space-separated flag as a package name. `npm i -g --prefix /path <pkg>`
  used to have `/path` treated as an untrusted positional package, which blocked
  the sanctioned first-party / allow-listed global install (e.g. upgrading the hq
  CLI into `~/.local`). Value-taking flags (`--prefix`, `-C`, `--registry`,
  `--cache`, `--dir`, ...) now have their value token skipped. The guard is
  unchanged for genuinely untrusted installs -- a new 12-case regression suite
  (`.claude/hooks/tests/block-unsafe-package-install.test.sh`) pins that
  `--prefix /path left-pad` still blocks. No operator action required.

## Release: v15.0.127-beta.6

- promote 2026-09-11 (conduct worker definitions): `/conduct` now **loads the worker it picks**.
  Previously the worker id was only a pool-slot label: the registry was consulted, a name was
  chosen, and then a generic lane was launched — so dispatching to `code-reviewer` and dispatching
  to `unmatched` produced identical lanes. `/conduct` now reads `{path}/worker.yaml` for the matched
  worker and builds the brief from it: the worker's name and description open the brief, its
  `instructions` are carried verbatim, and the paths to its `skills[].file`, `context.base` and
  `knowledge` entries are passed so the lane reads its own procedures. The lane's `timeoutSecs` now
  comes from `execution.max_runtime` instead of a fixed 15 minutes.
- promote 2026-09-11 (conduct worker definitions): a worker's `verification.approval_required` and
  `verification.human_checkpoints` are now **binding**. A worker that declares
  `before_merge_production` has that checkpoint carried into its brief as an explicit
  stop-and-report, and the parent asks the user before telling the lane to proceed. A declared human
  gate that does not happen is a defect, not a shortcut.
- promote 2026-09-11 (conduct worker definitions): the Step 2 selection filter was unfollowable. It
  told the agent to consider workers "whose `scope` is the active company, `public`, or personal",
  but registry entries have never carried a `scope` field — they carry `company`, `visibility` and
  `team`. The filter is now written against the real fields: `status` must be `active`, and
  `company` must be empty (a core or personal worker, available to every tenant) or exactly the
  active company slug. An entry naming a different company is out of scope, stated as a tenancy
  boundary rather than a preference.
- promote 2026-09-11 (conduct worker definitions): `execution.model`, `codex_model` and
  `codex_flags` are deliberately NOT applied. They name models for a delivery path `/conduct` no
  longer uses; the engine is the operator's session-wide choice and the tier follows the task.
- promote 2026-09-11 (conduct worker definitions): `context.base` paths are resolved before they
  reach the brief rather than passed through. They are not uniformly rooted — some are relative to
  the HQ root, some to `core/` — and many are stale: of 175 distinct entries shipped today, 109
  resolve from the HQ root, 17 only under `core/`, and 49 point at nothing at all. Each entry is
  tried against the HQ root, then `core/`, then the worker's own directory, and an entry that
  resolves nowhere is dropped instead of being handed to the lane as a missing path.
  `skills[].file` needs no such treatment: all 44 shipped entries resolve against the worker's own
  directory.
- promote 2026-09-11 (conduct worker definitions): new test
  `core/scripts/tests/conduct-worker-selection.test.sh` pins the skill to both schemas it reads, and
  parses the detached lane launch at **both** levels — the outer script and the inner `bash -c`
  body. An unbalanced quote inside that body is just a character to the outer shell, so it survives
  an ordinary syntax check and only fails at dispatch, in a detached process whose output goes to a
  log nobody is watching yet.

## Release: v15.0.127-beta.5

- promote 2026-09-11 (conduct lane drop box): a `/conduct` lane is no longer sealed once it
  launches. Every lane now carries a drop box, and a hook inside the lane delivers from it on
  the lane's next tool event, so a correction reaches a worker **while it is still working** —
  no kill, no relaunch, no waiting for the task to finish.
  `bash core/scripts/conduct-inbox.sh send --run-dir <dir> --text "..."` queues a message; the
  lane picks it up on its next tool call and treats it as an operator instruction outranking
  its brief. The channel is one-way: the lane cannot reply, and its answer still arrives in its
  final output. Messages queue, so sending before the lane's first tool call is safe, and each
  is delivered exactly once with the consumed copy retained under `inbox/claimed/` as a record
  of what the lane was actually told.
- promote 2026-09-11 (conduct lane drop box): **every engine is reachable mid-task, but not the
  same way.** (Superseded 2026-09-26 — see the Grok hook capabilities entry at the top. The Grok
  claims in this paragraph were wrong; delivery is now uniform across engines.) Codex and Claude lanes take the message quietly on `PostToolUse`, as context before
  the model's next step, with `Stop` as a backstop for anything queued late. Grok cannot be handed
  context on any event — its adapter routes passive-hook output to diagnostics and cannot block a
  `Stop` — so a Grok lane is reached on `PreToolUse` instead: the message arrives as a denied tool
  call whose reason is the text, and the lane is told the call was not blocked on its merits and to
  retry. That costs the interrupted call, so prefer Codex for work you expect to steer often. Grok
  deny reasons truncate near 1200 characters; keep messages to that engine short.
- promote 2026-09-11 (conduct lane drop box): a message is only ever consumed on an event that can
  actually reach the model. Draining on an event that cannot would not delay it — it would destroy
  it, silently, while the operator believed a correction had landed. The lane exports
  `HQ_CONDUCT_ENGINE` at launch so the hook can tell which route applies; a lane predating that
  export is treated as Codex.
- promote 2026-09-11 (conduct lane drop box): new script `core/scripts/conduct-inbox.sh`
  (`send | drain | list | clear`) and new hook `.claude/hooks/conduct-lane-inbox.sh`, registered in
  `.claude/settings.json` on `PostToolUse` (matcher `*`), `Stop`, and `PreToolUse` for the six tool
  matchers Grok dispatches (Bash, Read, Write, Edit, Grep, Glob), and allowlisted in all three
  `hook-gate.sh` profiles. The hook is gated on `HQ_CONDUCT_RUN_DIR`, which only a `/conduct` lane
  exports, and exits before touching disk when that variable is absent — so it is inert in every
  ordinary session despite the wildcard matcher, and it never blocks a lane that is legitimately
  finished.

## Release: v15.0.127-beta.2

- promote 2026-09-10 (conduct worker pool): `/conduct` no longer starts a new in-session
  subagent for every task. Each task is now matched to a long-lived HQ worker from a capped
  session pool and run as a detached `core/scripts/workflow-runner.mjs` lane on a chosen
  engine (Codex, Grok, or Claude) — the same runner `/orchestrate` already uses. Two things
  change for you. Lanes are ordinary OS processes, so they survive a compaction or a session
  restart, and `/conduct` now works on hosts with no in-session subagent support at all.
  And the number of live children is bounded: typical 8 or fewer, worst case
  `CONDUCT_POOL_CAP` (default 8), instead of one per task. Fifty tasks map onto at most
  eight workers.
- promote 2026-09-10 (conduct worker pool): new script `core/scripts/conduct-pool.sh` —
  `list | assign | record | recycle | clear` over the `conduct_pool` list on
  `workspace/sessions/<id>/meta.yaml`. `assign` is the only command that decides anything:
  it returns spawn or resume, retires the least-recently-used idle worker when the pool is
  full, and refuses without changing anything in two cases: exit 3 when every slot is
  running, and exit 4 when the requested worker's own lane is still going (only an idle slot
  is resumable — relaunching into a live lane's run directory would overwrite the artifacts
  of a process still working). Every read-modify-write holds a per-session lock for the whole
  transaction, because `/conduct` dispatches independent tasks concurrently and the atomic
  file replace at the end is not enough on its own. Override the cap with `CONDUCT_POOL_CAP`. The pool is deliberately not written through `hq-session.sh set`,
  which replaces a single-line `key: value` and cannot round-trip a nested list.
- promote 2026-09-10 (conduct worker pool): the session key `/conduct` persists is now
  `conduct_engine` (codex, grok, or claude), replacing `conduct_agent` (grok, opus, gpt,
  claude-*), which named in-session subagent types that no longer exist on this path. A
  session still carrying `conduct_agent` is harmless — `/conduct` ignores it and asks once
  for an engine. `/conduct off` clears both the pool and the engine.
- promote 2026-09-10 (conduct worker pool): `/run-project` inline and ralph modes are NOT
  changed in this release and still spawn per story; `/run-project --interactive` is
  unchanged. Catalog suggest-create is not part of this work.

## Release: v15.0.126-beta.2

- promote 2026-09-09 (goals and tasks board): tasks are a first-class list on the board
  rather than user stories inside a standing bucket project. A board's `tasks[]` holds
  loose work with its own small shape (`id`, `title`, `description`,
  `status: open|blocked|done`, `priority`, `objective_id`, `criteria[]`, `contacts[]`);
  `prd.json` user stories remain the shape for project-scoped work. This drops the
  `metadata.kind: "task_board"` bucket convention introduced in v15.0.126-beta.1 — a
  bucket project never completes and pollutes the project registry, and `prd.json`
  carries `branchName` / `e2eTests` / `files` / `dependsOn`, none of which mean anything
  for an errand.
- promote 2026-09-09 (goals and tasks board): the owner's board is `personal/board.json`
  in the overlay at the HQ root, not under `companies/personal/`. The personal vault's
  `.hqinclude` allowlist does not cover the reserved personal company scope, so a board
  kept there is invisible to an agent reading that vault; `personal/board.json` must
  itself be listed in `.hqinclude`. `core/scripts/hq-task.sh` gains
  `list|add|done|block|reopen|goals`, defaults to `personal/board.json`, and takes
  `--company <slug>` for `companies/<slug>/board.json`. Corrects the default and the
  guidance shipped in v15.0.126-beta.1. Anyone who created a bucket project under that
  release should move its stories into their board's `tasks[]` and delete the bucket;
  other companies are unaffected.

## Release: v15.0.126-beta.1

- promote 2026-09-09 (goals and tasks board): new concept doc
  `core/knowledge/public/hq-core/goals-and-tasks-board.md` — documents the three-layer
  pattern for recording intent on a company board (objectives and key results in
  `board.json` v2 → projects → tasks as `prd.json` user stories), the standing
  "task bucket" convention for errands too small to deserve a project
  (`metadata.kind: "task_board"`, conventionally named `life-admin`), and the read/write
  contract an agent follows when working a board. No new file formats; it reuses
  `board.json` v2 and ordinary project `prd.json` files, so existing board tooling needs
  no changes.
- promote 2026-09-09 (goals and tasks board): new scripts `core/scripts/hq-task.sh` and
  `core/scripts/hq-task.mjs` — `hq-task.sh list|add|done|reopen` manages tasks on a standing
  task-bucket project without hand-editing `prd.json`, assigning story ids and keeping the
  story shape consistent. Defaults to `--company personal --project life-admin`; works
  against any company and bucket name. No action required; existing projects are untouched
  unless the script is pointed at them.
- promote 2026-09-08 (access ladder): new core skill `.claude/skills/hq-access/SKILL.md`
  — `/hq-access <path-or-query>` diagnoses a vault file you cannot find or open as exactly
  one of never-existed / not-synced / no-access, fetches and pins when you have access,
  repairs sync when the fetch fails, and asks the prefix owner for a read grant after one
  confirmation via a DM with a one-click `hq files share` prompt. Runs `hq access` from
  `@indigoai-us/hq-cli` >= 5.109.0 and falls back to the same ladder over existing
  commands on older CLIs. No action required; upgrade the CLI to get the native command.
- promote 2026-09-08 (access ladder): new hard policy
  `core/policies/hq-failed-file-open-runs-access-ladder.md` — a failed Read/cat/open of a
  `companies/<slug>/…` path must run `/hq-access` before replying "file does not exist".
- promote 2026-09-08 (access ladder): `hq-files`, `hq-sync`, and `hq-heal` skills gain
  one-to-two-line pointers at `/hq-access`; `hq-heal` gains an `access` error class whose
  recipe is the ladder. No behavior change for existing flows.
- promote 2026-09-08 (quick reference): `core/knowledge/public/hq-core/quick-reference.md` gains an `hq access <path-or-query>` row in the `hq files` table. Docs only.

## Release: v15.0.121-beta.8

- promote 2026-09-04 (work-mesh progress noise): `core/scripts/work-mesh.mjs`
  — `report` / `progress` / `story` with no `--summary` and no task transition
  no longer post a thread event (local skip note, exit 0); task-only moves post
  a specific synthesized line (`US-003 → doing: <title>`); identical summaries
  for the same project within 10 minutes are coalesced client-side via
  `~/.hq/work-mesh/cache/last-progress.json`; the "Project work is in
  progress." / "Work is underway." placeholders are removed. **Impact:** skills
  that called `report` without a summary now produce no channel row
  (intended); board moves are unaffected. No action needed.
- promote 2026-09-04: policy `hq-project-work-mesh-reporting` bumped to v3 —
  progress reports must carry a real summary. No action needed.

## Release: v15.0.120-beta.7

- **Desktop sessions now get named on the first turn:** outside the terminal
  CLI the hook's `sessionTitle` never lands — the desktop host keeps its own
  title store and honours only its auto-titler and the model's
  `set_session_title` call. The three earlier session-title fixes therefore
  only ever reached terminal sessions. In `mode: full` the hook now injects a
  one-time instruction on the first user prompt telling the model to name the
  session immediately in HQ grammar, carrying the company/project the hook
  already resolved (or asking it to derive both from the message when nothing
  resolved). It never fires on SessionStart, in `mode: auto`, or once a session
  has been renamed by hand. No action needed.

## Release: v15.0.120-beta.4

- **HQ no longer names sessions `chat`:** when the hook could resolve neither a
  project nor a repo for a session, it emitted whatever was left — a bare
  command word (`chat`, `startwork`) or a lone org token (`HQ`). That is worse
  than silence twice over: it overwrites the host's written summary ("HQ core
  skill cloning") with a word that distinguishes nothing, and because the stub
  never changes, the wrapper's change-only cadence then keeps the session quiet
  for the rest of its life. Sessions were sitting on 1281 prompts still titled
  `chat`. The helper now prints nothing in that state, so the host's own title
  stands; the moment a project or repo resolves, HQ takes the title back. No
  action needed, and sessions that already resolve a project are unaffected.

## Release: v15.0.120-beta.4

- **New `/conduct` skill:** orchestrator mode that dispatches every task to a
  background worker agent on a user-chosen model (grok, opus, gpt, or native
  Claude opus/sonnet/haiku) so the parent session stays free to accept and
  route new messages. No migration steps required.

## Release: v15.0.120-beta.3

- **Desktop sessions no longer lose HQ naming permanently:** the one-time free
  pass that lets HQ ignore Claude Desktop's built-in auto-titler required proof
  that the title came from the session transcript. A desktop auto-title
  *inherited on resume* arrives in the `session_title` SessionStart input, when
  the transcript is often unreadable — the path may be absent, or the title line
  not yet flushed. Proof failed, the pass was withheld, and the session was
  muted for good with no `.autoname` file left behind to explain why. Resumes
  may now claim the pass unproven; `startup` (where `claude --name` is the only
  way a title can exist before any turn) and all other events still require
  proof, so `--name` and mid-session `/rename` back off exactly as before.

- **Sessions already muted by that bug now heal themselves:** the manual-rename
  marker short-circuits before any of the fixed logic runs, so affected sessions
  would have stayed muted forever. A mute carrying no `.autoname` sibling whose
  live title is in HQ grammar is provably wrong — a real rename is free-form
  prose — and is now cleared automatically so naming resumes. Mutes on prose
  titles, and mutes with a spent free pass (the documented second-rename
  back-off), are left untouched. No action needed.

## Release: v15.0.120-beta.2

- **First session title no longer drops the project:** `UserPromptSubmit` hooks
  run in parallel, so the session-title hook regularly computed its title before
  `auto-session-project` had written the session's project marker. The result
  was a projectless stub (`HQ`, `chat`) on a session's first prompt that only
  self-corrected on the following prompt. The hook now waits up to 2s — once per
  session, guarded by a `.projwait` state flag — for that marker before
  computing the title. Sessions that resolve no project pay the wait a single
  time, never per prompt. No configuration change; no action needed.

## Release: v15.0.117-beta.1

- **Session naming reminder now reaches the assistant:** the session-title
  grammar policy only triggered on prompts containing `session-title` or
  `rename`, words that do not occur in ordinary use, so the assistant was
  never told to name the session and titles fell back to the host autoname.
  The policy is now a per-session baseline (`on: [SessionStart]`,
  `when: always`) and states plainly that outside the terminal CLI — notably
  the Claude Code desktop app, which ignores `hookSpecificOutput.sessionTitle`
  and tracks sessions under its own ids — `set_session_title` is the only
  mechanism that names a session. Honouring `enabled`/`mode` in
  `settings/session-title.yaml` is unchanged; no action needed.

- **Claude Desktop auto-titler no longer disables HQ session naming:** Claude
  Desktop's built-in session auto-titler writes titles indistinguishable from
  a manual rename, which permanently tripped HQ's rename back-off on every
  desktop session. The session-title hook now ignores the first non-HQ title
  seen in a session's transcript (the auto-titler) and retakes the title; a
  second, different non-HQ title still counts as a real rename and backs off.
  New `desktop_autoname` key in `settings/session-title.yaml`
  (`ignore-first` default · `respect` restores the old behavior). No action
  needed unless you prefer the desktop auto-titler — then set
  `desktop_autoname: respect` in `personal/settings/session-title.yaml`.

- **Session title grammar reworked (supersedes the version shipped in
  v15.0.95-beta.1):** titles are now `{glyph} {COMPANY} · {subject}` with
  **exactly one** glyph, chosen by a four-tier precedence ladder — first tier
  that applies wins.

  1. *Needs you or finished* — 🙋 waiting on the user, 🤝 handed off to a person
     or fleet agent, 📤 closed with a handoff to resume from, ✅ shipped,
     🧊 parked.
  2. *Long-running by nature* — 🔁 recurring loop, 💬 standing channel.
  3. *Workflow stage* — 💭 exploring, 📐 planning, ⚡ building, 👀 in review,
     🧪 verifying.
  4. *Craft* — 🎨 design, ⚖️ legal, 💰 money, 📊 data, 🔎 research, 🔒 access,
     🛠️ tooling, ✍️ writing, 📣 growth, 🤖 agents, 📱 mobile, 🏗️ architecture,
     🧭 strategy, 🐛 incident, 🎟️ client, 🎤 music and events. This tier is open
     and is rendered *instead of* a stage glyph when the craft is the more
     interesting fact.

  v15.0.95-beta.1 shipped a `{icon} {CATEGORY} · {subject} · {phase}` form whose
  category token conflated two axes — sometimes a domain, sometimes a company —
  and fell back to a placeholder `🟦` when neither applied. The company now
  always leads the text and is never substituted with a generic token; when no
  company resolves, the token is omitted. `✅`, `📤` and `🤝` are three distinct
  states and are not collapsed: the work shipped, the session closed with
  resumable state, someone else owns it.

  **⛔, 🚫 and ⚠️ are banned by name** for "waiting on the user". A session with
  a question is working correctly; routinely spending a hazard glyph on a normal
  condition is how a warning stops meaning anything.

  `core/scripts/session-title.sh` emits a tier 2 or tier 3 glyph, the company
  and a slug. It never emits 🙋 (it cannot know that) and never a craft glyph —
  its only subject is a directory slug, so any keyword match against that slug
  would be redundant with the slug by construction. Both are left to the
  assistant, which sets a written subject via `set_session_title` once the
  session's purpose is clear.

  No action required for existing installations. Titles already emitted in the
  superseded form are replaced on the session's next title change; there is no
  migration step and no stored state to clear.

- **Session auto-naming is now a setting you can turn off:**
  `core/settings/session-title.yaml` ships the defaults; copy it to
  `personal/settings/session-title.yaml` to change them.

  - `enabled: false` — HQ never touches a session title. Claude Code's own
    auto-naming still applies; this switch turns off HQ's layer, not all naming.
  - `mode: auto` — the hook only. Titles are derived mechanically from the
    project path and the active slash command, and the assistant never renames.
  - `mode: full` (default) — the hook names the session immediately and the
    assistant replaces the directory slug with a written subject.

  Resolution is env → `personal/settings/` → `core/settings/` → built-in
  defaults, so the existing `HQ_SESSION_TITLE=off` and
  `HQ_DISABLED_HOOKS=session-title` escape hatches still win over both files.
  `HQ_SESSION_TITLE=auto` is new and selects `mode: auto` for one shell.
  Resolution is exposed as `core/scripts/session-title-config.sh`, which prints
  `enabled=` and `mode=`; it is grep/sed only, so the hook path stays free of
  both python3 and node.

  The same file carries an `aliases:` block mapping long company slugs to short
  forms (`aliases: {some-long-slug: SHORT}`). Without an entry a slug renders as
  its first hyphenated token, upper-cased and capped at 8 characters. HQ ships
  no company names in that block by design — release code must not carry tenant
  slugs — so put yours in `personal/settings/`, which is never released.

  No action required for existing installations; the defaults preserve current
  behaviour.

- **Session titles carry the repo or product, and a handoff shows two states:**
  the grammar is now `{glyph} {COMPANY} · {Product} · {subject}`. The product
  slot is optional and sits before the subject so identity survives truncation —
  a sidebar shows roughly 33 characters. It is derived from the session cwd when
  that sits inside `repos/`, with a leading company word dropped (under company
  `HQ`, the repo `hq-work` renders as `Work`). Omit it when the company has only
  one product or the subject already names it.

  `/handoff` now distinguishes 📝 *wrapping up* (the handoff is being written)
  from 📤 *handoff ready* (the session is closed; resume from the thread). The
  hook emits 📝 because that is what the running command tells it; the assistant
  sets 📤 once the handoff has actually landed. Both remain distinct from ✅ (the
  work shipped) and 🤝 (a person or agent owns it).

## Release: v15.0.114-beta.2

- **Codex no longer forces Extra High reasoning for every HQ task.**
  `.codex/config.toml` no longer sets `model_reasoning_effort`, so each install
  inherits the operator's user-level choice or per-task selection. Existing
  tasks retain their current setting; new tasks stop being forced to `xhigh`.

## Release: v15.0.110-beta.3

- **`/delegate` grants + reachability probe: three false-negative bugs fixed.**
  (1) The vault-grant verifier now recognizes a recipient email that the vault
  resolves to a `personUid` — it was grepping the ACL read-back for the literal
  email and so false-failed every fully-provisioned member (only pending
  invites, which stay email-keyed, ever passed). It now diffs the prefix's
  direct grants before/after the share and is resolution-aware. (2) The
  reachability probe browses each parent prefix once (memoized) with a retry on
  a throttled empty page, instead of re-browsing per referenced file. (3) Its
  file-presence check is now pipe-free, fixing a `set -o pipefail` + `grep -q`
  SIGPIPE false-negative that marked a genuinely-present file "not in the vault"
  whenever it sorted early in a large parent listing. No action required; the
  scripts are replaced on `/update-hq`.

## Release: v15.0.110-beta.1

- **Hook timeouts raised to a 30s floor: a 5s budget was silently disabling
  guards.** Every hook budget in `.claude/settings.json` dated from when hooks
  were pure bash. Several are now Node-backed — the checkpoint Stop gate
  delegates to `hq core checkpoint-stop-gate` — and Node startup alone can
  exceed 5s on a loaded box. A hook killed at its timeout emits nothing, and no
  output means **allow**, so an expired budget does not fail loudly: it turns
  the hook off.

  Measured on one live session (2026-08-20), hooks killed at their timeout:
  `block-core-writes-bash` 217x (worst 15.2s), `block-hq-worktree-session`
  155x (12.7s), `protect-core` 74x (14.9s), `block-hq-root-git-mutation` 45x
  (10.0s), `block-unsafe-package-install` 34x (11.2s),
  `mandatory-scope-authorizer` 25x (10.8s), `detect-secrets` 12x (10.0s),
  `checkpoint-stop-gate` 4x (7.4s). Most of those are guards; the scope
  authorizer is the one just hardened to fail **closed** for cross-tenant
  safety, and a timeout kill bypasses it before that logic runs.

  Every budget under 30s is now 30s (85 at 5/10/15s, plus the four 20s
  `reindex.sh` registrations). The deliberately-long budgets (60s, 300s) are
  unchanged. This costs nothing in the normal case — the Stop gate measures
  1.4s on the real dispatch path, 1.5s with a cold capability cache — and only
  matters under load, which is exactly when a guard should complete rather than
  be skipped. `core/scripts/tests/hook-timeout-floor.test.sh` pins the floor so
  a new registration cannot reintroduce a budget a Node-backed hook cannot meet.

  Not fixed here: `inject-policy-on-trigger` already had a 60s budget and still
  timed out at 70.4s. Raising it further would stall a prompt for over a minute,
  so it needs a performance fix rather than more budget.

## Release: v15.0.106-beta.1

- **The in-tree checkpoint Stop gate is now a delegating shim; the logic lives
  only in the CLI.** `.claude/hooks/checkpoint-stop-gate.sh` shipped a full,
  behavior-identical copy of the gate as a transitional fallback for CLIs
  predating `hq core checkpoint-stop-gate` (hq-cli 5.99.0, 2026-08-11). The
  duplication cost what duplication costs: the copies drifted — the CLI ran
  three fixes behind at one point — every change needed a matched pair of PRs,
  and each repo grew a suite whose real job was detecting the drift. The hook
  is now ~70 lines: probe the CLI once per version, hand over stdin, emit the
  CLI's decision verbatim.

  **Impact on update:** if the installed CLI cannot provide the gate (no `hq`
  on PATH, or a build older than 5.99.0), the gate no longer runs at all —
  the hook emits no decision and the turn ends normally, per the
  never-strand-a-session doctrine that governs every other error path in this
  hook. Previously such an install fell back to the in-tree copy. The CLI
  self-updates, so this affects only an install that is both very stale and
  not updating; `hq doctor` reports it and `hq self-update` fixes it. Note
  that the opt-in company-scope requirement
  (`HQ_CHECKPOINT_SCOPE_GATE_DOMAINS`) rides the same gate and is therefore
  also inactive on such an install — it is off by default in release-shipped
  scaffold, so only deployments that configured it are affected.
  `HQ_CHECKPOINT_GATE=0` remains the supported kill switch;
  `HQ_CHECKPOINT_GATE_NO_CLI=1` now means the gate does not run at all rather
  than "use the in-tree copy".

- **The Stop gate now requires a user-facing reply, not just the checkpoint:**
  the checkpoint payload is read by a background maintenance agent and never by
  the human, but agents kept treating it as the report — writing rich
  `--summary/--decision/--next` flags and then ending the turn on the tool
  call with a stub reply or none at all. A transcript audit of 1471 stop-gate
  checkpoint turns (2026-08-19) found 2.7% ended with no user-facing reply
  anywhere. Guidance alone could not fix this: the CLI's post-checkpoint
  reminder arrives after the agent has already decided to end the turn.
  The gate now measures the assistant text the genuine turn delivered after
  its last *work* tool call — on either side of the checkpoint, and across the
  gate's own block feedback — and, when a satisfying checkpoint leaves that
  under `HQ_CHECKPOINT_REPLY_MIN` non-whitespace characters (default 80),
  blocks **once** with a dedicated "deliver your reply now" message. An agent
  that already replied is never asked to restate (no double-messaging);
  mid-turn status notes written before the last work tool do not count as the
  reply. The nudge is stamped per checkpoint tool id and counted against the
  shared consecutive-block loop guard (hq-cli 5.103.8: at most 3 consecutive
  blocks per session, then the gate fails open until an allowed Stop resets
  the counter), so no combination of demands can strand a session.
  `--gate-probe` never triggers it, `--idle` triggers it only when the turn
  ran other tools, and the Codex runtime is excluded (its Stop feedback has
  its own delivery contract). It composes with the reply-aware block variants
  from hq-cli #417: an unsatisfied turn whose reply is already visible is told
  to checkpoint and stop — never to repeat itself — while an unreplied turn is
  told to checkpoint first and reply as the turn's final text.

  This behavior ships in the CLI (`hq core checkpoint-stop-gate`, hq-cli
  #415) and reaches operators with the CLI update, not with this scaffold
  release; the shim above is what routes to it. No action required on update.
  Operators who want the old behavior can set `HQ_CHECKPOINT_REPLY_MIN=0`;
  `HQ_CHECKPOINT_GATE=0` still disables the whole gate.

## Release: v15.0.105-beta.1

- **New `/hq-checkup` command: one manual health check that also repairs.**
  HQ previously had no single answer to "is my HQ working?". `hq doctor` covers
  hook wiring only; `/hq-heal` is reactive and needs an error already in hand;
  the CLI-version and hq-core-release facts existed only inside the advisory
  `check-hq-update.sh` SessionStart banner, which nobody could invoke on demand.
  `/hq-checkup` closes that gap. It verifies that the HQ CLI is installed and
  current, that hq-core is current, that the user is signed in, that the macOS
  menubar app and its background sync watcher are running, that cloud sync is not
  paused, that every workspace has backed up recently, that no sync conflicts are
  outstanding, and that the hook guardrails pass.

  It repairs by default rather than only reporting. Four remediations run
  automatically because each is safe and reversible: installing or updating the
  CLI, launching the menubar app, backing up stale workspaces one company at a
  time, and applying `hq doctor --fix`. After each repair it re-runs the original
  measurement and reports the true post-fix state, so a remediation that did not
  take is never announced as a success.

  Four conditions are deliberately left to the operator because no agent can
  perform them: signing in (a browser flow), un-pausing cloud sync (a menubar
  click), resolving conflicting file copies (only the operator knows which copy
  to keep), and running `/update-hq` (it rewrites the scaffold beneath a live
  session and must run in a fresh one).

  Findings that survive an attempted repair are demoted from the "Needs you"
  list to an informational line, so a permanently unfixable condition — an
  abandoned vault that no longer responds to sync — does not train the operator
  to ignore the whole report.

  All operator-facing output is written for a non-technical reader: no file
  paths, version numbers, process names, or HQ-internal vocabulary. `SKILL.md`
  carries a substitution table enforcing that ("hook" becomes "HQ's safety
  checks", "conflict" becomes "two copies of the same file").

  `check-hq-update.sh` is unchanged; the session-start nudge still fires
  independently, and `/hq-checkup` is the manual path to the same facts plus
  everything that hook does not cover.

  No action required on upgrade. Run `/hq-checkup`, or
  `bash .claude/skills/hq-checkup/hq-checkup.sh --check` to inspect without
  changing anything.

## Release: v15.0.103-beta.1

- **The scope guard's line-continuation defence worked only on Linux (SECURITY).**
  `mandatory-scope-authorizer.sh` strips backslash-newline before scanning a
  Bash command, because bash removes it before tokenizing — without that step a
  company path split across a line continuation is never reassembled. The strip
  was written as `${cmd//$'\\\n'/}`, and bash 3.2 — the stock macOS shell —
  matches that unquoted pattern against nothing: it reads the leading backslash
  as a pattern escape rather than a literal. The strip silently became a no-op,
  the scanner saw only the fragment before the break (an unknown company, so
  allowed) and never examined the rest, and the cross-company read the check
  exists to stop went through. bash 5 matches the same expression, so Linux CI
  stayed green while every macOS run of the covering test (`[9]`) failed.

  The pattern is now a quoted variable, which is literal on 3.2 and 5.x alike.
  `lint-shell-portability.sh` gained a rule for the whole class — an unquoted
  ANSI-C substitution pattern carrying a literal backslash — so the next one
  fails CI instead of shipping. Single-escape patterns (`$'\\t'`, `$'\\037'`)
  expand to one character, are unaffected, and are not flagged.

- **The scope-guard suite stopped writing into the developer's real HQ.** Case
  `[15]` invoked `hq-session.sh`, which resolves its root as
  `${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-<its own path>}}`. A developer running the
  suite from inside a Claude session inherits `CLAUDE_PROJECT_DIR` pointing at
  the real checkout, so the bind landed in that developer's own
  `workspace/sessions/` and the case failed locally. CI sets neither variable and
  fell through to the script's path, which is why it passed there. The case now
  pins both to the fixture.

  With this and the `[9]` fix, the suite passes end to end on macOS/bash 3.2 for
  the first time.

## Release: v15.0.101-beta.1

- **The company-scope guard now fails closed (SECURITY).**
  `mandatory-scope-authorizer.sh` decides whether a tool call may touch
  `companies/{co}/`. When the hook payload carried no session id it fell back to
  `workspace/sessions/.current` — a single, global, last-writer-wins pointer that
  names whichever session fired a hook most recently, not the caller. An agent
  the host could not name therefore inherited a stranger's company binding: an
  **unbound** spawned agent was observed reading another tenant's files because
  `.current` happened to name a session bound to that tenant (2026-08-19, HQ
  15.0.98, reproduced 2/2). A payload with no session id is exactly what
  `claude -p --session-id <uuid>` produces.

  The guard now accepts **only** the hook payload's session id. It consults
  neither `.current` nor the session environment: an id in the environment names
  whoever exported it, and a spawned agent inherits its parent's
  (`core/scripts/tests/hq-agent-session-hooks.test.sh` case 7 documents that
  inheritance), so trusting it would authorize a child against its parent's
  tenant. A call that cannot be attributed to a session is **denied** rather than
  guessed. This restores the invariant `core/scripts/lib/session-id.sh` already
  documents: "the enforcement side does not use .current. The scope guard …
  reads the authoritative session id out of the hook payload".

  Impact on update: a caller that reaches the guard with no identifiable session
  now gets a clear denial naming the cause, where it previously got silent
  access to company paths. Sessions identified by payload or environment are
  unaffected, as are `core/`, `personal/`, `repos/`, `workspace/`,
  `companies/manifest.yaml` and `companies/_template/`, which never required a
  binding.

- **`mandatory-scope-authorizer.test.sh` runs on macOS again.** `mktemp -d`
  returns `/var/folders/...` there while `/var` is a symlink to `/private/var`,
  and the hook resolves its own root with `pwd -P`; every absolute-path case
  then normalized to empty and the suite reported a pass-through as an allow.
  The fixture root is now canonicalized, the same way
  `core/scripts/tests/workflow-runner.test.sh` already does it. CI is unaffected
  (Linux `/tmp` is a real directory).


- **`/orchestrate` runs on the codex engine again:** codex forwards an
  `agent()` schema to its provider as a STRICT structured-output schema, which
  rejects any object node that omits `additionalProperties: false` or whose
  `required` does not list every property (HTTP 400 `invalid_json_schema`).
  The orchestrate pipeline's schemas set neither, so every codex launch died on
  its first agent (capture-idea) before doing any work. The workflow runner now
  rewrites each schema into the strict dialect on the wire
  (`core/scripts/lib/codex-output-schema.mjs`) and maps the answer back, so
  workflow scripts keep writing ordinary JSON Schema — an optional property
  stays out of `required` and comes back absent, not null — and the fix covers
  every present and future pipeline script, not just this one. The orchestrate
  pipeline's own schema literals also declare `additionalProperties: false`.
  No action required on update; the grok and claude engines are unaffected
  (they receive the script's schema in-prompt, unchanged).

- **Spawned workflow agents no longer lose their answer to the checkpoint
  gate:** an agent's whole contract is that its final text IS the return value,
  but HQ's end-of-turn checkpoint gate fires at Stop and demands one more turn
  after that answer is written. Observed 2026-08-19 on a claude-engine
  `/orchestrate` stage: the agent produced its JSON result, the gate fired, the
  agent ran `hq core checkpoint`, and the turn ended on that tool call — so the
  envelope came back with an empty result and the runner failed a stage that
  had really done ~8 minutes of work. `core/scripts/workflow-runner.mjs` now
  spawns every child with `HQ_DISABLED_HOOKS` extended by
  `checkpoint-stop-gate` (any value the operator set is preserved, not
  replaced). Checkpointing stays the launching session's job.

- **`/orchestrate` stages bind their company before reading it:** every stage
  runs as a fresh session, and a fresh session is unbound, so HQ's scope
  authorizer denies each read under `companies/{co}/` until
  `core/scripts/hq-session.sh set company_slug` runs — which nothing does for a
  spawned agent. Stages recovered on their own (the denial names its remedy)
  but burned turns doing it. The pipeline preamble now opens with the bind, and
  the "never retry a denied call" rule carves out this one denial, whose message
  states the exact fix. The personal scope is never told to bind.

## Release: v15.0.97-beta.2

- **Final-message placement contract (hidden-links fix):** the checkpoint stop
  gate now instructs runtimes to run the end-of-turn checkpoint FIRST and
  deliver the complete user-facing reply as the turn's final post-tool-call
  message (the Claude Code app folds pre-tool-call text into collapsed
  sub-messages, which was hiding links and instructions). Both HQ output
  styles (`hq.md`, `hq-operator.md`) gain a matching HARD placement rule.
  No action required on update; behavior-safe (the gate never mechanically
  required last-position).

## Release: v15.0.95-beta.1

- **Session titles now carry a category and an icon:** the SessionStart /
  UserPromptSubmit title hook emits `{icon} {CATEGORY} · {subject} · {phase}`
  (for example `🔒 SEC · vault-acl-risk-reconciliation · deploy`) instead of
  `{company} · {project} · {command}`. Three defects are fixed alongside it:
  `core/scripts/session-title.sh` no longer falls back to the machine-global
  `.claude/state/active-session-project` when a session has no project of its
  own (that fallback made every unpinned session inherit whichever project was
  last active anywhere on the box); its fallback HQ root is corrected from
  `$(dirname $BASH_SOURCE)/..` to `/../..`, which previously resolved to
  `core/` and made every state lookup silently miss whenever
  `CLAUDE_PROJECT_DIR` was unset; and `session-title` is added to
  `is_in_minimal_profile` in `.claude/hooks/hook-gate.sh`, where its absence
  made the hook a silent no-op under the minimal profile. Title ownership is
  now decided by grammar match rather than ledger membership alone, so a title
  set mid-session via `set_session_title` is recognised as HQ's own instead of
  being mistaken for a manual rename — previously the host's native session
  autonaming permanently disabled HQ titling for that session. Free-form prose
  titles are still treated as a user rename and still stop HQ from titling.
  New policy `hq-session-title-grammar` asks the assistant to replace the
  directory slug in the subject slot with a written subject once the session's
  purpose is clear. No action required for existing installations; stale
  `.claude/state/session-title-*.manual` markers may be deleted to re-enable
  titling on sessions that backed off under the old ownership test.

- **`/brainstorm` interviews properly again and stores research:** Step 3 is a
  decision-queue grilling — separate `AskUserQuestion` calls, one question at a
  time, covering every unresolved directional input (4-8 questions is normal;
  the prior "1 question max / skip if clear" behavior is removed). Step 4 now
  writes research notes to `{project_dir}/research/` (HQ landscape, market
  landscape, per-topic web notes) linked from brainstorm.md, and live web
  research is default-on for external-facing ideas. Pattern adapted from
  mattpocock/skills wayfinder. No action required for existing installations;
  the skill file is replaced on `/update-hq`.

## Release: v15.0.93-beta.1

- **Knowledge repositories must be real directories:** `/setup`, `/newcompany`,
  `/import-claude`, `/tutorial`, cleanup guidance, and the public README now use
  canonical real directories with optional embedded git. They no longer create or
  endorse repositories under `repos/` symlinked into `core/knowledge/`,
  `personal/knowledge/`, or `companies/{co}/knowledge/`. Existing installations
  with legacy knowledge symlinks should materialize the same content at the
  canonical path, preserve git there if needed, and verify `test -d PATH` plus
  `! test -L PATH` before the next cloud sync. `hq reindex` (hq CLI with the
  knowledge-migration pass) does this automatically: it scours the canonical
  knowledge locations, pulls each legacy repo, copies it inline with history
  preserved as an embedded repo, and removes the fully migrated legacy repo.

## Release: v15.0.91-beta.1

- promote 2026-08-12 (**Grok 4.6 workflow default**): the `/orchestrate` workflow runner
  (`core/scripts/workflow-runner.mjs`) now defaults its grok plan/exec tier models to
  `grok-4.6` (was `grok-4.5`), matching the newly released model. No action required — the
  defaults remain overridable via `HQ_WORKFLOW_GROK_PLAN_MODEL` / `HQ_WORKFLOW_GROK_EXEC_MODEL`,
  and reasoning effort is still inherited from the grok CLI config (`~/.grok/config.toml`),
  not set by the runner.

## Release: v15.0.88

- promote 2026-08-10 (**/deploy comments opt-in**): `/deploy` gains `--comments on|off`
  documenting turning the per-app comment widget on/off (`commentsEnabled`). The flag is
  orthogonal to the access mode and off by default — without it the deploy is byte-identical
  to a pre-feature deploy. A new Phase C step (`C.2.6`) PATCHes the per-app `commentsEnabled`
  flag after upload so the deploy pipeline injects the comment widget on the next deploy; a
  gated deploy's comment thread enforces the same access gate as the deploy itself.
