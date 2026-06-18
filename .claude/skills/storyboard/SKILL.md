---
name: storyboard
description: Lock visual design before building — explore mockups on your preferred surface (Paper, HTML, Figma) and feed discovered changes back into the PRD.
allowed-tools: Read, Write, Edit, Grep, Glob, Bash(git:*), Bash(qmd:*), Bash(ls:*), Bash(date:*), Bash(mkdir:*), Bash(.claude/skills/storyboard/scripts/surface-config.sh:*), Bash(.claude/skills/_shared/journal.sh:*), Bash, AskUserQuestion, Agent
argument-hint: "[company] {project} [--surface paper|html|figma] [--design-led]"
---

# Storyboard — Lock Design Before You Build

The missing phase between planning and building. `/storyboard` sits in the chain:

```
/brainstorm ──► /plan | /deep-plan ──► /storyboard ──► /run-project
     │                                      ▲  │
     └────────── /storyboard (design-led) ──┘  └─► writes deltas back into prd.json
```

Its job is **not** "make a mockup" — Paper MCP and designed HTML already do that. Its job is to be a **gate with a feedback loop**: explore design on the surface you prefer, then capture what the design surfaced that changes the plan and write those changes back into `prd.json` before any story executes. Locking design first means you don't build a pile of code against a spec the design was about to change.

**Important:** This skill designs and revises the plan. It does not implement product code. Building happens in `/run-project`.

**User's input:** $ARGUMENTS

## When to Use

- A PRD exists (`prd.json`) and you want to design its screens/flows and harden the spec before building.
- A brainstorm exists but no PRD yet, and the project is UI-first — you want to explore visuals before `/plan` writes stories.
- The design process is surfacing changes to scope, screens, or data contracts and you want those captured in the PRD, not lost in chat.

For raw canvas work with no PRD loop, use `/run paper-designer`. For production UI polish on already-built code, reach for a dedicated design-polish skill (the `impeccable` skill, where installed).

## Step 1 — Parse Arguments & Resolve Project

From `$ARGUMENTS`, extract (in order, all optional except the project):

- `[company]` — if the **first word** matches a top-level key in `companies/manifest.yaml`, set `{co}` and strip it. Otherwise `{co}` is resolved later from the project path (companies vs personal).
- `{project}` — project slug.
- `--surface paper|html|figma` — per-run surface override (does not change the saved default).
- `--design-led` — force design-led mode even when a `prd.json` is present.

Resolve the project directory:

- `companies/{co}/projects/{slug}/` when a company is anchored, else search both `companies/*/projects/{slug}/` and `personal/projects/{slug}/` (use `qmd search "{slug}" --json` or `ls`).
- Set `{project_dir}` to the match. If `{slug}` is ambiguous across companies, ask the user which one.

## Step 2 — Detect Mode

Inspect `{project_dir}`:

