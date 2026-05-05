---
id: hq-svg-recolor-via-brightness-invert-filter
title: Recolor single-paint SVG logos to white via filter brightness(0) invert(1)
scope: global
trigger: embedding a cross-repo single-paint SVG logo and needing a different color without forking the asset
enforcement: soft
public: true
version: 1
created: 2026-04-24
updated: 2026-04-24
source: session-learning
---

## Rule

**ALWAYS** recolor single-paint SVG logos via CSS `filter: brightness(0) invert(1)` when embedding cross-repo and you need pure white output, regardless of the SVG's original fill color. For other target colors, combine with `sepia()` + `hue-rotate()` + `saturate()` as needed, but the `brightness(0) invert(1)` idiom covers the common "make this logo white" case cleanly.

```css
.partner-logo {
  filter: brightness(0) invert(1);
}
```

Why it works:
- `brightness(0)` flattens every non-transparent pixel to pure black (`#000000`) while preserving the alpha channel and any internal gradients' **shape**.
- `invert(1)` then flips each channel (`255 - c`), turning the resulting black into pure white.

Net effect: any single-paint SVG — regardless of whether the source uses `#888`, `#E40046`, `currentColor`, or a named color — renders as pure white while retaining crisp edges and anti-aliasing.

**Do NOT use this for multi-paint SVGs** (icons with intentional multiple fills, brand marks with secondary colors). The filter flattens everything to white; distinct fills are lost.

**Preferred over:**
- Forking the SVG asset with a recolored fill (adds maintenance burden, drifts from upstream)
- Runtime `fill` overrides via CSS (only works when the SVG inlines its paint as `fill="currentColor"` or unset; fails when the source has a hardcoded hex)
- Server-side SVG transformation (infrastructure overkill for a display-only recolor)

## Rationale

The source SVG lived in a different repo with a hardcoded dark-gray fill and no `currentColor` support. Three options surfaced:

1. Fork the SVG, change the fill attribute, track two copies.
2. Post-process the SVG at build time.
3. Apply `filter: brightness(0) invert(1)` at the embed site.

Option 3 shipped in one CSS line with no asset fork and no build-time dependency. The filter composes with dark-mode overrides (`@media (prefers-color-scheme: light) { .partner-logo { filter: none; } }` when the logo should revert to its dark original on light backgrounds).

The `brightness(0) invert(1)` pattern is a standard trick in the CSS-filter community and is well-supported across all evergreen browsers. It's the correct default for "make this embedded logo white" — no forking, no runtime preprocessing, no build-time mutation.
