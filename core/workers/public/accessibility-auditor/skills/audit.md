# Full Accessibility Audit

Complete WCAG 2.2 AA audit — automated baseline + manual keyboard/screen-reader/visual testing.

## Inputs

- `url`: URL to audit
- `pages`: Comma-separated paths (default: homepage + 2-3 key pages)
- `target_repo`: Optional — for source code analysis of ARIA patterns

## Process

1. Run axe-core automated scan (baseline)
2. Keyboard navigation audit (all interactive elements)
3. Screen reader compatibility check (semantic HTML, ARIA, landmarks)
4. Visual checks (zoom 200%/400%, reduced motion, high contrast, touch targets)
5. Framework-specific gotcha scan (if source available)
6. Generate structured audit report

## Output

- Full audit report to `workspace/reports/accessibility/{date}-{target}-a11y-report.md`
- Issue count by severity (critical / serious / minor)
- Compliance summary table (Perceivable / Operable / Understandable / Robust)
- Fix instructions per issue with WCAG criterion reference
