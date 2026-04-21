# design.md Spec

`design.md` is the per-repo design context file used across HQ. It gives design workers (and any agent performing visual or UX work) the brand, product, and aesthetic context they need to produce output that is on-brand rather than generic.

**Canonical filename:** `design.md` (placed in the repo root)
**Consumed by:** `impeccable-designer`, company-scoped design workers (e.g. `hpo-designer`), and any agent running design-adjacent skills (`frontend-design`, `polish`, `typeset`, `colorize`, `audit`)
**Format:** Markdown with no YAML frontmatter

---

## Backward Compatibility Note

The legacy filename is `.impeccable.md`. Workers and scripts MUST check both names, in this order:

1. `design.md` (canonical — preferred for all new repos)
2. `.impeccable.md` (legacy — supported indefinitely for existing repos)

When both files are present, `design.md` takes precedence. Do not delete `.impeccable.md` from an existing repo without migrating its content to `design.md` first.

New repos: create `design.md`. Existing repos: rename on next design task (copy content verbatim, delete old file, commit).

---

## Section Definitions

A `design.md` file MUST contain all seven sections listed below, in the order listed. Optional items within a section may be omitted when not applicable.

---

### `## Brand`

**Required.**

**Purpose:** Establishes who the brand is and what aesthetic territory it occupies. This is the emotional and cultural anchor for all design decisions.

**What to include:**

- Brand name and one-line product/company description (Required)
- Aesthetic positioning — what the brand feels like and what it explicitly is not (Required). Use concrete cultural comparators (e.g. "Aesop, not Gatorade") rather than abstract adjectives alone.
- Brand personality in 2–4 short phrases (Required)

**Format notes:**

- Write in plain prose, not bullet lists
- Bold the brand name on first use
- Keep it to 3–6 sentences — this is a summary, not a brand bible

**Example:**

```markdown
## Brand

**Acme Co** — artisan cold brew. Craft and slowness as a philosophy. Think Blue Bottle or Intelligentsia, not Starbucks or Dunkin'. Warm, unpretentious, detail-obsessed.
```

---

### `## Product Context`

**Required.**

**Purpose:** Orients the designer to what this specific repo does, who uses it, and what the critical flows are. Prevents design decisions that are technically correct but contextually wrong (e.g. designing a mobile-first experience for an internal desktop tool).

**What to include:**

- **What this repo does** — one sentence on the app's purpose and any key technical constraints (Required)
- **Primary users** — who actually opens this product, and whether it is internal or customer-facing (Required)
- **Surface area** — which routes or screens exist, device targets, interaction model (Required)
- **Critical flows** — numbered list of the 2–5 flows that matter most (Required)
- **Tech stack** — framework, UI library, language (Required)
- Any known gotchas or constraints relevant to design work (Optional)

**Format notes:**

- Use a definition-style bullet list (`- **Label:** content`) for the first five items
- Critical flows should be a numbered sub-list under the bullet
- Keep it factual and specific — avoid marketing language here

---

### `## Tone & Voice`

**Required.**

**Purpose:** Defines how the product speaks. Prevents copy that is technically correct but tonally off-brand.

**What to include:**

- 3–6 tone descriptors, each as a short phrase or sentence (Required)
- At least one "never" — explicit anti-patterns for copy and voice (Required)

**Format notes:**

- Use a flat bullet list
- Lead with the most distinctive quality
- "Never" items should be concrete, not generic (not "never be boring" — that is not actionable)

---

### `## Design Direction`

**Required.**

**Purpose:** The normative design commitment for this repo. Everything in this section is binding — workers treat it as a source of truth for visual decisions.

**`style-pack:` field (Optional):**

Immediately after the section header, before any prose, workers check for a `style-pack:` declaration:

```markdown
## Design Direction

style-pack: <pack-id>  <!-- optional: links to registry.yaml for resource resolution -->
```

When `style-pack:` is present, workers that support pack resolution look up `<pack-id>` in `knowledge/public/design-styles/registry.yaml` and load the files listed under `context_paths.required` in the pack's `pack.yaml` (style guide, design tokens, implementation notes). Files listed under `context_paths.optional` may also be loaded for richer context. The inline Design Direction content takes precedence over pack defaults for any conflicting rule. If `style-pack:` is omitted, workers use inline content only.

