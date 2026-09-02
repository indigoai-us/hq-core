---
type: reference
domain: [operations, engineering]
status: canonical
tags: [policies, spec, learned-rules, enforcement, frontmatter, governance]
relates_to: []
---

# Policies Spec

## What is a Policy?

A **policy** is a standing operational rule that defines how work is done. Policies are proactive directives — they prescribe behavior before problems occur. They also serve as the canonical location for learned rules captured during execution.

Agents check applicable policies before executing tasks and follow them throughout execution.

## Directory Convention

Policies live in three locations, checked in this precedence order:

```
companies/{co}/policies/*.md       # Company-scoped (highest precedence)
repos/{pub|priv}/{repo}/.claude/policies/*.md  # Repo-scoped
core/policies/*.md              # Cross-cutting + command-scoped (lowest)
```

Each directory can have zero or more policy files. Policies are plain Markdown files with YAML frontmatter.

**Personal overlay (`personal/policies/`).** Files in `personal/policies/<slug>.md` are user-personal authoring locations. The policy trigger hook (`inject-policy-on-trigger.sh`) scans `personal/policies/` **directly** at load time — there is no `core/policies/` symlink mirror (the reindex mirror was retired; reindex now prunes any leftover mirror symlinks). Personal entries ride the same global scope as core and are *not* a separate precedence layer. Author user-global policies here; they are picked up by the SessionStart trigger hook and surface through the global scope. An install upgraded across the mirror retirement may still carry stale regular-file copies of a personal policy inside `core/policies/`; `core/scripts/detect-stale-core-policy-mirror.sh` reports those twins — `--prune-identical` removes only the byte-identical (behavior-neutral) orphans, and any diverged twin is flagged for a human to classify, never auto-synced.

> **`personal/policies/` is the default home for operator-global rules — including everything `/learn` captures at global/command scope.** `core/policies/` is release-shipped scaffold that `/update-hq` replaces wholesale, so a rule written directly there is lost on the next upgrade. `/learn` therefore never writes to `core/policies/`; it writes operator-universal rules to `personal/policies/` (read directly from `personal/policies/` by the trigger hook — no `core/policies/` mirror — so they still load as global) and company/repo rules to their own scoped dirs. The only sanctioned path *into* `core/policies/` is the staging → `/promote-hq-core` pipeline, for policies that genuinely ship to every HQ install. This is enforced mechanically by `protect-core.sh`, which blocks creation of a new `.md` under `core/policies/` (override: `HQ_ALLOW_CORE_POLICY_WRITE=1`). Authoritative rule: `core/policies/hq-customizations-live-in-personal-or-company.md`.

## File Format

```markdown
---
id: {scope-prefix}-{slug}
title: Short descriptive title
when: <boolean trigger expression>   # e.g. always | git && push | deploy || share
on: [<events>]                       # PreToolUse | PostToolUse | UserPromptSubmit | AssistantIntent | SessionStart
enforcement: hard | soft
version: 1
created: YYYY-MM-DD
updated: YYYY-MM-DD
public: false
---

## Rule

One or more clear, imperative statements defining what agents must do (or must not do).

## Rationale

Why this policy exists. What problem it prevents or what outcome it ensures.

## Examples

Optional. Concrete examples of correct and incorrect behavior under this policy.
```

## Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique identifier: `{prefix}-{slug}` (e.g. `acmeflow-docs-update`, `hq-git-branch-verify`, `{product}-staging-first`) |
| `title` | string | Human-readable title |
| `when` | string | Boolean trigger expression evaluated just-in-time to inject the policy when relevant (e.g. `always`, `git && push`). See **Trigger Expressions** below. Scope is determined by the policy's **directory**, not a field. |
| `on` | array | Evaluation site(s) for `when` — any of `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `AssistantIntent`, `SessionStart`. |
| `enforcement` | enum | `hard` (must follow, blocks execution if violated) or `soft` (should follow, deviations noted) |
| `version` | integer | Starts at 1, incremented on material changes |
| `created` | date | ISO date of creation |
| `updated` | date | ISO date of last update |

## Optional Fields

| Field | Type | Description |
|-------|------|-------------|
| `source` | string | Origin of the policy: `manual`, `migration`, `task-completion`, `back-pressure-failure`, `user-correction`, `pattern-repetition` |
| `learned_from` | string | Task ID or session reference (for auto-generated policies) |
| `command` | string | Command name for a command-scoped policy (e.g. `prd`, `email`); pair with a `when:` keyed on the `/command` token |
| `inject` | enum | `once` (default) or `always`. Sets injection **cadence** — how *often* the policy re-surfaces — and is orthogonal to `enforcement:` (which sets **depth**). See **Injection Cadence** below. |

> **Removed:** the `applies_to` field and its stack-based filtering have been removed from the policy schema. Scope stack-specificity through the `when:` expression instead (e.g. `when: vercel`).

### Trigger Expressions (`when:` / `on:`)

`when:` decides *when* a policy is injected **just-in-time** during a session.
The SessionStart trigger hook (`inject-policy-on-trigger.sh`) injects every
on:[SessionStart] policy at session start; reactive `when:` policies fire later
on a concrete signal. A reactive `when:` policy costs nothing until its
expression is true, then a `<policy-reminder>` is injected once per session.
How *much* of the policy that reminder carries is decided by `enforcement:` —
see **Injection Depth** below.

**Expression grammar — a tiny boolean algebra over open tokens:**

```yaml
when: git && push && shared_branch     # AND
when: deploy || share                  # OR
when: git && ! shared_branch           # NOT (use the derived shared_branch fact, not a literal branch name)
when: git && ( push || commit )        # parentheses / precedence
when: .mcp.json || settings.json       # filename tokens (dots/slashes allowed)
when: /brainstorm || /deep-plan        # slash-command tokens
```

- **Tokens are open** — there is no fixed vocabulary. An identifier is TRUE iff
  it appears in the fact set derived for the current event; an absent or
  misspelled identifier is simply FALSE.
- **Identifier charset:** `[A-Za-z0-9_./][A-Za-z0-9_./-]*` — letters, digits,
  `_ . / -`, and may start with `.` or `/`. So a filename (`.mcp.json`,
  `settings.json`) or a slash-command (`/brainstorm`) is a single literal token.
- **Operators:** `&&` (and), `||` (or), `!` (not), `( )` (grouping). Nothing else.
- **The whole expression must parse.** Two identifiers with nothing between them
  is malformed, not a shorter expression. `when: merge || pull request` does not
  mean "merge, or a pull request" — there is no operator before `request`, so it
  is rejected. Write `merge || (pull && request)`, or pick the single token you
  meant. Quoted phrases (`when: "gh pr checks"`), flags, globs, and shell sigils
  are outside the charset and are rejected the same way.
- **A malformed expression is reported, never silently obeyed.** The evaluator
  returns "malformed" rather than true or false, and the injector then does the
  narrowest safe thing:
  - `enforcement: hard` — injected **once per session** as a baseline (a typo
    must never suppress a binding rule), with a notice naming the policy and
    telling you to run `bash core/scripts/lint-policy-triggers.sh`.
  - `enforcement: soft` or unset — **not injected**, and named in the same
    notice.

  It is not treated as a match on every event. That older behaviour meant one
  typo turned a narrow policy into an unconditional one, and a tree with many
  broken triggers crowded out the policies that genuinely matched.
- **Author-time and sweep-time checks.** `validate-policy-frontmatter.sh` blocks
  a malformed `when:` as the file is written;
  `bash core/scripts/lint-policy-triggers.sh` sweeps an existing tree (which the
  write hook never saw) and reports every malformed, missing, loose, and
  oversized trigger at once. `--strict` also exits non-zero on the warn-level
  findings.

**`on:` selects the evaluation site(s):**

```yaml
on: [PreToolUse]                       # default when omitted
on: [PreToolUse, UserPromptSubmit]     # also evaluate on the user's message
on: [PostToolUse]                      # evaluate against the tool's output
on: [AssistantIntent]                  # evaluate against what the AI said it will do
on: [SessionStart]                     # introduce at the very start of a session
```

`SessionStart` evaluates `when` against **static facts only** (`company`, `repo`,
`shared_branch`) plus the reserved **`always`** token. Use `when: always` +
`on: [SessionStart]` for advisory policies that should be introduced at the very
start regardless of context. There is no longer a pre-built digest to dedup
against, so **every** policy whose `on:` includes `SessionStart` and whose `when:`
matches is injected unconditionally — hard and soft alike.

**`always`** is a reserved token present in every fact set — `when: always`
matches unconditionally. It is the canonical "no condition" expression.

`AssistantIntent` is a **pseudo-event**, not a real Claude Code hook. It is
evaluated wherever an AI-message look-back exists — during `PreToolUse` and
`UserPromptSubmit` hook runs — but against a fact set built **only** from the
assistant's recent messages (see below), with no command/prompt/static facts.
Use it for "fire on what the AI is about to do" independent of the literal
command. (Tool events are CLI/Bash-only; `PreToolUse`/`PostToolUse` skip
non-Bash tools.)

**Facts available per channel** (derived by
[`core/scripts/derive-trigger-facts.sh`](../../../scripts/derive-trigger-facts.sh)):

Each text channel emits **every word token** in its text (lowercased, letter-led,
length ≥ 2) — open tokenization, no curated keyword list — plus the non-literal
derived facts (`secret`, `shared_branch`, filename, slash-command). So a policy
keys on whatever word naturally appears when it is relevant (`refactor`,
`monitor`, `docker`, `linear`, …) with nothing to register in advance.

| Source | Tokens |
|--------|--------|
| `PreToolUse` Bash command | every word of the command (`git`, `push`, `commit`, …); `gh pr`→`pr`; `op://`/`AWS_PROFILE`/`.env`→`secret`; a shared branch name→`shared_branch` |
| `PreToolUse` other tools | lowercased tool name (`glob`, `grep`, `read`, `write`, `edit`) |
| `UserPromptSubmit` | every word token of the user's message |
| `PostToolUse` | every word token of the tool's **output** |
| `AssistantIntent` | every word token of assistant message text since the last user turn — **AI-message only, no static facts** |
| `SessionStart` | static facts only (no command/prompt/AI tokens) |
| Static session facts (real events only) | `company`, `repo`, `shared_branch` (current branch) |
| Any text channel (command / prompt / output / AI-intent) | **filename tokens** — see below |
| Every fact set | `always` (reserved — `when: always` matches unconditionally) |

