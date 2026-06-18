---
name: project-summary
description: Render a branded visual artifact from a project's prd.json (plan summary) or brainstorm.md (research deck) and deploy it gated, returning a link.
allowed-tools: Read, Grep, Glob, Write, Edit, Bash(ls:*), Bash(cat:*), Bash(jq:*), Bash(date:*), Bash(mkdir:*), Bash(awk:*), Bash(grep:*), Bash(test:*), Bash(bash:*), Bash(.claude/skills/project-summary/scripts/deploy-summary.sh:*)
---

# Project Summary

Render a **visual, shareable artifact** for a project and deploy it via hq-deploy, returning a
link. Two modes:

- **plan mode** (default) — visualizes a finished PRD: objectives, the plan (story map),
  phasing, and product-style UX mockups (or an architecture diagram for backend work). Auto-run
  at the end of `/prd` and `/deep-plan` (their Step 8.9), and via `/project-summary {co}/{name}`.
- **deck mode** (`--brainstorm`) — visualizes a brainstorm as a research/findings deck: the
  framing, what we know / don't know, the premise verdict, the approaches compared with their
  tradeoffs, and the recommendation. Auto-run at the end of `/brainstorm`, and via
  `/project-summary {co}/{name} --brainstorm`.

**Guiding principle:** the source file already exists; this skill only *visualizes* it. It
reads `prd.json` (plan mode) or `brainstorm.md` (deck mode), never re-plans, and never touches
target repos. It is idempotent — rerun anytime to regenerate and redeploy at the same stable URL.

---

## Step 1: Resolve the project + mode

Accept `{co}/{name}`, a bare `{name}`, or a project directory path, plus an optional
`--brainstorm` flag (or a `brainstorm.md` path) selecting **deck mode**.

1. Locate the project dir:
   - `companies/{co}/projects/{name}/` when a company is given or inferable.
   - `projects/{name}/` or `personal/projects/{name}/` for personal / HQ projects (no company).
   - If only `{name}` is given, find it: `qmd search "{name}" --json -n 5` or check the
     locations directly.
2. Pick the mode + source file:
   - **deck mode** (`--brainstorm`, or input points at a `brainstorm.md`) → source is
     `{dir}/brainstorm.md`.
   - **plan mode** (default) → source is `{dir}/prd.json`.
   - If the chosen source is missing, **stop** with a one-line message:
     `No {source} at {path} — run /{prd|brainstorm} first.` (When called from a skill's auto-step
     the path is already known, so this never triggers.)
3. Set `{co}` (may be empty for personal projects), `{name}`, and `{mode}` for the rest of the flow.

## Step 2: Read project data

### Plan mode

Read `prd.json` (and `README.md` if present). Extract:

- `name`, `description`
- `metadata.goal`, `metadata.successCriteria`
- `metadata.audiences`, `metadata.designRef`, `metadata.repoPath`
- `metadata.nonGoals`, `metadata.dataModel`, `metadata.architectureNotes`, `metadata.integrations`
- `userStories[]` → `id`, `title`, `priority`, `labels`, `acceptanceCriteria`, `dependsOn`

Derive **phasing** from `priority` (group stories by priority ascending; respect `dependsOn`
ordering within a group). This is the "shape of it, ordered for execution."

### Deck mode

Parse `brainstorm.md` — its frontmatter (`company`, `status`, `source_idea_id`) and sections:

- `# {Title}` + the `> {framing}` blockquote (one-line problem/opportunity)
- `## Context`
- `## What We Know` (bullets) and `## What We Don't Know` (bullets)
- `## Premise Check` → the verdict token (STRONG / QUESTIONABLE / WEAK) + reasoning
- `## Narrowest Wedge` (if present)
- `## Approaches` → each `### Option {X}: {Name}` with **How it works**, **Tradeoffs**
  (Pro/Con bullets), **Effort** (S/M/L/XL), **When to choose this**
- `## Recommendation` → preferred option, **Key condition**, **Biggest risk**
- `## Next Steps` (checkbox bullets)

## Step 3: Resolve the design standard

Look for a company design pack:

```bash
ls companies/{co}/knowledge/design-styles/packs/*/pack.yaml 2>/dev/null
```

- **Pack found** → pick the bound/default pack (if multiple, prefer one whose `pack.yaml`
  `type: brand`; for Indigo this is `indigo-blueprint`). Then, per
  `companies/{co}/policies/*deploy*blueprint*` (load-at-authoring-time rules):
  1. Read the pack's `design-tokens.css` and inline it into `:root` of the artifact.
  2. Read the pack's `implementation.md` and build sections from its HTML/CSS blocks —
     copy the system, edit only the content. **Never hardcode hex; reference `var(--token)`.**
  3. Honor the typeface roles and single-accent discipline the pack defines.
- **No pack** (personal projects, or company without one) → inline the shipped fallback
  theme `.claude/skills/project-summary/templates/default.css` into `:root`. It uses the same
  token names, so the same markup renders correctly either way.

## Step 4: Decide the visuals

### Plan mode — mockup type (auto-detect)

Classify the project from `prd.json` to choose what to draw:

**User-facing product → UX / screen mockups** if ANY of:
- `metadata.audiences` names end users / customers (not just "developers" / "internal tooling"),
- `metadata.designRef` is non-empty,
- story titles or acceptance criteria contain UI words: page, screen, view, form, button,
  dashboard, modal, onboarding, wizard, table, list, UI, UX, component, layout, nav.

