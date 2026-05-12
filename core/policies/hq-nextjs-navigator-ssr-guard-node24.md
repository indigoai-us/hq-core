---
id: hq-nextjs-navigator-ssr-guard-node24
title: Never use `typeof navigator` as an SSR guard — Node 24 polyfills it
scope: global
trigger: next.js, react 19, ssr guard, navigator, typeof navigator, hydration bail, onSubmit lost, form GET fallback, node 24 runtime
enforcement: soft
public: true
version: 1
created: 2026-04-22
updated: 2026-04-22
source: session-learning
---

## Rule

NEVER use `typeof navigator !== "undefined"` as an SSR / client-only guard in Next.js / React client components. Starting in Node 24, `globalThis.navigator` is polyfilled as `{ userAgent: "Node.js/XX" }`, which means the guard is now **truthy on the server**. The server branch that reads `navigator.userAgent` (or similar) then executes during SSR, the polyfilled `"Node.js/XX"` UA leaks into the server-rendered HTML, and the hydrating client produces a different tree.

Under React 19 this manifests as a **silent hydration bail** on the affected subtree:
- No console error by default (hydration warnings were downgraded to recoverable in React 19)
- Event handlers attached in that subtree — including `onSubmit`, `onClick`, `onChange` — are never wired up
- Forms fall back to **native HTML submission**, which on a `<form>` without `method="post"` sends a **GET** with all fields as query-string params — not the POST the app expects

Replace with one of:

```tsx
// Option 1 — gate on `window` (never polyfilled in Node)
if (typeof window !== "undefined") {
  const ua = window.navigator.userAgent;
  // ...
}

// Option 2 — defer the browser read to useEffect with a server-safe default
const [ua, setUa] = useState<string | null>(null);
useEffect(() => {
  setUa(window.navigator.userAgent);
}, []);
```

The same failure mode applies to any render-time read of a browser global that Node now polyfills or may polyfill in the future. Use `typeof window` as the canonical client-check.

## Rationale

Node 24 shipped the `navigator` polyfill, Vercel's Lambda runtime silently picked it up on a later deploy, and a legacy `typeof navigator !== "undefined"` guard that had been safe for years inverted meaning. Onboarding forms rendered, but clicks did nothing visible because hydration silently bailed and the browser's native GET-submit was the only path left.