The raw `PreToolUse`/`UserPromptSubmit` fact sets deliberately **exclude** the
look-back so the command/prompt channel and the AI-intent channel stay distinct.

**Filename tokens.** Any file reference in the evaluated text emits two extra
facts: a literal basename token and a `.ext` token. `.claude/settings.json` yields
`settings.json` + `.json`; `.mcp.json` yields `.mcp.json` + `.json`; `shot.png`
yields `shot.png` + `.png`. The leading dot of a directory is dropped with the
path; a dotfile keeps its own leading dot. This is how a file-scoped policy fires
from `AssistantIntent` — the assistant names the file it is about to edit or read
(`when: settings.json`, `when: .mcp.json`, `when: .png || .jpg`) even though the
hook never sees the non-Bash Edit/Read tool call itself. Extensions must be
letter-led, so dotted version numbers (`v1.5`, `3.13`) are not mistaken for files.

**Slash-command tokens.** A `/command` mentioned in the evaluated text emits a
`/command` fact (`/brainstorm`, `/deep-plan`), so a slash-command-scoped policy
fires when the command is invoked or referenced in a prompt (`when: /deep-plan`).
The slash must follow a space or start-of-text, so path segments (`repos/public`)
are not treated as commands.

**How it is applied:**

1. [`.claude/hooks/inject-policy-on-trigger.sh`](../../../.claude/hooks/inject-policy-on-trigger.sh)
   takes the event from `hook_event_name`, derives facts, and for each in-scope
   policy whose `on:` includes the event evaluates `when:` via
   [`core/scripts/eval-trigger.sh`](../../../scripts/eval-trigger.sh) (exit 0=match,
   1=skip, 2=malformed).
2. **Scope is tenant-safe:** global `core/policies` always; the active company's
   and active repo's policies only when the session is in that company/repo — so
   one tenant's `when: git` never injects during another's session.
3. Matches are injected as a `<policy-reminder>` and recorded in
   `workspace/orchestrator/policy-trigger-state/<session_id>.txt` (deduped — a
   slug fires at most once per session).
4. A legacy hardcoded regex map in the same hook still fires for precise
   PreToolUse patterns a coarse boolean token cannot express (e.g.
   `git checkout {ref} -- .`). Both paths dedupe by slug, so migrating a policy
   to `when:` is incremental and never double-injects.

### Injection Depth (`enforcement:` decides how much text is injected)

`when:`/`on:` decide **whether** a policy is injected. `enforcement:` decides
**how much of it**:

| `enforcement` | What the agent receives |
|---------------|-------------------------|
| `hard` | The policy's **binding body**, verbatim, quoted into the `<policy-reminder>` block — everything after the closing frontmatter `---`, stopping at the first archival heading. Rule text, exceptions, override env vars, and escape hatches: all of it. |
| `soft` (or omitted) | **Frontmatter-level only** — the slug plus a single ≤160-char excerpt of the first line of `## Rule`, with a pointer to the file. |