**What to include:**

- Opening commitment statement — which design system or aesthetic this repo commits to (Required)
- **Typography** — named typefaces, weights, and their intended roles (Required)
- **Color palette** — named palette with usage rules (Required)
- **Shape & effects** — corner radii, shadows, elevation model (Required)
- **Spacing & density** — whitespace philosophy, grid approach (Required)
- Sub-sections for surface-specific guidance (Optional, e.g. `### Chart-Specific Guidance`, `### Component-Specific Guidance`)

**Format notes:**

- Open with a single declarative sentence naming the design system this repo commits to
- Use bold labels for each sub-topic within the section
- Specific values (hex codes, px sizes, font names) should be exact, not approximate
- Sub-sections use `###` headers

---

### `## Anti-Patterns`

**Required.**

**Purpose:** The explicit deny list. Workers and humans should treat these as hard rules, not suggestions. Audit skills (`hpo-designer audit`, `impeccable-designer audit`) scan for violations of this section.

**What to include:**

- One or more named sub-categories of anti-patterns (e.g. Typography, Color, Shape & Effects, Layout) (Required — use at least two categories)
- Each anti-pattern as a `❌` bullet with a specific, actionable description (Required)
- For legacy violation callouts: note which specific files contain the pattern (Optional but recommended when known)

**Format notes:**

- Use `###` headers for each category
- Use `❌` prefix on every bullet (not `- [ ]`, not `- ⛔`)
- Be concrete: `❌ Geist (create-next-app default — not HPO)` is better than `❌ wrong font`
- A "Known Violations" sub-section may follow Anti-Patterns to track migration targets (Optional)

**Optional: `## Known Violations (Migration Targets)`**

When legacy anti-patterns exist in the codebase and have not yet been removed, list them here with the specific file and a remediation command. This section is separate from Anti-Patterns proper.

---

### `## Quality Bar`

**Required.**

**Purpose:** Gives workers (and humans) a final check before shipping any visual change. The Quality Bar translates abstract brand standards into concrete pass/fail questions.

**What to include:**

- 2–4 named tests, each as a question or check a human can actually apply (Required)
- For each test: the question, and what "fail" looks like (Required)
- Pointers to worker skills that remediate failures (Optional but recommended)

**Format notes:**

- Number the tests
- State each test as a question in quotes or as a bolded label followed by the criterion
- Keep language direct — this is a checklist, not a manifesto

---

### `## References`

**Required.**

**Purpose:** Lists canonical sources of truth for brand assets, design tokens, worker configs, and live references. Workers use this section to resolve imports and verify current standards.

**What to include:**

- Path to brand guidelines file (Required if exists)
- Path to design tokens file(s) — CSS custom properties, DTCG JSON, or equivalent (Required if exists)
- Path to the design worker yaml for this repo (Required if exists)
- URL to any live design reference (deck, staging site, Figma) (Optional)
- Any other files a worker should read before making design decisions (Optional)

**Format notes:**

- Use a flat bullet list
- Format: `path/or/url — description of what this file contains`
- Use HQ-relative paths (from the HQ root), not absolute paths

---

## Complete Example

The following is the canonical real-world `design.md` for the HPO chart-renderer repo. It is the reference implementation of this spec.

---

