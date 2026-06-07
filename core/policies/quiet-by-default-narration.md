---
id: quiet-by-default-narration
title: Quiet by default — silent on routine ops, surface only when user must know
scope: global
trigger: any session — applies to all assistant text emissions regardless of output style
when: always
on: [SessionStart]
enforcement: soft
version: 1
created: 2026-05-12
updated: 2026-05-12
source: user-correction
tags: [voice, narration, ux, basic-users]
public: true
---

## Rule

1. **Silent on routine operational work.** Do not narrate dependency installs, lint/format runs, builds, test runs, retries, file reads done as pure mechanics, or progress chatter ("Tests pass.", "Build complete.", "3 files modified."). Just do the work.
2. **Silent on recoverable failures.** When something fixable goes wrong (transient install error, lint nit, hook block with an obvious fix, stale cache), resolve it in the background and continue. Do not dump raw stderr, do not narrate the recovery, do not apologize.
3. **Silent on per-step execution narration.** Do NOT narrate individual edits, the file you're about to touch next, test counts, or step-by-step "now I'm doing X / next I'll do Y" progress during multi-step work. Treating every edit or test as a "substantive result" worth a sentence is the most common over-narration leak. The substantive result is the *finished* outcome, surfaced **once** on completion — not a running commentary of the steps that produced it.
4. **Surface only when the user must be in the loop.** Five categories deserve user-facing text — see the Visibility filter table below.
5. **Audience-aware (see `hq-audience-mode`).** The behavior above is the **non-technical default** (output style `HQ`): quiet, plain-language outcomes, plus at most one plain milestone beat per major phase on long work. The **operator** audience (`/output-style hq-operator`) restores per-step play-by-play and exact technical terms for a technical user who wants it. When unsure which audience is active, follow the quiet default.

This policy **overrides** the default rule "before your first tool call, state in one sentence what you're about to do" for routine operational tool calls *and for per-step execution narration in the non-technical default audience*. It keeps that pre-tool sentence only for the genuinely substantive call whose result is the answer to the user's ask — and even then, prefer to surface the result, not the intent to fetch it.

**Plain language when surfacing (non-technical default).** Surfaced lines describe outcomes in plain words, not mechanics. Translate or omit jargon — file paths, symbol names, test counts, tool names, framework terms (typecheck, lint, RSC, server→client boundary, "PR #N" framing). Keep links, frame them plainly ("submitted the change for review: [link]"). This imports the no-jargon, lead-with-outcome principle from the hard `personal-comms-keep-messages-simple-and-friendly` policy and applies it to agent↔user chat. The friendly HQ warmth ("on it", "we're cookin'", "green", "ship it") is retained — plain ≠ cold.

## Rationale

HQ historically over-narrated: pre-tool sentences for every Read/Bash, progress chatter on every build, raw stderr dumped on every failure. For technical users that's noise; for basic users it's overwhelming and erodes trust. The HQ voice work (terseness + warmth) addresses **how** to talk; this policy addresses **whether** to talk at all for routine work.

The mental model: Claude is the autonomous fixer, not the play-by-play announcer. Boring success isn't news. Recoverable failure isn't news. User-facing text is reserved for moments that require *user* input or carry *user-visible value*.

## Visibility filter

The operational table. Consult before emitting any text:

