---
name: polish
description: Final quality pass before shipping. Fixes alignment, spacing, consistency, and detail issues that separate good from great.
user-invokable: true
args:
  - name: target
    description: The feature or area to polish (optional)
    required: false
---

Perform a meticulous final pass to catch all the small details that separate good work from great work.

> Reference: `knowledge/public/design-styles/foundations/` for design principles and anti-patterns.

## Pre-Polish Assessment
1. **Review completeness**: Is the work functionally complete? What quality bar applies (MVP vs. flagship)?
2. **Identify polish areas**: Visual inconsistencies, spacing issues, interaction state gaps, copy issues, edge cases.

**CRITICAL**: Polish is the last step, not the first. Don't polish work that's not functionally complete.

## Polish Systematically

### Visual Alignment & Spacing
- Pixel-perfect alignment to grid
- All gaps use spacing scale (no arbitrary values)
- Optical alignment for icons (may need small offset for visual centering)
- Consistent at all breakpoints

### Typography Refinement
- Hierarchy consistent throughout
- Body text line length 45–75 characters
- No widows or orphans
- Font loading without FOUT/FOIT

Reference: `knowledge/public/design-styles/foundations/typography.md`

### Color & Contrast
- WCAG contrast ratios on all text
- No hard-coded colors — use design tokens
- Consistent across all theme variants
- Tinted neutrals (avoid pure gray/black — add 0.01 chroma minimum)
- Never use gray text on colored backgrounds (use a shade of that color instead)

Reference: `knowledge/public/design-styles/foundations/color-and-contrast.md`

### Interaction States
Every interactive element needs: Default · Hover · Focus · Active · Disabled · Loading · Error · Success

### Micro-interactions & Transitions
- Smooth transitions (150–300ms)
- Ease-out-quart/quint/expo for deceleration — never bounce or elastic
- 60fps only — animate transform and opacity only
- Respects `prefers-reduced-motion`

Reference: `knowledge/public/design-styles/foundations/motion-design.md`

### Content & Copy
- Consistent terminology and capitalization
- No typos
- Consistent punctuation

### Icons & Images
- Consistent icon family and sizing
- Optical alignment with adjacent text
- All images have alt text, no layout shift on load

### Forms & Inputs
- All inputs labeled; required indicators clear; errors helpful and specific
- Logical tab order; consistent validation timing

### Edge Cases & Error States
- Loading, empty, error, and success states all handled
- Long content handled gracefully (truncation or reflow)
- Offline behavior is appropriate

### Responsiveness
- All breakpoints tested (mobile, tablet, desktop)
- Touch targets 44×44px minimum
- No horizontal scroll

### Code Quality
- No console logs, commented-out code, or unused imports
- No TypeScript `any`
- Semantic HTML with proper ARIA

## Polish Checklist
- [ ] Visual alignment correct at all breakpoints
- [ ] Spacing uses design tokens consistently
- [ ] Typography hierarchy consistent
- [ ] All interactive states implemented
- [ ] Transitions smooth (60fps, transform/opacity only)
- [ ] Copy is consistent and clean
- [ ] Icons consistent and properly sized
- [ ] All forms labeled and validated
- [ ] Error states are helpful
- [ ] Loading states are clear
- [ ] Empty states are welcoming
- [ ] Touch targets 44×44px minimum
- [ ] Contrast ratios meet WCAG AA
- [ ] Keyboard navigation works
- [ ] Focus indicators visible
- [ ] No console errors or warnings
- [ ] No layout shift on load
- [ ] Respects reduced-motion preference
- [ ] Code is clean (no debug artifacts)

**NEVER**: Polish before functionally complete. Introduce bugs while polishing. Perfect one thing while leaving others rough.