```markdown
# design.md — HPO Chart Renderer

<!--
  Design context for the HPO chart renderer. Consumed by `hpo-designer` and
  the shared `impeccable-designer` worker.

  Source of truth: companies/hpo/knowledge/brand/brand-guidelines.md
-->

## Brand

**HPO** — sparkling protein water. Functional nutrition meets elevated lifestyle. Think Aesop or Le Labo, not Gatorade or Quest. Editorial, warm, quietly confident.

## Product Context

- **What this repo does:** Next.js app that renders a fixed set of data visualizations for HPO blog articles. Each chart route renders at an exact pixel size (800×400 or 800×500) so the content team can screenshot the output and drop the PNG into a CMS post.
- **Primary users:** HPO content / marketing team. Internal only, never customer-facing directly — the output (PNG) is what customers see in blog posts.
- **Surface area:** `app/page.tsx` index + `app/charts/{slug}` routes (~8 charts today). Desktop-only, no mobile, no forms, no interactive drilldowns. A chart is a single static composition.
- **Critical flows:**
  1. Content editor opens `/` to find the chart index
  2. Clicks into `/charts/{slug}` and confirms the chart looks right
  3. Screenshots at exact size → drops PNG into Shopify blog article
- **Tech stack:** Next.js (latest, with breaking changes — read `node_modules/next/dist/docs/` before writing code, see `AGENTS.md`), TypeScript, Tailwind CSS.

## Tone & Voice

- Quiet confidence. Never shouting.
- Sensorial — language evokes taste, texture, warmth.
- Knowing, grounded. Assume the reader is intelligent.
- Female-forward but universal.
- Never: bro-coded, supplement-industry, gym-sweat, pharma, "powered by AI".

## Design Direction

style-pack: hpo-brand  <!-- optional: links to registry.yaml for resource resolution -->

This repo commits to the **HPO rebrand editorial pastel/serif system**. Charts must be legible when extracted from context (i.e., sitting alone in a blog post) and should read as unmistakably HPO. Specifically:

- **Serif display** (Libre Caslon Display) for chart titles and editorial moments.
- **Condensed sans** (Barlow Condensed, uppercase, expanded tracking) for axis labels, legends, source lines, unit labels.
- **Humanist sans** (Inter, 300–400 weight) for body annotations and tooltips only.
- **Six-pastel palette** (lavender, lilac, pink, peach, yellow, mint) as the categorical chart palette — one pastel per series, cycling in order.
- **Signature 135° pastel gradient** reserved for cover/lead charts or hero stat moments, not every chart.
- **Flat design** — no drop shadows on bars, no 3D effects, no gradient fills on individual bars (use flat pastels).
- **Negative space as the dominant element** — charts breathe. 60–70% of each frame is whitespace. No crowded grids.
- **20–24px card radii** on any wrapping container.

### Chart-Specific Guidance

- **Background:** `var(--light-bg)` (`#FAFAFA`), never white.
- **Gridlines:** `rgba(0,0,0,0.08)` (hairline divider), never solid black or gray.
- **Bars / lines:** solid pastels from the six-color palette, rotated in order (lavender, lilac, pink, peach, yellow, mint). One pastel per data series.
- **HPO-as-hero:** when comparing HPO to competitors, HPO gets lavender or the primary gradient accent; competitors get neutral gray (`#C8C8C8`) to visually de-emphasize.
- **Axis labels:** Barlow Condensed uppercase, `0.25em` tracking, `clamp(10px, 0.8vw, 13px)`, `#888888`.
- **Chart title:** Libre Caslon Display 400, mixed case (never uppercase), `clamp(24px, 3vw, 36px)`, `#1a1a1a`.
- **Source line:** Inter 300, 10–12px, `#888888`, lowercase.
- **Data labels:** Inter 400, 11–13px, `#1a1a1a`.
- **Accent dots / legend markers:** 8–10px circles at 50% border-radius.
- **No shadows, no bevels, no 3D.**

## Anti-Patterns

The following are **never** acceptable in this repo. `hpo-designer audit` will flag each.

### Typography

- ❌ Montserrat (legacy brand only)
- ❌ Geist (create-next-app default — not HPO)
- ❌ Inter used as a display/chart-title face
- ❌ All-caps chart titles (mixed case Libre Caslon Display only)
- ❌ Letter-spacing on body annotations
- ❌ `font-weight: 800` on titles (use Libre Caslon 400 or 900)

### Color

- ❌ Legacy Plum `#4d0d2e` (currently in `app/page.tsx` — must be removed)
- ❌ Legacy Orange `#ef4323` (currently in `app/page.tsx` — must be removed)
- ❌ Legacy Cream `#fff6f1` (currently in `app/page.tsx` — must be removed)
- ❌ Legacy Yellow `#f3d60e`
- ❌ Legacy Red/Brown `#bb060a`, `#602f00`, `#f16223`
- ❌ Cyan/purple AI-slop gradients
- ❌ Neon accents on charts
- ❌ Gradient text on metrics or chart titles
- ❌ Rainbow categorical palettes (stick to the six pastels)