| Found | Mode | Behavior |
|---|---|---|
| `prd.json` exists (and no `--design-led`) | **spec-led** (default) | Design the surfaces the PRD describes, then write deltas back into `prd.json` and lock design. |
| only `brainstorm.md` exists (or `--design-led`) | **design-led** | Explore visuals from the brainstorm; produce `design/design.md` that `/plan` then consumes. No `prd.json` writeback (there's nothing to write to yet). |
| neither exists | **short-circuit** | Tell the user: "No PRD or brainstorm found for `{slug}`. Run `/brainstorm {slug}` or `/plan {slug}` first, or give me a one-line description and I'll sketch from that." Stop unless they provide a description. |

Announce the resolved mode and project in one plain line.

## Step 3 — Resolve the Design Surface (set once, forgotten forever)

Resolve the surface preference with the helper:

```bash
.claude/skills/storyboard/scripts/surface-config.sh resolve --company "{co}" --surface "{flag-or-empty}"
```

It prints `surface=`, `figma=`, and `origin=` (one of `flag`, `company`, `global`, `unset`).

- **`origin=flag|company|global`** — use the resolved surface silently. Do not re-ask. (For `global`/`company`, you may note it in one line: "Designing on **{surfaces}** (your saved default).")
- **`origin=unset`** — this is the **first run**. Ask **once** with a single `AskUserQuestion`:
  - **Question:** "Which design surface should `/storyboard` use by default? I'll remember it and never ask again."
  - **Options:** `Paper + HTML (Recommended)` · `Paper MCP only` · `Designed HTML only` · `Figma references`
  - Then persist (default `figmaReferences: true` so Figma links are always allowed as references):

    ```bash
    .claude/skills/storyboard/scripts/surface-config.sh save --surface "paper,html" --figma true
    ```

    Save to the company override instead when the user wants this default scoped to one company: add `--company "{co}"`.

Resolution order is always: `--surface` flag → company override → personal default → first-run prompt. The saved default is global unless the user scopes it to a company.

## Step 4 — Load Design Context

Pull the same design sources the existing design workers use — do not invent a parallel system:

- **Design tokens / styles:** the design-styles catalog and any bound company brand pack (`core/packages/hq-pack-design-styles/`, and `companies/{co}/knowledge/design-styles/packs/` when a company is anchored — falls back to the shipped theme for personal projects). Use it for palette, type scale, spacing, and motion.
- **PRD context (spec-led):** read `prd.json` — `description`, `userStories[]` (titles + acceptance criteria define the screens/states to design), `metadata.audiences`, `metadata.designRef`, `metadata.dataModel`, `metadata.authModel`.
- **Brainstorm context (design-led):** read `brainstorm.md` — `## Recommendation`, `## What We Don't Know`, audience, and the chosen approach.
- **Policies:** if a company is anchored, note its hard-enforcement policies (frontmatter scan via `bash core/scripts/read-policy-frontmatter.sh`). When designing on Paper, the Paper MCP policies apply (see Step 5).

## Step 5 — Design Iteration

Iterate on the resolved surface(s). Storyboard the screens/flows the PRD or brainstorm describes, share for feedback, and revise. Keep iterating until the user signs off on the design.

### Surface: `paper` (Paper MCP)

Best for multi-screen flows and storyboards. Follow the `paper-designer` worker patterns and the Paper MCP policies:

- **Storyboard in Paper before writing component code** (`hq-paper-mcp-before-deck-code`, hard).
- **Run Paper MCP agents sequentially — never in parallel** (`hq-paper-mcp-sequential-agents`, hard). Paper operates on a shared canvas; concurrent `write_html` / `create_artboard` calls collide.
- Load the Paper guide once (`get_guide`), `get_basic_info` for artboards, then build one visual group per `write_html`. Review with `get_screenshot` after meaningful changes; `finish_working_on_nodes` when done.
- Export artboard screenshots into `design/mockups/` and note artboard refs (no raw node IDs in user-facing output).

If Paper Desktop isn't running / no `.paper` file is open, say so plainly and offer the `html` surface as a fallback rather than failing.

### Surface: `html` (designed HTML)

Best for web mockups and a shareable link. Generate designed HTML using the design tokens from Step 4, then preview and share via `/deploy` (its local preview always runs; surface the preview URL inline in one plain line). Save the HTML into `design/mockups/`.

### Surface: `figma`

When the user designs in Figma, capture **reference links and export specs** (frames, component names, token values) into `design/design.md` and `design/mockups/` rather than rendering. `/storyboard` records and reconciles Figma designs into the PRD; it does not drive Figma.

> Quick wireframe fallback: if no live surface fits (e.g. you just need a fast concept sketch from the PRD), the `project-summary` skill renders an SVG wireframe labeled "concept — not final UI."

## Step 6 — Design Delta → PRD Writeback (the defining mechanic)

After sign-off, run a **Design Delta** pass: enumerate what the design surfaced that changes the plan, in these buckets:

- **New stories** — screens/states the PRD didn't enumerate.
- **Changed acceptance criteria** — what the design made concrete or contradicted.
- **New non-goals** — scope the design revealed should be cut (also record via `/out-of-scope`).
- **Contract implications** — data model / API / auth changes the UI implies.
- **Open questions** — resolved or newly raised by the design.

Present the delta as a transparency header (`Design delta (N changes): 1. … 2. …`), then walk each change **one at a time** using a single `AskUserQuestion` per change — the strict `decision-queue-one-at-a-time` discipline. Never batch unrelated changes into one call. (In Codex, ask one question per turn with the plain-text decision-gate fallback.)

For each confirmed change, apply it to `prd.json`:

- add or edit entries in `userStories[]` (new screen → new story with acceptance criteria + `e2eTests`);
- append `{question, answer, decidedAt, decidedBy}` to `metadata.decisions[]`;
- update `metadata.nonGoals[]`, `metadata.dataModel`, `metadata.authModel` as confirmed;
- set `metadata.designRef` to the design artifact (`design/design.md`, plus Figma URL when used);
- set `metadata.designLocked: true`.

Then **regenerate `README.md` from the updated `prd.json`** (README is always derived from the PRD, never edited in reverse). In **design-led mode** there is no `prd.json` yet — skip the writeback; the deltas live in `design/design.md` for `/plan` to consume.

## Step 7 — Write Artifacts

Into `{project_dir}`:

- **`design/design.md`** — full-prose design rationale (full prose, no shorthand — this is a file on disk): surface(s) used, palette, type scale, spacing system, the screen/flow list, key interactions, and the design decisions with their reasoning. In design-led mode, also list the proposed screens/stories so `/plan` can pre-fill from them.
- **`design/mockups/`** — exported HTML and/or artboard screenshots; Figma links when that surface was used.
- **Preview URL** — when the `html` surface was used, surface the `/deploy` link inline.
- **Updated `prd.json` + regenerated `README.md`** (spec-led only).
- **Board sync** — read `companies/manifest.yaml` for the company `board_path`; if present, set the project's `board.json` entry `status: "design_locked"` and bump `updated_at`. Skip silently if there's no board.
- **Orchestrator state** — in `workspace/orchestrator/state.json`, set the project's entry to reflect design lock (e.g. note `designLocked` in the project record) so `/run-project` can read it. Skip silently if the project isn't registered yet.
- **Journal** — open and finalize a session journal:

  ```bash
  .claude/skills/_shared/journal.sh open storyboard "{project_dir}"
  ```

  Record the surface used, the design decisions, and the applied deltas at `{project_dir}/journal/{ISO8601}-storyboard.md`.

## Step 8 — Handoff

State the outcome in one or two plain lines and point to the next step:

- **spec-led:** "Design's locked for **{slug}** — {N} changes folded into the PRD. Ready to build with `/run-project {slug}`." Include the preview URL if there is one.
- **design-led:** "Design explored for **{slug}** — wrote `design/design.md`. Run `/plan {slug}` and it'll pre-fill from the design."

## Codex Notes

- Replace `Agent` sub-agents with Codex sub-agents when available, or run the same phases inline and persist to the journal / `design/design.md` between phases.
- No plan-mode switching; iterate inline.
- `qmd` runs as the CLI (`qmd search/query "..." --json`).
- One decision per turn in the Design Delta pass; use the plain-text decision-gate fallback for sign-off when structured questions aren't available.

## Related

- Upstream: [`/brainstorm`](../brainstorm/SKILL.md), [`/plan`](../plan/SKILL.md), `/deep-plan`
- Downstream: `/run-project`, `/execute-task`
- Design surfaces: `/run paper-designer`, `/deploy`, plus the `impeccable` and [`project-summary`](../project-summary/SKILL.md) skills
- Delta discipline: [`/decision-queue`](../decision-queue/SKILL.md), [`/out-of-scope`](../out-of-scope/SKILL.md)
- Paper policies: `core/policies/hq-paper-mcp-before-deck-code.md`, `core/policies/hq-paper-mcp-sequential-agents.md`
