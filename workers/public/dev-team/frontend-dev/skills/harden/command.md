---
name: harden
description: Edge case hardening for i18n, text overflow, empty states, and error handling. Makes interfaces robust and production-ready.
user-invokable: true
args:
  - name: target
    description: The feature or area to harden (optional)
    required: false
---

Strengthen interfaces against edge cases, errors, internationalization issues, and real-world usage scenarios that break idealized designs.

> Reference: `knowledge/public/design-styles/foundations/` for design resilience principles (responsive-design.md, ux-writing.md, interaction-design.md).

## Assess Hardening Needs
1. **Extreme inputs**: Very long text, very short text, special characters (emoji, RTL, accents), large numbers, many items (1000+), no data
2. **Error scenarios**: Network failures (offline, slow, timeout), API errors (400/401/403/404/500), validation errors, concurrent operations
3. **Internationalization**: Long translations (German ~30% longer), RTL languages, CJK characters, date/time/number formats

**CRITICAL**: Designs that only work with perfect data aren't production-ready.

## Hardening Dimensions

### Text Overflow & Wrapping
```css
/* Single line with ellipsis */
.truncate { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

/* Multi-line clamp */
.line-clamp { display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }

/* Flex/Grid: prevent overflow */
.flex-item { min-width: 0; overflow: hidden; }
.grid-item { min-width: 0; min-height: 0; }
```

### Internationalization (i18n)
- Budget 30–40% extra space for translations; use flex/grid that adapts
- Logical CSS properties for RTL: `margin-inline-start`, `padding-inline`, `border-inline-end`
- UTF-8 everywhere; test with CJK and emoji
- Use `Intl.DateTimeFormat` and `Intl.NumberFormat` — never hand-format dates or numbers
- Use i18n library for pluralization (not naive string interpolation)

### Error Handling
- **Network errors**: Clear message + retry button + explain what happened
- **Form validation**: Inline errors near fields, specific messages, preserve user input on error
- **API status codes**: 400→validation feedback · 401→redirect to login · 403→permission message · 404→not found · 429→rate limit with wait time · 500→generic message + support contact
- **Graceful degradation**: Core functionality without JS; progressive enhancement

### Edge Cases & Boundary Conditions
- **Empty states**: Always provide a clear next action — never just "No data"
- **Loading states**: Skeleton screens preferred; "Loading your [thing]..." for named content; time estimates for long operations
- **Large datasets**: Pagination or virtual scrolling; never load 10,000 items at once
- **Concurrent operations**: Prevent double-submission (disable button while loading); handle race conditions
- **Permission states**: Explain why access is denied, not just that it is

### Input Validation & Sanitization
- Client-side: required, format, length, pattern validation with clear feedback
- **Always validate server-side** — never trust client-only validation
- Set clear constraints with `maxlength`, `pattern`, `aria-describedby` hint text

### Accessibility Resilience
- Full keyboard navigation: logical tab order, focus management in modals, skip links
- ARIA labels, live regions for dynamic changes, semantic HTML
- `prefers-reduced-motion` respected throughout
- Test in high contrast mode; never rely solely on color to convey state

### Performance Resilience
- Skeleton screens for slow connections (avoid spinners for content-heavy loads)
- Clean up event listeners, subscriptions, and timers on unmount
- Debounce search/input (300ms); throttle scroll handlers (100ms)

## Verify Hardening
Test with: 100+ character names · emoji in text fields · Arabic/Hebrew RTL text · CJK characters · disabled network · 1000+ list items · rapid concurrent clicks (10× submit) · forced API errors · all empty states.

**NEVER**: Assume perfect input. Ignore i18n. Use generic error messages ("Error occurred"). Leave fixed widths on text containers. Assume English-length text. Block the entire interface when one component errors.