### Shape & Effects

- ❌ 50px pill buttons (legacy)
- ❌ Drop shadows on bars/cards (flat design)
- ❌ Glassmorphism / backdrop-blur
- ❌ Neumorphism
- ❌ Sharp-corner cards
- ❌ 3D chart effects
- ❌ Bounce easing on any animation
- ❌ Gradient fills on individual bars

### Imagery & Iconography

- ❌ Protein powder product isolation
- ❌ Shaker bottles, gym equipment
- ❌ Gym sweat, workout aesthetics
- ❌ Complex pictographic icons
- ❌ Stock chart emojis

### Layout & Copy

- ❌ Dense dashboard grids
- ❌ Card grids with more than 3 columns
- ❌ "Loading your experience..." copy
- ❌ Uppercase headlines or chart titles
- ❌ CTA shouting — the index page lists charts, it doesn't sell

## Known Violations (Migration Targets)

The following files contain legacy tokens and need to be rebranded. Run `/run hpo-designer apply-rebrand` to convert:

- `lib/chart-config.ts` — **color source of truth**. Hardcodes all five legacy hex values. Replace with design token imports.

## Quality Bar

Before shipping any visual change from this repo, apply **both** tests:

1. **AI Slop Test:** "If I showed this chart to someone and said 'AI made this,' would they believe me immediately?" If yes, keep working.
2. **HPO Rebrand Check:** "Could this chart sit on a slide in hpo-rebrand-deck.vercel.app without looking out of place?" If no, keep working.

Use `/run hpo-designer review` to get specific violations. Use `frontend-design`, `polish`, `typeset`, or `colorize` skills via `hpo-designer` to remediate.

## References

- `companies/hpo/knowledge/brand/brand-guidelines.md` — full style guide
- `companies/hpo/knowledge/brand/design-tokens.css` — import these custom properties directly into `app/globals.css`
- `companies/hpo/knowledge/brand/design-tokens.json` — DTCG format for tooling
- `companies/hpo/workers/hpo-designer/worker.yaml` — the design worker that operates on this repo
- https://hpo-rebrand-deck.vercel.app/ — live design reference deck (source of truth)
```

---

## Usage

### How workers load design.md

Workers that perform design tasks MUST follow this loading protocol at the start of every task:

1. Check for `design.md` in the target repo root. If present, read it.
2. If absent, check for `.impeccable.md` in the target repo root. If present, read it.
3. If neither is present, run the `teach-impeccable` skill (or equivalent context-gathering flow) to create `design.md` before proceeding with any design work.
4. Never infer brand context from code alone — code tells you what was built, not who it is for.

### What workers do with design.md

| Section | Primary use |
|---------|-------------|
| Brand | Sets aesthetic territory; informs all tone decisions |
| Product Context | Scopes work to the correct surface, device target, and user type |
| Tone & Voice | Governs all copy generated or reviewed |
| Design Direction | Binding rules for typography, color, shape, and effects |
| Anti-Patterns | Input to audit skills; hard deny list for generated output |
| Quality Bar | Final check before any visual change is marked complete |
| References | Source resolution — workers load tokens and guidelines from these paths |

### Teach-impeccable (creating design.md from scratch)

When no `design.md` or `.impeccable.md` exists, run the `teach-impeccable` skill. It gathers:

- Brand personality and cultural positioning
- Product users and purpose
- Aesthetic direction and design principles
- Accessibility considerations
- Existing assets (brand guidelines, tokens, decks)

The skill writes the result as `design.md` in the repo root. Workers must not begin design work until this file exists.

### style-pack resolution

When a `style-pack:` field is present in Design Direction, workers that support pack resolution perform the following lookup:

1. Read `knowledge/public/design-styles/registry.yaml`
2. Find the entry matching `<pack-id>`
3. Resolve the pack directory via the registry `path` field
4. Load all files listed under `context_paths.required` in the pack's `pack.yaml` (style guide, design tokens, implementation notes)
5. Optionally load `context_paths.optional` files for richer context
6. Merge with inline Design Direction content — inline rules take precedence over pack defaults on any conflict

Workers that do not support pack resolution ignore the `style-pack:` field and use inline content only.