The reason for the split: a hard policy is *binding*, and its binding content is
rarely confined to its first sentence — the exceptions, the sanctioned override
env vars, and the "this looks like a bug but is the gate working" clauses all sit
further down the file. Paraphrasing a hard rule down to one line is how an agent
ends up confidently violating it. A soft policy is advisory, so a pointer is
enough; the agent can open the file when it matters.

**Where the binding body stops.** A hard policy is re-quoted into every session it
fires in, so its archival half is pure recurring cost. Injection stops at the
first heading named `Rationale`, `Background`, `Change History`, `Changelog`,
`History`, `Examples`, `References`, `Related`, `See also`, `Sources`,
`Provenance`, or `Evidence` (`HQ_POLICY_BODY_STOP` overrides the pattern). Write
the rule — including its exceptions — above that line, and put worked examples,
incident write-ups, and provenance below it. Nothing is lost: the agent has the
path and can read the whole file when it needs the reasoning.

**Bounded, and never silently.** Two limits apply. Each hard policy's body must
fit `HQ_POLICY_HARD_MAX_BYTES` (default 6144) on its own, and the whole injection
must fit `HQ_POLICY_HARD_BUDGET_BYTES` (default 16384) across all of them,
consumed in precedence order (company > repo > personal > core) so a tenant's own
hard rules claim it first. A hard policy that exceeds either limit degrades to the
soft one-line shape **and is named** in a trailing notice, so a shortened set can
never be misread as the complete text. A hard policy whose file is unreadable or
has no body degrades the same way — never silently dropped.

`bash core/scripts/lint-policy-triggers.sh` reports every hard policy over the
per-policy limit across the whole install, so oversized rules surface as a list to
fix rather than one notice at a time. The same limit is enforced at authoring
time by `validate-policy-frontmatter.sh`
(`HQ_POLICY_HARD_RULE_MAX_BYTES`), which blocks the write and points at the
archival headings to move text below.

**Escape hatches.** `HQ_POLICY_HARD_FULL_TEXT=0` restores summary-only output for
hard policies; `HQ_POLICY_HARD_BUDGET_BYTES` resizes the budget. The
`HQ_POLICY_EMIT=tsv` machine path is unaffected — it emits the five-field record
(`slug`, `scope`, `path`, `enforcement`, `rule`) and leaves depth to its consumer,
which has the `path` and can read the file itself.

This is one more reason `enforcement:` is not decorative: marking a policy `hard`
materially increases its per-session context cost. Reserve it for rules that
genuinely block execution when violated.

**Auto-backfill at SessionStart.** A policy authored without `when:`/`on:` does
not stay untriggered: [`core/scripts/migrate-policy-triggers.sh`](../../../scripts/migrate-policy-triggers.sh)
runs as a SessionStart hook and derives a trigger from the policy's own
metadata — `when:` from its `tags:` (topical vocabulary, `vendor:x`→`x`, meta
tags dropped);
`on: [PreToolUse, PostToolUse, UserPromptSubmit, AssistantIntent]` (every live
event — `when:` does the filtering). If neither tags nor trigger yield a signal,
only an `enforcement: hard` policy falls back to `when: always` +
`on: [SessionStart]`. A soft or unset-enforcement policy is left unbackfilled,
and the injector skips it because it has no `when:` trigger. The script is
**strictly idempotent**: a policy that already declares `when:` (authored or
human-tuned) is never rewritten — so it backfills new policies only, with zero
writes in steady state. Hand-tuning a generated trigger is therefore permanent.

### Injection Cadence (`inject:` decides how often)

`when:`/`on:` decide **whether** a policy is injected and `enforcement:` decides
**how much** of it; `inject:` is a third, orthogonal switch that decides **how
often** it re-surfaces:

| `inject` | Cadence |
|----------|---------|
| `once` (or omitted) | The policy fires **at most once per session**. After it is injected, its slug is recorded in the per-session ledger (`workspace/orchestrator/policy-trigger-state/<session-id>.txt`) and it is not injected again for the life of the session. This is the historical default and remains the right choice for almost every policy. |
| `always` | The policy re-injects **once per user turn**. It is deduped only within a turn (via a separate per-turn ledger `<session-id>.turn.txt` that is truncated at each `UserPromptSubmit`), so a turn's many mid-turn Bash calls never repeat it, but every new user message re-surfaces it. Reserve this for a small number of rules that must stay continuously present in context. |

