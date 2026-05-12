# Keyboard Navigation Test

Focused keyboard-only testing of a page or component.

## Inputs

- `url`: URL to test
- `component`: Optional — specific component to focus on (modal, dropdown, form, carousel, tabs)

## Process

1. Navigate entire page via Tab/Shift+Tab — map all focus stops
2. Test interactive elements: Enter, Space, Escape, Arrow keys
3. Check focus indicators (visibility, contrast)
4. Test focus traps (modals, drawers) — enter, navigate, escape
5. Verify skip links
6. Test form submission via keyboard only

## Output

- Keyboard navigation map (ordered list of tab stops with PASS/FAIL)
- Focus trap test results
- Missing/broken focus indicators
- Inaccessible interactive elements
