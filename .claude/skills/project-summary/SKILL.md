---
name: project-summary
description: Render a branded visual artifact from a project's prd.json (plan summary) or brainstorm.md (research deck) and deploy it gated, returning a link.
allowed-tools: Read, Grep, Glob, Write, Edit, Bash(ls:*), Bash(cat:*), Bash(jq:*), Bash(date:*), Bash(mkdir:*), Bash(awk:*), Bash(grep:*), Bash(test:*), Bash(bash:*), Bash(python3 -m http.server:*), Bash(.claude/skills/project-summary/scripts/deploy-summary.sh:*)
---

# Project Summary

Render a **visual, shareable artifact** for a project and deploy it via hq-deploy, returning a
link. Two modes:

- **plan mode** (default): visualizes a finished PRD as a broadcast page: the decision, the
  system as a diagram, the plan as a storyboard strip of phases, one chart when the PRD has
  numbers, and the guardrails. Auto-run at the end of `/prd` and `/deep-plan` (their Step 8.9),
  and via `/project-summary {co}/{name}`.
- **deck mode** (`--brainstorm`): visualizes a brainstorm as a findings deck: the
  recommendation first, the options as comparable cards, the shape of what it builds on, what
  we know and don't, next steps. Auto-run at the end of `/brainstorm`, and via
  `/project-summary {co}/{name} --brainstorm`.

**Guiding principle:** the source file already exists; this skill only *visualizes* it. It
reads `prd.json` (plan mode) or `brainstorm.md` (deck mode), never re-plans, and never touches
target repos. It is idempotent, rerun anytime to regenerate and redeploy at the same stable URL.

**The bar:** a reader gets the point in ten seconds from the first screen, and can get every
detail by clicking. The page is a visual, broadcast-style executive summary, not a rendering of
the source file. Anti-pattern: a story table followed by the same stories again as phase lists.

---

## Step 1: Resolve the project + mode

Accept `{co}/{name}`, a bare `{name}`, or a project directory path, plus an optional
`--brainstorm` flag (or a `brainstorm.md` path) selecting **deck mode**.

1. Set `{co}` from the input when a company is given or inferable (empty for personal
   projects). When `{co}` is set, run `bash core/scripts/work-mesh-live-bind-trusted.sh --company "{co}"` now, before any read under `companies/{co}/`. The scope guard blocks company paths until the session is bound to `{co}`.
2. Locate the project dir:
   - `companies/{co}/projects/{name}/` when a company is given or inferable.
   - `projects/{name}/` or `personal/projects/{name}/` for personal / HQ projects (no company).
   - If only `{name}` is given, find it: `qmd search "{name}" --json -n 5` or check the
     locations directly.
3. Pick the mode + source file:
   - **deck mode** (`--brainstorm`, or input points at a `brainstorm.md`): source is
     `{dir}/brainstorm.md`.
   - **plan mode** (default): source is `{dir}/prd.json`.
   - If the chosen source is missing, **stop** with a one-line message:
     `No {source} at {path}, run /{prd|brainstorm} first.` (When called from a skill's auto-step
     the path is already known, so this never triggers.)
4. Keep `{co}`, `{name}`, and `{mode}` for the rest of the flow.

## Step 2: Read project data and build the fact ledger

### Plan mode

Read `prd.json` (and `README.md` if present). Extract:

- `name`, `description`
- `metadata.goal`, `metadata.successCriteria`
- `metadata.audiences`, `metadata.designRef`, `metadata.repoPath`
- `metadata.nonGoals`, `metadata.dataModel`, `metadata.architectureNotes`, `metadata.integrations`
- `metadata.decisions[]`, `metadata.openQuestions[]`, `metadata.rolloutStrategy`
- `userStories[]` to `id`, `title`, `priority`, `labels`, `acceptanceCriteria`, `dependsOn`

Derive **phasing** from `priority` (group stories by priority ascending; respect `dependsOn`
ordering within a group). Give each phase a 3 to 6 word intent from its stories' titles and
labels (for example "Prove the numbers", "Migrate the accounts", "Remove the old path").

### Deck mode

Parse `brainstorm.md`, its frontmatter (`company`, `status`, `source_idea_id`) and sections:

- `# {Title}` + the `> {framing}` blockquote (one-line problem/opportunity)
- `## Context`
- `## What We Know` (bullets) and `## What We Don't Know` (bullets)
- `## Premise Check` to the verdict token (STRONG / QUESTIONABLE / WEAK) + reasoning
- `## Narrowest Wedge` (if present)
- `## Overlap & Cruft` table (if present) to existing items with verdicts
- `## Approaches` to each `### Option {X}: {Name}` with **How it works**, **Tradeoffs**
  (Pro/Con bullets), **Effort** (S/M/L/XL), **When to choose this**
- `## Recommendation` to preferred option, **Key condition**, **Biggest risk**
- `## Next Steps` (checkbox bullets)

### The fact ledger (both modes)

Before writing markup, list in your working notes every **number, date, name, and status**
the page will show, each with where it came from in the source. The hero KPI band, the pills,
and any chart draw only from this ledger. A number that is not in the source does not go on
the page. A forecast stays a forecast ("~", "about", "planning range").

When the source contradicts itself (segments that do not sum to the stated total, two counts
for the same thing), show the figure the source states most directly (the headline total, the
audiences list) and add a `.note` or a `data-tip` naming the other figure and where it
appears. Never reconcile silently and never pick a number the source does not state.

**Phase state (plan mode):** a phase whose stories all have `passes: true` is `.done`; the
first phase with an unpassed story is `.now`; the rest are plain. Inside a phase, order
stories so that any `dependsOn` target in the same phase comes first; otherwise keep id order.

## Step 3: Resolve the design standard

The shipped theme `.claude/skills/project-summary/templates/default.css` is the visual
system for every summary: dark ground, one accent, mono labels, and the component set in
`templates/components.md`. Always inline it into `<style>`.

Then look for a company design pack:

```bash
ls companies/{co}/knowledge/design-styles/packs/*/pack.yaml 2>/dev/null
```

- **Pack found**: a pack counts only if its directory is not under `_archive/`, its
  `pack.yaml` is `type: brand` (or declares web/HTML as a medium), and it ships a
  `design-tokens.css`. Video, explainer, and asset packs are not web packs; ignore them. For
  a qualifying pack, read its `design-tokens.css`
  and inline its `:root` block **after** `default.css` so the pack's values override the
  theme's tokens (colors, fonts, radii). Keep the component markup. If the pack defines a
  wordmark or eyebrow, put it in the hero kicker. Never hardcode hex in `index.html`.
- **No pack**: `default.css` alone.
- A company policy that mandates a specific deploy scaffold for all artifacts wins on tokens
  and type: inline its tokens the same
  way and honor its named components where they overlap. The broadcast structure, the
  storyboard strip, the disclosure rules, and the one-chart rule still apply.
- A company policy that mandates a **light editorial** page style for general deploys does not
  change the structure of a summary page; apply its tokens if a pack exists, otherwise use
  the theme. Say so in one line when you report the link.

## Step 4: Decide the visuals

Every page gets, in this order: a hero with a KPI band, one decision callout, one diagram, the
storyboard strip (plan) or option cards (deck), at most one chart, and the guardrails. Pick the
specific drawings from the source:

### Diagram (both modes)

- **Plan, user-facing product** (`metadata.audiences` names end users, `designRef` set, or
  story titles use page/screen/view/form/dashboard/modal/onboarding/table/UI words) to a
  **flow diagram** of the user path (input to system to what the person sees) **plus** screen
  wireframes in Step 5 section 04.
- **Plan, backend/CLI/data/infra**: an **architecture diagram** (inputs, components,
  outputs and data stores), derived from `dataModel`, `integrations`, `architectureNotes`, and
  the stories. Label boxes with the story ids they come from.
- **Plan, both** (a backend program with a few screens): the architecture diagram, with the
  screens as boxes in it, plus the wireframes in section 04.
- **Deck**: a diagram of the recommended approach, or when `## Overlap & Cruft` exists, an
  **overlap map**: existing items as boxes colored by verdict (extend = accent, merge = pass,
  replace = warn, remove = err) around the new thing.

Draw as inline SVG with the classes in `components.md` (`.s-box`, `.s-line`, `.t-h` …),
classes only, no color attributes. Ship a horizontal `.flow-h` and a stacked `.flow-v` for
phones. Keep `.flow-h` at a viewBox width of 900 or less and size the viewBox height to the
content, so 12px text renders at 12px or larger inside the 1040px wrap. Label every diagram
`concept diagram` via `.concept-note`.

