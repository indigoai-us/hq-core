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
enforcement: hard | soft | gate
version: 1
created: YYYY-MM-DD
updated: YYYY-MM-DD
public: false
company: <slug>                      # optional; or companies: [a, b]. Personal/repo/core policy written for one client
---

## Rule

One or more clear, imperative statements defining what agents must do (or must not do).

## Rationale

Why this policy exists. What problem it prevents or what outcome it ensures.

## Examples

Optional. Concrete examples of correct and incorrect behavior under this policy.

## Provenance

Optional. HQ-local evidence: who reported it, when, which company, which ticket.
Stripped on publish.
```

**`company:` / `companies:` (optional).** Marks a personal, repo, worker or core policy as written for one or more clients. When the session holds a company lock (`core/scripts/hq-session.sh`) that includes none of them, the reminder skips the policy if it is soft. Binding rules (hard, gate) are never skipped this way, and sessions with no lock or a personal lock see it as before. Words in `when:` are never read as company names. Policies in a company's own policies directory need no field: that directory already loads only for the session's companies. Each value must be a slug in `companies/manifest.yaml`: `validate-policy-frontmatter.sh` blocks any other value, and the reminder counts only whole slug items that have a `companies/<slug>/` folder, ignoring anything after a ` #` comment and any item with other text, so a placeholder never hides a rule. `/learn` writes this field when an explicit repo, command or global scope sends a rule about one client outside that client's policies directory (the slug the user named, or the active or locked session company the rule is about). Company rules still go to the company's policies directory by default. It never infers a company from the policy name or wording, and it omits the field for general rules.

**`## Provenance` vs `## Rationale`.** Rationale explains the mechanism and the
trade-offs, and ships with the policy. Provenance records who, when, which
company, and which ticket. It stays HQ-local and the publish pipeline strips it.
The injector and the hard-body size limit treat `## Provenance` as an archival
heading, so it is never injected.

- Do: `## Rationale` — "Two hooks read the same receipt store, so a stale receipt from one session can satisfy the other."
- Don't: `## Rationale` — "Reported by Jane at Acme on 2026-09-12 in ticket OPS-412." Put that line under `## Provenance`.

## Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique identifier: `{prefix}-{slug}` (e.g. `acmeflow-docs-update`, `hq-git-branch-verify`, `{product}-staging-first`) |
| `title` | string | Human-readable title |
| `when` | string | Boolean trigger expression evaluated just-in-time to inject the policy when relevant (e.g. `always`, `git && push`). See **Trigger Expressions** below. Scope is determined by the policy's **directory**, not a field. |
| `on` | array | Evaluation site(s) for `when` — any of `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `AssistantIntent`, `SessionStart`. |
| `enforcement` | enum | `hard` (must follow, blocks execution if violated), `soft` (should follow, deviations noted), or `gate` (blocks named tool calls until required session facts exist; needs a `gate:` block, see **Gate Block**) |
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
| `principals` | list | Session principals the policy is injected for: any of `human`, `agent`, `bot`, as `[agent, bot]` or a YAML block list of `- agent` lines. Omitted means every principal. See **Principals** below. |
| `repos` | list | Repos the policy applies to, as `[repo-a, repo-b]` or a YAML block list. Omitted or empty means every repo. See **Repo Scope** below. |

### Principals

`principals:` limits a policy to the kind of session it is written for. It is unrelated to the
`hq-audience-mode` output styles, which set how the agent talks to a human.

The policy injector resolves the session principal once per event, in this order:

1. `HQ_SESSION_PRINCIPAL` set to `human`, `agent`, or `bot`. Any other value is ignored.
2. `agent` when a fleet identity is present: `HQ_AGENT_WORKDIR`, `HQ_AGENT_COMPANY_DIR`, or
   `HQ_AGENT_IDENTITY_FILE` is set, or `/etc/hq-agent/identity.json`,
   `/etc/hq-agent/machine-creds.json`, `/var/lib/hq-agent/identity.json` (under
   `HQ_AGENT_ROOT_PREFIX` when set), or `/var/lib/hq-agent/machine-creds.json` exists. This mirrors
   hq-cli `fleetIdentityPresent`.
3. `bot` when `HQ_BOT_AGENT_UID` (personal bot turn) or `HQ_MACHINE_CREDS_FILE` (company bot turn)
   is set.
4. `human` otherwise.

A policy whose `principals:` does not include the session principal is dropped before trigger
matching and ranking, so it never takes a slot under the output ceiling. A missing field applies to
everyone. `core/scripts/lint-policy-triggers.sh` reports unknown values, empty lists, and malformed
syntax as `PRINCIPALS` findings and exits non-zero. At runtime a list with no recognized value
applies to everyone, so a typo cannot hide a policy.

### Repo Scope

`repos:` limits a policy to events that touch one of the listed repos. It is opt-in: a policy
without the field, or with an empty list, behaves exactly as before. It works in any policy scope,
and is most useful for a company policy that is about one of the company's repos.

```yaml
repos: [web-app]        # or a block list:
# repos:
#   - web-app
#   - acme-org/api      # owner/name and repos/<public|private>/name are accepted
```

Each entry is reduced to its last path segment and compared case-insensitively with the repo names
the event touches. The injector reads those names, without running git, from:

- any `repos/public/<name>` or `repos/private/<name>` path in the session cwd or the tool command
  (this covers `git -C <dir>` and file operands);
- any `workspace/worktrees/<name>/` path in the cwd or the command (HQ worktrees are grouped by repo
  name);
- `-R owner/<name>` or `--repo owner/<name>` in the command.

A policy whose `repos:` list matches none of these is dropped before trigger matching and ranking,
so it never takes a slot under the output ceiling. Matching is by directory name only: the git remote
is not read, so a clone checked out under a different directory name does not match.

### Lifecycle Fields

All optional. `.claude/hooks/validate-policy-frontmatter.sh` validates them when present and names
the offending field when one is malformed. `/learn`, `/garden`, the injector, `policy-retire.sh`, and the
gate hook read this one schema.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `status` | enum | `active` | `active`, `retired`, or `superseded`. Any other value is rejected. Consumers skip non-active policies. |
| `retired_at` | ISO timestamp | none | When the policy was retired. Allowed only with `status: retired`. |
| `retired_by` | string | none | Who or what retired it (a person, `policy-retire.sh`, `/garden`). Allowed only with `status: retired`. |
| `retired_reason` | string | none | Why it was retired. Allowed only with `status: retired`. |
| `last_confirmed` | ISO date | none | Last date someone confirmed the rule still holds (`YYYY-MM-DD`; a full timestamp is also accepted). |
| `retire_when` | string | none | Free-text condition under which the rule can be retired, e.g. `retire_when: hq-cli 6.0 ships the native fix`. No quotes and no regex metacharacters (`* + ? [ ] ( ) { } \| \ ^ $`), per `hq-policy-when-expr-no-quotes-or-symbols`. |
| `supersedes` | list of policy ids | none | Policies this one replaces. Accepts `[a, b]`, `a, b`, or a YAML block list of `- id` lines. Each entry must be a bare policy id. |

### Gate Block (`enforcement: gate`)

`enforcement: gate` is a third tier beside `hard` and `soft`. A gate policy declares, as data, which tool
calls it guards and which session facts must exist before those calls run. The gate hook blocks a
matching call until every required fact is present and fresh. The policy carries a `gate:` block:

```yaml
enforcement: gate
gate:
  tools: [mcp__superhuman-*__send_draft, mcp__hq-work__send_email]
  bash: [gws gmail send]
  requires: [sending_account_confirmed, recipients_confirmed]
  freshness: 60
  override: allowed
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `tools` | list of tool-name globs | none | Tool names the gate guards. `*` is the only glob character. |
| `bash` | list of command prefixes | none | Bash command prefixes the gate guards. |
| `requires` | list of fact names | required | Session facts that must exist before a guarded call runs. |
| `freshness` | integer minutes | none (no expiry) | Maximum age of each required fact. |
| `override` | enum | `allowed` | `allowed` or `denied`. Whether a human can pass the gate once with an audited `gate-override` token. |

