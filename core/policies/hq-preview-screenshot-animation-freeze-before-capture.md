---
id: hq-preview-screenshot-animation-freeze-before-capture
title: Freeze or slow fast CSS animations before preview_screenshot verification
scope: global
trigger: verifying sub-second CSS animations / transitions via preview_screenshot
enforcement: soft
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
---

## Rule

Do NOT try to verify sub-second CSS animations (fades, pulses, shimmer sweeps, toast dismissals, etc.) by racing `preview_screenshot` against the animation window. The `preview_eval` → `preview_screenshot` round-trip is typically 500 ms–1 s, which almost always exceeds the animation duration, so the capture misses the peak frame.

Instead, pin the element into its peak state before capturing. Pick one:

1. **Stretch the animation.** Inject a stylesheet that overrides the duration:
   ```js
   const s = document.createElement('style');
   s.textContent = '.target { animation-duration: 20s !important; transition-duration: 20s !important; }';
   document.head.appendChild(s);
   ```
2. **Delay React's unmount timer.** Patch `window.setTimeout` so any `setTimeout(() => setVisible(false), N)` in the component resolves far in the future:
   ```js
   const orig = window.setTimeout;
   window.setTimeout = (fn, ms, ...rest) => orig(fn, ms < 10000 ? 60000 : ms, ...rest);
   ```
3. **Freeze after mount.** Once the element is on screen, pin its end state directly:
   ```js
   const el = document.querySelector('.target');
   el.style.animation = 'none';
   el.style.transition = 'none';
   el.style.opacity = '1';           // or whatever peak value you need
   ```

Then call `preview_screenshot`. Restore the page afterwards if further interaction is needed.

## Rationale

`preview_screenshot` captures the current paint of the headless browser, but each MCP tool call serializes through a stdio bridge with its own marshalling cost. A 300 ms fade-in often finishes before the screenshot request even reaches the renderer, leaving the verification loop chasing ghosts — the run either captures the resting state or misses the element entirely if it has already unmounted.

Freezing the animation side-steps the race. Duration overrides keep the element mid-animation indefinitely; setTimeout patching keeps React-driven unmounts from firing; direct style pinning skips the animation machinery altogether. All three preserve the visual fidelity you want to screenshot without introducing flaky timing assumptions.
