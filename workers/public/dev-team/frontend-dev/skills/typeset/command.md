---
name: typeset
description: Improve typography by fixing font choices, hierarchy, sizing, weight consistency, and readability. Makes text feel intentional and polished.
user-invokable: true
args:
  - name: target
    description: The feature or component to improve typography for (optional)
    required: false
---

Assess and improve typography that feels generic, inconsistent, or poorly structured — turning default-looking text into intentional, well-crafted type.

> Reference: `knowledge/public/design-styles/foundations/typography.md` for type scales, font pairing, and loading strategies.

## Assess Current Typography
1. **Font choices**: Defaulting to Inter/Roboto/Arial with no personality? Too many families (>2–3)?
2. **Hierarchy**: Can you distinguish headings from body from captions at a glance? Are sizes too close together?
3. **Sizing & scale**: Is there a consistent type scale? Body text ≥ 16px? Correct sizing strategy (fixed `rem` for app UI; fluid `clamp()` for marketing headings)?
4. **Readability**: Line lengths 45–75 chars? Appropriate line-height? Sufficient contrast?
5. **Consistency**: Same-role elements styled identically throughout?

**CRITICAL**: The goal isn't fancier text — it's clearer, more readable, more intentional. Good typography is invisible.

## Plan Improvements
- **Font selection**: Do fonts need replacing?
- **Type scale**: Establish modular scale (e.g., 1.25 ratio) with clear hierarchy
- **Weight strategy**: Which weights serve which roles?
- **Spacing**: Line-heights, letter-spacing, margins between typographic elements

## Improve Systematically

### Font Selection
If fonts need replacing:
- Choose fonts that reflect brand personality
- Pair with genuine contrast (serif + sans, geometric + humanist)
- Ensure web font loading avoids layout shift (`font-display: swap`, metric-matched fallbacks)

### Establish Hierarchy
- 5 sizes cover most needs: caption · secondary · body · subheading · heading
- Consistent ratio between levels (1.25, 1.333, or 1.5)
- Combine dimensions: size + weight + color + space — don't rely on size alone
- **App UIs**: Fixed `rem`-based scale (fluid sizing undermines spatial predictability in dense layouts)
- **Marketing/content pages**: Fluid sizing via `clamp(min, preferred, max)` for headings; fixed body text

### Fix Readability
- `max-width: 65ch` on text containers
- Line-height: tighter for headings (1.1–1.2), looser for body (1.5–1.7)
- Slightly higher line-height for light-on-dark text
- Body text minimum 16px / 1rem

### Refine Details
- `tabular-nums` for data tables and aligned numbers
- Letter-spacing: slightly open for small caps/uppercase; tight for large display text
- Use semantic token names (`--text-body`, `--text-heading`) not value names (`--font-16`)
- `font-kerning: normal`; consider OpenType features where appropriate

### Weight Consistency
- Define clear roles per weight; stick to them throughout
- Max 3–4 weights (Regular, Medium, Semibold, Bold)
- Load only the weights you actually use

**NEVER**: >2–3 font families. Arbitrary sizes outside the scale. Body text <16px. Decorative fonts for body copy. `user-scalable=no`. `px` for font sizes. Default to Inter/Roboto when brand personality matters. Pair similar-but-not-identical fonts (creates visual confusion without genuine contrast).

## Verify
- Hierarchy: heading vs. body vs. caption identifiable instantly?
- Readability: body text comfortable to read in long passages?
- Consistency: same-role elements identically styled?
- Personality: typography reflects brand character?
- Performance: web fonts load without layout shift?
- Accessibility: WCAG contrast met? Zoomable to 200% without breaking layout?
