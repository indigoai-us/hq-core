---
name: audit
description: Perform a systematic design quality scan across accessibility, performance, theming, and responsive design. Generates a prioritized issue list with actionable recommendations. Does not fix — documents for other skills to address.
user-invokable: true
args:
  - name: area
    description: The feature or area to audit (optional)
    required: false
---

Run systematic quality checks and generate a comprehensive audit report with prioritized issues and actionable recommendations. Don't fix issues — document them.

> Reference: `knowledge/public/design-styles/foundations/` for design principles and anti-patterns.

## Diagnostic Scan

Run checks across multiple dimensions:

### 1. Accessibility (A11y)
- Contrast ratios < 4.5:1 (or < 7:1 for AAA)
- Interactive elements missing ARIA roles, labels, or states
- Missing focus indicators, illogical tab order, keyboard traps
- Improper heading hierarchy, missing landmarks, divs used as buttons
- Missing or poor alt text
- Inputs without labels, poor error messaging, missing required indicators

### 2. Performance
- Animating layout properties (width/height/top/left) instead of transform/opacity
- Images without lazy loading, unoptimized assets
- Unnecessary re-renders, missing memoization
- Layout thrashing (reading/writing layout in loops)

### 3. Theming
- Hard-coded colors not using design tokens
- Missing dark mode variants or poor dark-theme contrast
- Values that don't update on theme change

### 4. Responsive Design
- Fixed widths that break on mobile
- Touch targets < 44×44px
- Content overflow causing horizontal scroll
- No mobile/tablet breakpoint variants

### 5. Anti-Patterns (CRITICAL)
Check against DON'T guidelines in `knowledge/public/design-styles/foundations/ai-slop-test.md`. Look for AI slop tells: generic color palettes, gradient text, glassmorphism, hero metrics, card grids, default fonts (Inter/Roboto/Arial with no personality).

## Generate Audit Report

### Anti-Patterns Verdict
**Start here.** Pass/fail: does this look AI-generated? Reference `knowledge/public/design-styles/foundations/ai-slop-test.md` for the full fingerprint checklist.

### Executive Summary
- Total issues by severity
- Top 3–5 critical issues
- Overall quality score
- Recommended next steps

### Detailed Findings by Severity
For each issue: Location · Severity (Critical/High/Medium/Low) · Category · Description · Impact · Recommendation

#### Critical
#### High
#### Medium
#### Low

### Systemic Patterns
Identify recurring problems (e.g., "Hard-coded colors in 15+ components").

### Positive Findings
Note what's working well.

### Recommendations by Priority
1. **Immediate** — Critical blockers
2. **Short-term** — High-severity issues
3. **Medium-term** — Quality improvements
4. **Long-term** — Nice-to-haves

**NEVER**: Report issues without explaining impact. Skip positive findings. Provide generic recommendations. Forget to prioritize.