A gate block must declare `tools` or `bash` (at least one) and a non-empty `requires`. Unknown keys inside
`gate:` are rejected. A `gate:` block is validated whenever present. The v1 fact
vocabulary is fixed: `sending_account_confirmed`, `recipients_confirmed`, `draft_approved`,
`humanize_passed`, `enforcement_observed`. The policy-gate-enforcement project owns fact-name and
metacharacter validation for gate fields.

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
on: [PostToolUse]                      # default for tool-bearing when: facts
on: [PreToolUse, UserPromptSubmit]     # also evaluate on the user's message
on: [PostToolUse]                      # evaluate against the tool's output
on: [AssistantIntent]                  # evaluate against what the AI said it will do
on: [SessionStart]                     # introduce at the very start of a session
```

An omitted `on:` on a tool-bearing `when:` policy means `PostToolUse`. This is
the event where Claude Code can deliver the reminder as
`hookSpecificOutput.additionalContext`. PreToolUse is not evaluated for passive
policy reminders by default because plain stdout from that event is not model
context. `on: [PreToolUse]` remains meaningful for rollback compatibility;
passive PreToolUse policy evaluation is disabled unless
`HQ_POLICY_TOOL_EVENTS=legacy` is set. That environment variable is a
one-release rollback switch and restores both PreToolUse evaluation and the
historical omitted-on default.

`SessionStart` evaluates `when` against **static facts only** (`company`, `repo`,
`shared_branch`) plus the reserved **`always`** token. There is no longer a
pre-built digest to dedup against, so **every** policy whose `on:` includes
`SessionStart` and whose `when:` matches is injected unconditionally — hard and
soft alike.

**`always`** is a reserved token present in every fact set — `when: always`
matches unconditionally. It is not a recommended trigger. Every core policy
is keyword-triggered: the 14 policies that carried `when: always` rode along on
every hook event and were the main reason the policy-reminder ceiling cut
lower-ranked lines; they were moved to keyword triggers in HP-4 of
hq-hook-perf (for example `read || file`, `decision || question || choose`,
`write || message || reply || report || email || slack`, `catch || error ||
try`). A "baseline" rule still has a moment when it applies; name the words
that appear in that moment. Reserve `when: always` + `on: [SessionStart]` for
an `enforcement: hard` rule with no nameable signal at all, and expect a
reviewer to ask for the keyword.

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
| `PreToolUse` Bash command | every word of the command (`git`, `push`, `commit`, …); `gh pr`→`pr`; `op://`/`AWS_PROFILE`/`.env`→`secret`; a shared branch name→`shared_branch`; `run_in_background: true`→`run_in_background` |
| `PreToolUse` other tools | lowercased tool name (`glob`, `grep`, `read`, `write`, `edit`) |
| `UserPromptSubmit` | every word token of the user's message |
| `PostToolUse` Bash command and output | every word token of `tool_input.command` and the tool's **output**, plus command-derived facts other than `run_in_background` |
| `PostToolUse` non-Bash tool | every word token of the tool's **output** |
| `AssistantIntent` | every word token of assistant message text since the last user turn — **AI-message only, no static facts** |
| `SessionStart` | static facts only (no command/prompt/AI tokens) |
| Static session facts (real events only) | `company`, `repo`, `shared_branch` (current branch) |
| Any text channel (command / prompt / output / AI-intent) | **filename tokens** — see below |
| Every fact set | `always` (reserved — `when: always` matches unconditionally) |

The raw `PreToolUse`/`UserPromptSubmit` fact sets deliberately **exclude** the
look-back so the command/prompt channel and the AI-intent channel stay distinct.
The `run_in_background` marker is available only on PreToolUse, where the host
reports that option. Passive policy evaluation skips PreToolUse by default, so a
policy that depends on this marker will not run until
`HQ_POLICY_TOOL_EVENTS=legacy` restores the old path. The blocking Bash hooks
are separate registry entries and this change does not edit them.

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
fit `HQ_POLICY_HARD_MAX_BYTES` (default 2048) on its own, and the whole injection
must fit `HQ_POLICY_HARD_BUDGET_BYTES` (default 5120) across all of them,
consumed in relevance order (below) so the hard rules most relevant to the
current event claim it first. A hard policy with a *specific* match (below) is
not limited by the shared budget; the per-policy limit and the output ceiling
still apply to it. A hard policy that exceeds either limit degrades to the
soft one-line shape **and is named** in a trailing notice, so a shortened set can
never be misread as the complete text. A hard policy whose file is unreadable or
has no body degrades the same way — never silently dropped.

**Ranked by relevance to the trigger.** Matches are ordered before any budget
or ceiling applies. A policy whose `when:` identifiers appear directly in the
event's own facts (the command or prompt it keys on) is a *direct*
match; a match through `when: always`, a PostToolUse output word, or a broader fact set is *generic*. Direct
matches rank above generic ones, hard above soft within each group, and the
reactive groups rank above the SessionStart baseline. Within a group, more
matched identifiers rank first, and ties keep scope precedence
(company > repo > personal > core).

A direct match is *specific* when it matched two or more `when:` identifiers,
or one identifier that at most `HQ_POLICY_RARE_TOKEN_MAX` (default 3) in-scope
policies use in their `when:`, or a file name, path or slash command (an
identifier with `.` or `/` in it, such as `settings.json` or `/prd`). A match on one common word, such as `deploy` or
`slack` in an HQ with hundreds of policies keyed on it, is direct but not
specific. Specific matches rank above the other direct matches.