### Chart (at most one)

Draw a bar block (`.bars`) only when the source states two or more comparable quantities with
a unit: stories per phase, user segments, cost ranges per option, coverage percentages. Show
unit, period, and source in `.sub`. If the only numbers are singletons, they belong in the KPI
band, not a chart. Never invent, extrapolate, or normalize numbers to make a chart work.

### Cards

- Plan: `metadata.decisions` as decision cards (max six visible; the remaining decisions,
  not all of them, go behind `details.more` in full); outputs or audiences as cards when the
  PRD lists them. A long answer is **cut, never reworded**: keep the source's first clause and
  put the full answer in `data-tip` on the card title.
- Deck: one card per option, the recommended one `.rec`; use case cards grouped under
  colored `.group-kicker` headings when the brainstorm lists what the idea enables.

Each card carries a stroke icon from `components.md` that matches its meaning. No emoji.

### Mockups (plan, user-facing only)

Illustrative wireframes generated from the PRD, drawn as inline SVG with `.mock`, each labeled
**concept mockup, not final UI** with `.concept-note`. Two at most on the page; more go behind
`details`. Do not imply these are real screenshots.

## Step 5: Render index.html

Start from the scaffold: `templates/plan-scaffold.html` or `templates/deck-scaffold.html`.
Inline the CSS per Step 3, fill every `{{placeholder}}` from the fact ledger, delete any block
the source cannot fill. Write a single self-contained file (inline CSS + inline SVG, **no
external fetches** beyond a brand web-font `<link>` if the pack uses one) to:

```
workspace/project-summary/{slug}/index.html
```

Build slug: `{co}-{name}` for company projects, `personal-{name}` for personal ones; in **deck
mode** append `-brainstorm` (e.g. `personal-publish-kit-direct-brainstorm`) so plan and deck
artifacts never collide.

### Writing rules (broadcast style)

- **Headline answers the question.** `h1` says what is happening and the one word that
  matters, in one sentence, with a single `<em>`. Not the project slug.
- **Standfirst, then stop.** `.lead` is two or three short sentences: why, and what done looks
  like. No background paragraph in the hero.
- **Labels over prose.** Section `h2` is 2 to 5 words. `.sub` is one line. Card copy is one
  sentence. A bullet is one line.
