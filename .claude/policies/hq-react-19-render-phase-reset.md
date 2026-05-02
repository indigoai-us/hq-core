---
id: hq-react-19-render-phase-reset
title: React 19 — reset derived state at render time, not via synchronous setState at the top of useEffect
scope: global
trigger: react 19, useEffect, setState, react-hooks/set-state-in-effect, derived state reset, fetch on prop change
enforcement: soft
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
---

## Rule

When a component needs to reset derived state (clear preview, reset form, abort a previous fetch) because an identifying prop changed, use a **render-phase reset** pattern. Do NOT call `setState` synchronously at the top of a `useEffect` body to do the reset.

### Preferred pattern (render-phase reset)

Track the id of the previously-loaded entity in state, compare against the current active id during render, and call `setState` during render if they differ. React 19 handles render-phase setState correctly — it re-runs the component synchronously before committing, without an extra effect flush.

```tsx
const activeId = open && row ? row.id : null;

if (activeId !== loadedId) {
  setLoadedId(activeId);
  setPreview(null);
  setError(null);
  setLoading(activeId !== null);
}

useEffect(() => {
  if (activeId === null) return;
  const ac = new AbortController();
  fetchPreview(activeId, { signal: ac.signal })
    .then(setPreview)
    .catch((e) => { if (e.name !== "AbortError") setError(e); })
    .finally(() => setLoading(false));
  return () => ac.abort();
}, [activeId]);
```

The effect body is now focused on the side effect (fetch + abort). State resets happen at render, tied to the id transition.

### Anti-pattern (effect-phase reset)

```tsx
// ❌ Trips react-hooks/set-state-in-effect and causes cascading renders
useEffect(() => {
  setPreview(null);      // sync setState at top of effect
  setError(null);
  setLoading(true);
  if (!activeId) return;
  fetchPreview(activeId).then(setPreview).catch(setError);
}, [activeId]);
```

Why this is wrong:
- React 19's `react-hooks/set-state-in-effect` lint rule fires on every `setState` call inside an effect that is not wrapped in a condition or an event handler — this pattern lights up three times in one effect.
- Each `setState` inside the effect schedules an additional render pass, causing a cascade of renders between the prop change and the first fetch resolution.
- The effect body conflates two concerns (reset + fetch) that belong in different phases.

## Rationale

The initial implementation fetched the preview JSON in a `useEffect` keyed on the selected row's id and reset local preview/error/loading state at the top of the same effect. React 19 lint flagged the three `setState` calls with `react-hooks/set-state-in-effect` (error-level by default in Next 16 / React 19 configs).

The fix is not to silence the lint rule — the rule is pointing at a real render-phase smell. Splitting the concerns (render-phase tracks the active id and resets derived state; effect-phase fetches with an abort controller) produces a component that (a) passes lint, (b) renders fewer times per interaction, and (c) makes the data flow legible to a reader scanning the function body. The pattern generalizes to any component that does "fetch on prop change with a clean slate" — dialogs, drawers, side panels, master-detail views, etc.
