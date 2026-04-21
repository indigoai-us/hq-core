---
name: add-animation
description: Add purposeful, performant animations to a component following design-styles motion primitives
user-invokable: true
args:
  - name: component
    description: The component or section to animate (required)
    required: true
---

Analyze the component and add purposeful animations following design-styles motion primitives.

> Reference: knowledge/public/design-styles/foundations/motion-design.md for timing, easing, and stagger patterns.

## Assess Animation Opportunities

Before writing any animation code, audit the component for:

- Missing feedback — buttons/links with no hover or click response
- Jarring transitions — state changes that snap without acknowledgment
- Unguided attention — no visual hierarchy for where the eye should go on load
- Missed entrances — content that appears without context on first render
- Scroll blindness — content below the fold that appears with no reveal

## Animation Strategy

Layer animations by purpose:

1. **Hero moment** — the one entrance animation that defines the component's personality (entrance, not decoration)
2. **Feedback layer** — micro-interactions on every interactive element
3. **Transition layer** — smooth state changes (expanded/collapsed, selected/unselected, loading/loaded)

## Implement by Type

### Entrance Animations (Page Load Choreography)

Stagger element reveals on initial mount. Elements should not all appear at once.

```css
/* Stagger children by index */
.item:nth-child(1) { animation-delay: 0ms; }
.item:nth-child(2) { animation-delay: 100ms; }
.item:nth-child(3) { animation-delay: 200ms; }

/* Or via CSS custom property */
.item { animation-delay: calc(var(--i, 0) * 100ms); }
```

- Use fade + slide-up combinations (translateY: 16-24px → 0, opacity: 0 → 1)
- Keep stagger delays at 100-150ms per element
- Cap total stagger time at 500ms for lists
- Duration: 300-500ms per element with ease-out-quart

**Hero Section Entrances:**
- Headline: first, 500-800ms, ease-out-expo
- Subtext: +150ms delay
- CTA: +300ms delay
- Supporting imagery: +100ms delay, can overlap with CTA

### Micro-interactions

Every interactive element needs a response. These should be immediate (100-150ms).

```css
/* Button hover */
.button {
  transition: transform 150ms var(--ease-out-quart), box-shadow 150ms var(--ease-out-quart);
}
.button:hover {
  transform: scale(1.02);
}
.button:active {
  transform: scale(0.95);
  transition-duration: 80ms;
}

/* Link/icon hover */
.link {
  transition: opacity 120ms ease;
}
.link:hover {
  opacity: 0.75;
}
```

Scale range: hover 1.02–1.05 (subtle), click 0.95 (tactile).

### State Transitions

Animate between states (loading/loaded, expanded/collapsed, selected/unselected):

- Duration: 200-300ms
- Easing: ease-in-out for toggles, ease-out for entering states, ease-in for leaving
- Never snap — always interpolate

### Scroll-triggered Animations

Use IntersectionObserver — never scroll event listeners.

```js
const observer = new IntersectionObserver(
  (entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add('visible');
        observer.unobserve(entry.target); // animate once
      }
    });
  },
  { threshold: 0.15 }
);

document.querySelectorAll('.animate-on-scroll').forEach((el) => observer.observe(el));
```

Trigger at 15% visibility. Animate once — do not re-trigger on scroll-back.

## Technical Standards

### Easing Curves

Define as CSS custom properties in `:root`:

```css
:root {
  --ease-out-quart: cubic-bezier(0.25, 1, 0.5, 1);
  --ease-out-quint: cubic-bezier(0.22, 1, 0.36, 1);
  --ease-out-expo: cubic-bezier(0.16, 1, 0.3, 1);
  --ease-in-quart: cubic-bezier(0.5, 0, 0.75, 0);
  --ease-in-out-quart: cubic-bezier(0.76, 0, 0.24, 1);
}
```

### Timing Reference

| Purpose | Duration | Easing |
|---------|----------|--------|
| Feedback (hover, click) | 100–150ms | ease-out-quart |
| State changes | 200–300ms | ease-in-out-quart |
| Layout / panel shifts | 300–500ms | ease-out-quint |
| Entrance animations | 500–800ms | ease-out-expo |

## Performance Rules

- Animate `transform` and `opacity` only — these are compositor-only properties
- GPU acceleration: `will-change: transform` on elements with complex animations (use sparingly)
- Never use `will-change` on more than a handful of elements at once
- Use `IntersectionObserver` for scroll triggers — never `scroll` event listeners
- Stagger via CSS custom properties or JS index assignment — avoid JS timers for animation sequencing
- Test on low-end device profiles (Chrome DevTools CPU throttle 6x) before shipping

## Accessibility (MANDATORY)

Every animation must respect `prefers-reduced-motion`. No exceptions.

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

For JS-driven animations, check the media query before running:

```js
const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
if (!prefersReducedMotion) {
  // run animation
}
```

Approximately 35% of users over 40 have motion sensitivity — this is not optional.

## NEVER

- Bounce or elastic easing — feels dated, draws attention to the animation itself rather than the content
- Animate layout properties (width, height, top, left, margin, padding) — triggers layout recalc on every frame
- Ignore `prefers-reduced-motion` — accessibility violation
- Feedback durations over 500ms — feels broken, not intentional
- Animate every element at once — stagger gives hierarchy
- Use `setTimeout`/`setInterval` for animation sequencing — use CSS delays or Web Animations API