- **Above the fold: 120 words at most** (hero + first callout), excluding pills and KPI labels.
- **The source's own words**, shortened. Never paraphrase a decision into a different claim.
- **Numbers carry units and qualifiers** ("1,200 users", "about 280 USD a month", "about 5%").
- No em dashes, no exclamation marks, no filler ("it's worth
  noting", "in order to"). Run the `/humanize` checklist mentally on every visible string.

### Progressive disclosure (details are hidden, not deleted)

- Stories live inside each `.phase` behind `details > summary`, never as a flat table.
- Acceptance criteria, architecture notes, rollout strategy, open questions, the full decision
  list, "how it works" prose, and the brainstorm context go in `details.more` blocks under the
  section they belong to.
- A term or number that needs one sentence of explanation gets `data-tip="…"` and
  `tabindex="0"` so it shows on hover and keyboard focus.
- `details` content must still be real content: a reader who opens everything sees the whole
  source, nothing less.

### Plan mode sections (in order)

1. **Hero**: kicker `{co} · plan · {date}`, headline, standfirst, fact pills (story count,
   phase count, decided date, status), KPI band of three or four source numbers.
2. **01 The decision**: the one `.callout`: the biggest risk or the decision that gates the
   work (from `openQuestions`, `rolloutStrategy`, or the highest-priority story). Then decision
   cards from `metadata.decisions`.
3. **02 How it works**: the diagram.
4. **03 The plan**: the storyboard strip: one `.phase` per priority group, intent line,
   story count, stories behind `details` with `dependsOn` as `.dep`.
5. **04 What people will see**: mockups (user-facing projects only; omit otherwise).
6. **05 One chart**: only when the ledger has comparable quantities; omit otherwise.
7. **06 Done means**: success criteria (`.panel.pass`) beside non-goals (`.panel.err`), then
   `details` for architecture notes, rollout, open questions.
8. **Footer**: `generated from prd.json · {date} · {co}/{name}` and counts.

### Deck mode sections (in order)

1. **Hero**: kicker `{co} · brainstorm · {date}`, the recommendation as the headline, the
   framing line as standfirst, pills (premise verdict colored, option count, recommended
   option, effort), KPI band from the brainstorm's own numbers.
2. **01 Recommendation**: the one `.callout`: option, why, key condition, biggest risk.
3. **02 Options**: `.cards`, one per approach, effort `.size`, two or three pros/cons, the
   recommended one `.rec`; "how it works" behind `details`.
4. **03 What it builds on**: the overlap map or approach diagram, with a verdict legend.
5. **04 Known and unknown**: two panels of short bullets; full `## Context` behind `details`.
6. **05 Next steps**: `ul.tasks` with owners when named.
7. **Footer**: `generated from brainstorm.md · {date}` and status.

### Check before deploying

- Serve the folder with `python3 -m http.server --bind 127.0.0.1 8766 --directory <dir>` and open
  `http://127.0.0.1:8766/` in the Browser pane (never `file://`), at desktop width and at 390px. Fix overflow, clipped SVG text, bars without labels, and any
  section that is a wall of text. Screenshots are for your own eyes; report what you fixed in
  one line, not the images.
- Count the words above the fold. Over 120: cut.
- Every KPI, pill, and chart value is in the fact ledger.
- Every `details` opens and contains the long-tail content it promises.
- No hex colors in `index.html` outside `<style>`; no emoji; no external scripts.
- File exists and is non-trivial (>6KB).

## Step 6: Deploy + return the link

Run the deploy wrapper. App name is `{slug}-summary` in plan mode, `{slug}-brainstorm` in deck
mode (the build slug already carries the `-brainstorm` suffix, so pass it as the app name too).
Company slug is optional, omit/empty for personal projects:

```bash
# plan mode
bash .claude/skills/project-summary/scripts/deploy-summary.sh \
  "workspace/project-summary/{slug}" "{slug}-summary" "{co}"
# deck mode ({slug} ends in -brainstorm)
bash .claude/skills/project-summary/scripts/deploy-summary.sh \
  "workspace/project-summary/{slug}" "{slug}" "{co}"
```

It is idempotent (stable app name to stable URL), gates to the project's company when a
`cloud_uid` resolves from `companies/manifest.yaml`, and uses a password gate only for
personal / no-company projects. A company deck is deployed into that company's org
(`X-Org-Slug: {co}` on every call). If the company has no `cloud_uid` or its gate cannot be
proven, the script exits with `ERR: company_uid_unresolved` or
`ERR: company_gate_unverified` and uploads nothing. Report that error and do not retry
without `{co}`. Parse its `KEY=VALUE` output and report:

- Plan, company-gated to `Visual summary is live (members only): {LIVE}`
- Deck, company-gated to `Brainstorm deck is live (members only): {LIVE}`
- Password-gated to `… is live: {LIVE}, password: {PASSWORD} (copied to clipboard)`

**Non-fatal:** if the script exits non-zero (e.g. `ERR: no_identity`), do NOT fail the caller.
Report `skipped, {reason}` and continue. The calling skill must never be blocked by this deploy.

## Rules

- **Read-only on the project**: never edit `prd.json`, `brainstorm.md`, `README.md`, or any
  target repo. This is a visualization of existing planning output, subject to the no-implement rule.
- **The source file is the source of truth**: every value shown comes from `prd.json` (plan
  mode) or `brainstorm.md` (deck mode) via the fact ledger; never invent stories, options,
  criteria, numbers, or scope.
- **Visual first, text behind a click**: a page that shows the same list twice, or a table
  of stories on the first screen, fails the bar. Rebuild it.
- **One accent, color means state**: green verified, amber conditional, red excluded,
  accent the subject. No color for variety.
- **Stay on the brand**: pack tokens override theme tokens; never hand-roll a competing
  stylesheet or hardcode colors.
- **Idempotent**: same project to same app name to same URL. Reruns refresh content in place.
- **Quiet + plain**: surface only the final link (or a one-line skip). No play-by-play.
- **Tenant isolation**: only ever read the resolved company's pack/policies and gate to that
  company. Never cross companies.
