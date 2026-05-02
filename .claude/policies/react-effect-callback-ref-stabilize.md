---
id: hq-react-effect-callback-ref-stabilize
title: Stabilize callback props in animation/timer effects with a ref
scope: global
trigger: Writing a React component whose useEffect schedules animations, timers, or a phase machine and depends on a callback prop
enforcement: soft
public: true
version: 1
created: 2026-04-17
updated: 2026-04-17
source: session-learning
---

## Rule

ALWAYS: When a `useEffect` runs an animation/timer sequence and depends on a callback prop, stabilize the callback via a ref before using it inside the effect:

```tsx
const cbRef = useRef(cb);
useEffect(() => { cbRef.current = cb; }, [cb]);

useEffect(() => {
  const timers: ReturnType<typeof setTimeout>[] = [];
  // ...schedule work...
  timers.push(setTimeout(() => cbRef.current(), readyMs));
  return () => timers.forEach(clearTimeout);
}, [/* NO callback here */]);
```

Drop the callback from the effect's dependency array — the ref always points at the latest `cb`. Callers can safely pass fresh arrow functions (`onComplete={() => setDone(true)}`) without restarting the timeline.

## Rationale

Inline arrow-function props change identity every render. If the animation/timer effect has the callback in its dep array, every parent state change reinstalls the effect — which clears the timers and replays the full sequence from the top. The user-visible symptom is a loader that restarts every ~1s (or loops indefinitely) while the parent is actively re-rendering.

This surfaced on `BootOverlay` in hq-onboarding's provision step: `onComplete={() => setBootDone(true)}` caused the 8-second phase machine to restart every render, manifesting as "the loader played several times and kept restarting." The fix moved `onComplete` into a ref and removed it from the dep array; the effect identity is now stable regardless of caller behavior.

Alternatives considered:
- Forcing callers to wrap in `useCallback` → pushes memoization burden onto every consumer and regresses silently if any caller forgets
- Omitting deps with eslint-disable → loses the value the dep array provides for other deps (intentional restarts on prop changes that *should* restart)

The ref pattern is the least-surprising option: it preserves eslint-plugin-react-hooks correctness for all other deps while isolating one-shot callbacks from the restart signal.
