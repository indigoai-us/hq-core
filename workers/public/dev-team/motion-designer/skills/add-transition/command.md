---
name: add-transition
description: Add smooth, performant transitions to page routes, UI elements, or interactive components
user-invokable: true
args:
  - name: transition
    description: The transition to add (e.g., page route change, accordion open, modal entry)
    required: true
---

Add smooth, performant transitions following the motion-design primitives.

> Reference: knowledge/public/design-styles/foundations/motion-design.md — the 100/300/500 rule, easing curves, and reduced motion patterns.

## Select Duration

Match duration to the purpose of the transition. Every transition should have an intentional duration — never default to a single value for everything.

| Purpose | Duration | Example |
|---------|----------|---------|
| Immediate feedback | 100–150ms | hover state, button press |
| State change | 200–300ms | tab switch, toggle, tooltip |
| Layout / panel shift | 300–500ms | sidebar open, filter expand |
| Entrance / hero | 500–800ms | page load, modal entry, hero reveal |

The 80ms threshold: changes under 80ms feel instantaneous to users and create a sense of speed (optimistic UI). Changes over 500ms for feedback feel broken.

## Select Easing

| Direction | Curve | CSS Variable |
|-----------|-------|--------------|
| Entering (ease out) | Decelerates — fast start, gentle finish | `var(--ease-out-quart)` |
| Leaving (ease in) | Accelerates — gentle start, fast exit | `var(--ease-in-quart)` |
| Toggle (ease in-out) | Symmetric — gentle both ends | `var(--ease-in-out-quart)` |

```css
:root {
  --ease-out-quart: cubic-bezier(0.25, 1, 0.5, 1);
  --ease-out-quint: cubic-bezier(0.22, 1, 0.36, 1);
  --ease-out-expo: cubic-bezier(0.16, 1, 0.3, 1);
  --ease-in-quart: cubic-bezier(0.5, 0, 0.75, 0);
  --ease-in-out-quart: cubic-bezier(0.76, 0, 0.24, 1);
}
```

Never use `ease` (browser default) — it is a generic approximation, not purposeful.

## Transition Patterns

### Page / Route Transitions

Outgoing page exits quickly (ease-in), incoming page enters deliberately (ease-out).

```css
/* Outgoing */
.page-exit {
  animation: pageExit 200ms var(--ease-in-quart) forwards;
}

/* Incoming */
.page-enter {
  animation: pageEnter 400ms var(--ease-out-expo) forwards;
}

@keyframes pageExit {
  to { opacity: 0; transform: translateY(-8px); }
}

@keyframes pageEnter {
  from { opacity: 0; transform: translateY(16px); }
}
```

Keep exit short (150-200ms) and entry slightly longer (300-400ms).

### Reveal / Collapse (Accordion, Expandable)

Use the CSS grid trick for height — avoids animating `height` directly (which causes layout recalc).

```css
.collapsible {
  display: grid;
  grid-template-rows: 0fr;
  transition: grid-template-rows 300ms var(--ease-in-out-quart);
}

.collapsible.open {
  grid-template-rows: 1fr;
}

.collapsible-inner {
  overflow: hidden;
}
```

This animates the row track, not the element height — compositor-friendly.

### Modal / Drawer

```css
/* Modal backdrop */
.modal-backdrop {
  transition: opacity 200ms var(--ease-out-quart);
}

/* Modal panel */
.modal-panel {
  transition:
    opacity 300ms var(--ease-out-expo),
    transform 300ms var(--ease-out-expo);
}

.modal-panel[data-state="closed"] {
  opacity: 0;
  transform: scale(0.96) translateY(8px);
}

/* Drawer from bottom */
.drawer-panel {
  transition: transform 400ms var(--ease-out-quint);
  transform: translateY(100%);
}

.drawer-panel[data-state="open"] {
  transform: translateY(0);
}
```

Backdrop enters with the panel, exits before the panel (fade out at 150ms, panel at 200ms).

### Tab / Accordion

```css
/* Tab indicator slide */
.tab-indicator {
  transition: left 200ms var(--ease-in-out-quart), width 200ms var(--ease-in-out-quart);
}

/* Tab content crossfade */
.tab-panel {
  transition: opacity 150ms var(--ease-out-quart);
}

.tab-panel[aria-hidden="true"] {
  opacity: 0;
  pointer-events: none;
}
```

## Stagger (for list reveals)

When multiple elements enter together, stagger their arrival to create hierarchy.

```css
/* CSS custom property stagger */
.list-item {
  animation: fadeSlideUp 400ms var(--ease-out-quint) both;
  animation-delay: calc(var(--i, 0) * 50ms);
}

@keyframes fadeSlideUp {
  from {
    opacity: 0;
    transform: translateY(12px);
  }
}
```

Assign `--i` via JS or `:nth-child` selectors. Cap total stagger time at 500ms — if a list has 20 items, use 25ms intervals, not 100ms.

## Accessibility

Every transition must respect `prefers-reduced-motion`.

```css
@media (prefers-reduced-motion: reduce) {
  *,
  *::before,
  *::after {
    animation-duration: 0.01ms !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0.01ms !important;
    scroll-behavior: auto !important;
  }
}
```

For JS-driven transitions:

```js
const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
const duration = prefersReducedMotion ? 0 : 300;
```

## Back Pressure

Verify before shipping:

- [ ] Transition runs at 60fps — check in Chrome DevTools Performance panel (no layout recalc, no paint during animation)
- [ ] No layout thrashing — only `transform` and `opacity` are changing
- [ ] `prefers-reduced-motion` tested — toggle in OS settings or DevTools, verify content still usable
- [ ] Exit and enter asymmetry is correct — exits faster than enters
- [ ] Duration matches purpose from the timing table above

## NEVER

- Use `ease` (browser default) — always specify an intentional easing curve
- Animate `width`, `height`, `top`, `left`, `margin`, or `padding` directly — use the grid trick or `transform` instead
- Feedback transitions over 500ms — feels broken
- Identical duration for all transitions — ignores purpose hierarchy
- Skip `prefers-reduced-motion` — accessibility violation