Both cadences are still gated by `when:`/`on:` — an `always` policy only
re-injects on the turns where its trigger actually matches. Pairing
`inject: always` with `when: always` + `on: [SessionStart]` yields a rule that
is present on every single turn; pairing it with a reactive `when:` yields a
rule that re-appears the first time its condition is met in each turn it applies.

**Compaction resets the ledgers.** The injected `<policy-reminder>` text lives
in the conversation turns, so when autocompact condenses older turns that text
is dropped from context. A PreCompact hook
([`purge-policy-ledger-precompact.sh`](../../../../.claude/hooks/purge-policy-ledger-precompact.sh))
deletes the current session's ledgers just before the compaction, so the next
event re-injects the **entire** SessionStart baseline and every once-per-session
policy — the guardrails come back exactly as at session start, rather than
staying suppressed by a ledger that still lists them as "already injected". The
purge is scoped strictly to the session id in the hook payload; it never wipes
another live session's state.

## Optional Sections

- **Examples**: Concrete correct/incorrect behavior
- **Exceptions**: When the policy does not apply
- **Related**: Links to other policies, knowledge, or workers

## ID Prefix Convention

| Scope | Prefix | Example |
|-------|--------|---------|
| Company | `{company}-` | `acmeflow-docs-update` |
| Repo | `{repo-slug}-` | `{product}-staging-first` |
| Command | `hq-cmd-{name}-` | `hq-cmd-prd-question-batching` |
| Global | `hq-` | `hq-git-branch-verify` |

## How Agents Use Policies

1. Before executing a task, load policies from all applicable directories:
   - `companies/{co}/policies/` (determine company from context — at SessionStart this resolves from cwd, the owning repo via `manifest.yaml`, or the `company_slug` persisted to the session by `/startwork`)
   - `{repo}/.claude/policies/` (if working inside a repo)
   - `personal/policies/` (always — operator-authored global rules, read directly by the trigger hook; not mirrored into `core/`)
   - `core/policies/` (always — the release-shipped set)
2. The `when:` / `on:` fields decide when each policy is injected just-in-time (see **Trigger Expressions**); an injected policy applies to the current task
3. Follow all applicable `hard` enforcement policies — violation blocks task completion
4. Follow all applicable `soft` enforcement policies — deviations are acceptable with justification
5. **Precedence:** company > repo > command > global. If policies conflict, higher-precedence wins

## Auto-Generated Policies

The `/learn` command creates policy files automatically from execution learnings. These use the same format with the optional `source` and `learned_from` fields populated.

**Enforcement defaults:**
- `enforcement: hard` — user corrections (`source: user-correction`), critical severity, NEVER rules with safety implications
- `enforcement: soft` — informational patterns, reference rules, success patterns

**Slug generation:** First 4-5 meaningful words from the rule, lowercased, hyphenated. Deduplicated against existing files in target directory.

## Repo-Level Policies

Repos can have their own policies at:

```
repos/{pub|priv}/{repo}/.claude/policies/*.md
```

Repo-level policies use the same format as company policies. The `id` field uses `{repo-slug}-{policy-slug}` format (e.g. `{product}-no-force-push`).

Agents check repo-level policies when working within that repo. The `/learn` command auto-creates this directory when writing a repo-scoped policy.

## Global HQ Policies

Cross-cutting rules that apply to all companies and repos live at:

```
core/policies/*.md
```

These are always loaded regardless of company or repo context. They have the lowest precedence — company and repo policies override them if conflicting.

## Command-Scoped Policies

Policies that apply to specific HQ commands live at `core/policies/`. They fire when the command is invoked or referenced by keying `when:` on the slash-command token.

Example:
```yaml
---
id: hq-cmd-prd-question-batching
title: Limit PRD Discovery Question Batches
when: /prd || /plan
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
---
```

## Relationship to Other HQ Concepts

| Concept | Purpose | Location |
|---------|---------|----------|
| **Company Policies** | Company-scoped standing rules | `companies/{co}/policies/` |
| **Repo Policies** | Repo-scoped rules and learnings | `repos/{repo}/.claude/policies/` |
| **Global Policies** | Cross-cutting rules | `core/policies/` |
| **Worker Instructions** | Worker-specific behavioral rules | `worker.yaml instructions:` block |
| **Knowledge** | Reference material (facts, schemas, guides) | `companies/{co}/knowledge/` or `knowledge/public/` |
