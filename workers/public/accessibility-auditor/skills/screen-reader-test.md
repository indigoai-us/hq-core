# Screen Reader Compatibility Test

Verify semantic HTML and ARIA for screen reader users.

## Inputs

- `url`: URL to test
- `target_repo`: Optional — for source code analysis

## Process

1. Check heading hierarchy (h1-h6, no skipped levels, one h1 per page)
2. Verify landmarks (header/nav/main/footer/aside, labeled if multiple)
3. Audit images (meaningful alt text, decorative images have alt="")
4. Check link text (descriptive, not "click here" or "read more")
5. Verify form labels (programmatic association, error messages linked)
6. Test dynamic content (live regions, SPA route announcements)
7. Validate ARIA usage (valid roles, required properties, no ARIA better than bad ARIA)

## Output

- Screen reader audit checklist with per-item PASS/FAIL
- Heading outline (visual tree of heading hierarchy)
- Landmark map
- List of unlabeled/mislabeled interactive elements