**Relevance cap.** The cap applies to soft and unset policies only; every
matched hard policy is listed, at least as its summary line, and the full-text
budget and output ceiling bound its size. Reactive policies with a specific
match and `inject: always` policies are also always shown. The other soft
policies fill what is left of `HQ_POLICY_RELEVANCE_CAP` slots (default 6) after
those, in rank order. Soft matches over the cap are counted in a notice and not
recorded as delivered, so they stay eligible for a later event that matches
them more specifically. SessionStart is not capped, and an explicit legacy
`HQ_SESSION_POLICY_CAP` replaces this cap. `HQ_POLICY_RELEVANCE_CAP=0` turns
it off.

**Generic cap on tool events.** A Bash call is one of dozens per turn, and a
match on one common word of its command text (`git`, `status`, `deploy`) is a
weak signal. On PreToolUse and PostToolUse at most `HQ_POLICY_GENERIC_CAP`
(default 2) such soft rows are shown, in rank order, inside the relevance
cap; the other soft ones are *parked* and named in the notice: written to the
seen set under that word,
so the same word does not surface them again for `HQ_POLICY_SEEN_TTL_SECONDS`
(default 1800). A valid hard policy is never generic and never parked: it is shown, or
deferred by name when the full-text budget is spent. When the output ceiling
shortens a hard policy to its summary line or cuts it, it is not recorded or
parked and is shown in full on its next matching event, and the reminder
says how many hard policies the ceiling cut instead of claiming all are shown. A specific match, an `inject: always` policy, or a match on two
or more identifiers or on a file name, path or slash command is never generic.
A malformed-trigger fallback row did not match the command at all: on a tool
event it is one of the weak rows and is shown as its summary line only. A
baseline row (`when: always` and the rest of the SessionStart set) is not
shown on a tool event; SessionStart introduces it and a prompt event backfills
it. Prompts keep the relevance cap alone. `HQ_POLICY_GENERIC_CAP=0` turns the
generic cap off (over-cap rows then stay eligible, as under the relevance cap
alone).

**Hard rules are never shortened below their Rule section on reactive
events.** A hard policy whose body is over the per-policy limit shows its
`## Rule` section when that fits, with a heading that says so and points at
the file for the rest; only when the Rule section is itself over the limit does
it fall back to the summary line and the oversize notice. A reactive hard rule
that loses the shared full-text budget on a capped tool or prompt event is
*deferred*: left out of that reminder, named in a notice, not recorded, and
shown with its text on the next event it matches once the rules that took the
budget have been recorded. Baseline rows keep their index line (that is the
index), and the output-ceiling fallback below keeps its summaries.

**Output ceiling.** The whole reminder must fit
`HQ_POLICY_OUTPUT_CEILING_BYTES` (default 8000; for PostToolUse this is the
JSON envelope). When the full text does not fit and a hard rule matched the
event, soft and unset summary lines are cut first, lowest-ranked first,
and every hard rule keeps its text. If that is not enough, the top-ranked hard
rule keeps its full text (with specific matches, as many of the specific hard
rules as fit) and every other hard rule is shortened to its summary line, with a notice
naming the kept rules and pointing at each file. If that still does not fit,
every hard rule is summarised, then lower-ranked lines are cut and counted in a
notice. Cut policies are not recorded as delivered, so they stay eligible
for the next event. The ceiling is not raised to make content fit.

**No repeats inside a window.** A hard policy delivered in full is recorded in
the session ledger like any `once` policy. A hard policy shown only as its
summary line is recorded in a per-session seen set
(`<session-id>.seen.tsv`) with the time and its trigger key (the matched
`when:` identifiers). The same policy is not shown again for the same trigger
key until `HQ_POLICY_SEEN_TTL_SECONDS` (default 1800) has passed; a new trigger
key shows it again at once. The key does not include the working directory, repo, or company, and a row with a future timestamp counts as expired. `inject: always` policies are not filtered by the
seen set. The PreCompact purge deletes the seen set with the other ledgers.

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

## Retirement (`status: retired`)

A policy is retired, never deleted. `bash core/scripts/policy-retire.sh <slug> --reason "<why>"` adds
`status: retired`, `retired_at`, `retired_by`, `retired_reason` to the frontmatter; `--restore` removes them.
Every consumer skips a retired policy: the trigger loader, the company-bind digest, and
`policy-age-report.sh`. Candidates come from `policy-age-report.sh --candidates` (never fired, dormant,
stale references, old single-incident rules); `policy-retire.sh --from-report <json> --class <class> --yes`
retires a class in one pass. Usage is measured two ways: `fired` (emitted in the index) and `retrieved`
(the session pulled the full text), and only the second means the rule was actually read.
