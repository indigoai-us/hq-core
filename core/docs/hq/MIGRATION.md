# HQ Migration Guide

Newest release first. `## Release: TBD` collects promotions staged for the next
release; the release workflow stamps it with the version at tag time.

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
