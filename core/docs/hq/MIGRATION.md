# HQ Migration Guide

Newest release first. `## Release: TBD` collects promotions staged for the next
release; the release workflow stamps it with the version at tag time.

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