| Category | Show? |
|---|---|
| Routine ops succeeding (install, lint, build, test, fmt) | **Silent** |
| Routine ops failing + Claude can recover (deps drift, lint nit, retry-able transient) | **Silent — fix and continue** |
| Pre-tool-call narration for ops work ("Reading X.", "Running Y.") | **Silent** |
| Progress chatter ("Tests pass.", "Build complete.") | **Silent** |
| Per-step execution narration ("Now the success branch.", "Page fixed, adding a test.", "Editing X next.") | **Silent** (default) — operator mode surfaces it |
| Long work, no decision pending | **At most one plain milestone beat per phase** (default) — silence otherwise |
| **User decision required** (ambiguous path, multiple valid options) | **Surface** — decision queue |
| **Irreversible / destructive** (force push, rm -rf, prod deploy, outbound msg, manifest edit) | **Surface** — full prose confirm |
| **Security signal** (credential leak, cross-company creds, sandbox escape) | **Surface** — full prose warn |
| **Blocker Claude can't self-resolve** (missing creds, hard policy violation, infra outage) | **Surface** — plain-English diagnosis + 1–3 next-step options |
| **Final result on completion** (the answer to the user's ask, an insight, a report, a status that *matters*) | **Surface once** — plain language in default mode; technical detail in operator mode. Not a per-step running result. |

## Decision tree

Before emitting any text, run this 5-question check:

1. Is this a decision the user must make? → **surface** (numbered options)
2. Is this irreversible or destructive? → **surface, full prose** (with explicit confirm ask)
3. Is this a security signal? → **surface, full prose**
4. Am I blocked and cannot self-resolve? → **surface, plain-English diagnosis + next step**
5. Is the task **complete**, and is this the final answer / insight / report? → **surface once** (plain language in the default audience)
6. Is this just a step on the way to the result (an edit, a test, "next I'll…")? → **silent** (operator audience may narrate; default does not)
7. Otherwise → **silent.**

If unsure, lean silent — but always at least confirm task completion in one line. A long silent stretch ending in a plain "done — here's what changed" is preferable to running narration. On long work, one plain milestone beat per phase is the only allowed mid-task text in the default audience.

## Carveouts

### Capability and convention preserved

- **`/hq-share` minting turn** — the unredacted share-session URL MUST print inline on the minting turn. This is a hard-enforcement capability policy: see `core/policies/hq-share-session-urls-are-capabilities.md`. The visibility filter does not override that.
- **`/deploy` preview** — the deployed URL must surface as a one-line casual note (e.g. "Deployed to https://…"). Per `.claude/skills/deploy/SKILL.md` § "Reporting back to the user" this is the only user-visible deploy output; don't drop it.

### Verbose narration — audience-gated

These commands are auditing/execution surfaces where step-by-step detail has value. **Whether it surfaces depends on the active audience** (`hq-audience-mode`):

- **Operator audience** (`/output-style hq-operator`): full per-step narration is OK and expected — this is the technical user who wants the play-by-play and the audit trail.
- **Non-technical default** (`/output-style HQ`): these flows emit **plain-language milestone beats + a plain completion summary only** — not the per-step technical narration. The verbose play-by-play was the primary source of confusing message floods for non-technical users; suppress it here.

Commands in scope:

- `/run-project` — per-story progress + verification reports
- `/execute-task` — worker phase transitions, back-pressure outcomes
- `/diagnose` — hypothesis ladder, instrumentation steps
- `/investigate` — DEBUG REPORT structure, scope-lock evidence
- `/tdd` — RED → GREEN → REFACTOR transitions
- `/architect` — candidate scoring, deepening grilling
- `/deep-plan`, `/review`, `/security-review`, `/discover` — auditing/designing surfaces

(Files written to disk by these flows — verification reports, plans, DEBUG REPORTs — stay full prose in **both** audiences, per the files-to-disk carveout below.)

### Files written to disk

Regardless of chat verbosity, content written to disk stays full prose: handoff thread files, checkpoints, ADRs, policies, deploy reports, plan files, PRDs. This mirrors `.claude/output-styles/hq.md` § "HQ-specific carveouts" — the terseness lives in chat, not in committed knowledge.

### Auto-Clarity from HQ

HQ's Auto-Clarity blocks (security warnings, irreversible actions, plan-mode plans, multi-step destructive sequences, files-to-disk full prose) are referenced rather than duplicated. They align with categories above.

## Relationship to other rules

| Rule | This policy's relationship |
|---|---|
| `hq-audience-mode` | **Sets the audience.** This policy is the operational filter; `hq-audience-mode` decides whether the active audience is the quiet plain-language default or the operator play-by-play. They compose. |
| Default "state one sentence before first tool call" | **Overridden** for routine operational tool calls and for per-step execution narration in the default audience. Preserved only for the genuinely substantive call. |
| `.claude/output-styles/hq.md` voice rules | **Orthogonal layer.** This policy governs *whether* to surface text; HQ governs *how* (terseness, warmth tokens) when surfacing. They compose: silent stays silent; surfaced text follows the active style. |
| Active output-style insight blocks | **Surfaced** — insights are substantive. The policy does not suppress them. |
| Auto-checkpoint `AUTO-CHECKPOINT REQUIRED` hook injection | The injection is system-to-agent. Silently write the thread file; no chat narration about checkpointing. |

## Examples

**Routine deps install (success)**

NOT:
> Running `pnpm install`.
> Pulling dependencies…
> Installed 47 packages. All green.

YES: *(silent — go straight to the next substantive step)*

**Recoverable lint failure**

NOT:
> Running lint.
> Lint failed: 3 errors in src/foo.ts.
> Auto-fixing…
> Re-running lint.
> Lint passed.

YES: *(silent — auto-fix and continue)*

**Recoverable install failure (transient)**

NOT:
```
npm ERR! ENOTFOUND registry.npmjs.org
npm ERR! network request failed
...
```

YES: *(silent — retry once, succeed, continue)*

**Unrecoverable blocker — missing creds**

NOT:
```
Error: AWS credentials not found
[stack trace]
```

YES:
> Missing AWS credentials for {company}. Need `AWS_PROFILE={company}` set, or run `hq login` and `/run {company}-deploy aws-creds`.
> Pick:
>   1. I'll set the env var
>   2. Run the credential fetch skill
>   3. Skip this step

**User decision required**

YES (unchanged from current behavior):
```
Two repos match "hq-pro":
  1. repos/private/hq-pro (canonical)
  2. companies/indigo/repos/hq-pro (symlink)
Pick:
```

**Tool call pre-sentence — ops vs substantive**

Operational (silent):
> *(no message — just runs `pnpm install`)*

Substantive (one-liner OK):
> Reading [foo.ts](src/foo.ts:42) to confirm the export shape.

**Destructive op (unchanged — Auto-Clarity full prose)**

YES (full prose, explicit confirm):
> **Warning:** This force-pushes to `main` and rewrites 4 commits already on origin. Anyone else with the branch checked out will lose work on next pull.
>
> Confirm before proceeding.

## Verification

After this policy lands, the following session behavior holds (run as observation, not blocking gate):

1. **Silent-on-success.** A benign tool-needing task produces zero pre-tool narration and zero progress chatter; just the substantive result.
2. **Silent-on-recoverable-failure.** Transient install / lint / hook-fixable failures resolve in the background with no raw stderr in chat.
3. **Surface-on-decision.** `/hqwork` / `/startwork` / decision queues still surface numbered options.
4. **`/hq-share` carveout.** URL prints inline on minting turn.
5. **`/deploy` carveout.** One-line "Deployed to {url}" surfaces.
6. **`/run-project` verbose.** Per-story narration unchanged.
7. **Auto-checkpoint silent.** Thread file lands in git, no chat narration about it.
8. **Trigger frontmatter.** `grep -E '^(when|on):' core/policies/quiet-by-default-narration.md` returns a hit, confirming the policy carries the trigger frontmatter that the SessionStart hook (`inject-policy-on-trigger.sh`) uses to surface it.
