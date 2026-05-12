---
id: hq-preview-eval-no-navigate-use-click
title: Never navigate via preview_eval — use preview_click with viewport sized for breakpoints
scope: global
trigger: UI verification with preview_* tools (preview_eval, preview_click, preview_snapshot)
enforcement: soft
public: true
version: 2
created: 2026-04-20
updated: 2026-04-24
source: session-learning
---

## Rule

When using the `preview_*` MCP tooling for UI verification:

1. **Never navigate via `preview_eval`** running `window.location.assign()`, `.replace()`, or `.href = ...`. The eval tears down the JS world mid-navigation and frequently reports the *old* pathname back, making verification unreliable. Prefer `preview_click` on a known selector to trigger navigation.
2. **Resize to ≥ 768px before clicking nav elements.** Tailwind `md:` breakpoints gate navigation visibility via `hidden md:block`. Below the breakpoint, target elements have `offsetParent === null` and clicks no-op silently. Set viewport to `1280×800` (or at least `768+`) before interacting with desktop nav.
3. **`preview_snapshot` serializes DOMRect as `{}`.** The `getBoundingClientRect()` props (`top`, `left`, `width`, `height`, etc.) are prototype getters, which `JSON.stringify` drops. If you need rect numbers, read them explicitly: `const r = el.getBoundingClientRect(); return { top: r.top, left: r.left, width: r.width, height: r.height };` — do not rely on the snapshot payload.
4. **Never use `location.href = ...` or `location.replace(...)` inside `preview_eval` to recover a browser stuck on `chrome-error://chromewebdata/`** (typical after a dev-server restart). The eval waits on the navigation, hits its 30s timeout inside the error page's dead JS world, and kills the preview target so subsequent `preview_*` calls also fail. Instead, restart via `preview_start` (or `preview_stop` + `preview_start`) — the start command re-navigates the headless browser to the configured URL through the controller, not through JS inside the wedged page.

## Rationale

The preview environment runs the page inside a headless browser and bridges commands over a stdio channel. `window.location` mutations yank the document out from under the running eval context, so any return value sent after the navigation kicks in is delivered from a half-dead context. Clicks are driven synchronously from a fresh eval each call, so they don't suffer the same tear-down.

Viewport size is part of the Tailwind render contract: `hidden md:flex` literally removes the element from the layout tree below 768px, and `offsetParent` reads `null` — which MCP preview's default `click` code uses as a click-eligibility signal. The default viewport in some preview backends is < 768px, which is why "the nav exists but clicks do nothing" is a routine failure mode.

`DOMRect.toJSON()` does exist in browsers, but the MCP snapshot bridge uses plain `JSON.stringify` on serialized DOM trees, which walks own-enumerable properties only. Getters on the prototype are invisible. The fix is to materialize the numeric props into a plain object before returning.