**Otherwise → architecture / flow diagram** (backend, CLI, data, infra): draw a labeled
box-and-arrow SVG of the system (inputs → components → outputs / data stores), derived from
`metadata.dataModel`, `metadata.integrations`, `metadata.architectureNotes`, and the stories.

In BOTH cases the mockups are **illustrative wireframes generated from the PRD**, drawn as
inline SVG/HTML styled with the resolved tokens, and each is clearly labeled
**"concept mockup — not final UI"** (use the `.concept-note` class). Do not imply these are
real screenshots.

### Deck mode — comparison visuals

No UX mockups. Instead draw, from `brainstorm.md`:
- a **premise verdict badge** (STRONG = `--pass`, QUESTIONABLE = `--warn`, WEAK = `--err`),
- an **options-comparison** of the approaches side by side: one card per option with its
  effort badge and Pro/Con tradeoffs, the recommended option visually highlighted (accent
  border / "RECOMMENDED" tag),
- the **recommendation** as a highlighted callout (preferred option + key condition + biggest risk).

## Step 5: Render index.html

Write a single self-contained file (inline CSS + inline SVG, **no external fetches** beyond
the brand's web-font `<link>` if the pack uses one) to:

```
workspace/project-summary/{slug}/index.html
```

Build slug: `{co}-{name}` for company projects, `personal-{name}` for personal ones; in **deck
mode** append `-brainstorm` (e.g. `personal-publish-kit-direct-brainstorm`) so plan and deck
artifacts never collide.

### Plan mode sections (in order)

1. **Hero** — kicker (`{co} · project`), `{name}` as `h1`, one-line goal as `.lead`.
2. **Objectives & success** — `metadata.goal` + `metadata.successCriteria` as `.checks`.
3. **The plan** — story-map table: `#` / `Story` / `Priority` (mirror the PRD-done screenshot;
   `id` in the `.num` column). One row per story.
4. **Phasing** — stories grouped by priority into phases, with a one-line intent per phase.
5. **Mockups** — UX screens OR architecture diagram per Step 4, each `.concept-note` labeled.
6. **Footer** — `metadata.nonGoals` (or "None defined") + `generated from prd.json · {date}`.

### Deck mode sections (in order) — a research/findings deck

1. **Title slide** — kicker (`{co} · brainstorm`), title as `h1`, the framing line as `.lead`,
   and the premise verdict badge.
2. **Context** — the `## Context` prose.
3. **What we know / What we don't** — two columns (`.grid2`), `.checks` lists.
4. **Approaches** — the comparison cards from Step 4 (effort badge + Pro/Con per option,
   recommended one highlighted).
5. **Recommendation** — highlighted callout: preferred option, key condition, biggest risk.
6. **Next steps** — the `## Next Steps` checklist, plus the promotion path.
7. **Footer** — `generated from brainstorm.md · {date}` (`date -u +%Y-%m-%d`).

Keep it responsive to 360px. Verify the file exists and is non-trivial (>2KB) before deploying.

## Step 6: Deploy + return the link

Run the deploy wrapper. App name is `{slug}-summary` in plan mode, `{slug}-brainstorm` in deck
mode (the build slug already carries the `-brainstorm` suffix, so pass it as the app name too).
Company slug is optional — omit/empty for personal projects:

```bash
# plan mode
bash .claude/skills/project-summary/scripts/deploy-summary.sh \
  "workspace/project-summary/{slug}" "{slug}-summary" "{co}"
# deck mode ({slug} ends in -brainstorm)
bash .claude/skills/project-summary/scripts/deploy-summary.sh \
  "workspace/project-summary/{slug}" "{slug}" "{co}"
```

It is idempotent (stable app name → stable URL), gates to the project's company when a
`cloud_uid` resolves from `companies/manifest.yaml`, and falls back to a password gate for
personal / no-company projects. Parse its `KEY=VALUE` output and report:

- Plan, company-gated → `Visual summary is live (members only): {LIVE}`
- Deck, company-gated → `Brainstorm deck is live (members only): {LIVE}`
- Password-gated → `… is live: {LIVE} — password: {PASSWORD} (copied to clipboard)`

**Non-fatal:** if the script exits non-zero (e.g. `ERR: no_identity`), do NOT fail the caller.
Report `skipped — {reason}` and continue. The calling skill must never be blocked by this deploy.

## Rules

- **Read-only on the project** — never edit `prd.json`, `brainstorm.md`, `README.md`, or any
  target repo. This is a visualization of existing planning output, subject to the no-implement rule.
- **The source file is the source of truth** — every value shown comes from `prd.json` (plan
  mode) or `brainstorm.md` (deck mode); never invent stories, options, criteria, or scope.
- **Stay on the brand** — when a company pack exists, build from its `implementation.md` and
  reference `var(--token)`; never hardcode colors or hand-roll a competing stylesheet.
- **Idempotent** — same project → same app name → same URL. Reruns refresh content in place.
- **Quiet + plain** — surface only the final link (or a one-line skip). No play-by-play.
- **Tenant isolation** — only ever read the resolved company's pack/policies and gate to that
  company. Never cross companies.
