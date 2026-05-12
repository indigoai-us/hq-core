---
id: hq-vitest-mock-invoke-lazy-reject
title: Use lazy mockImplementation for rejection paths when mocking Tauri invoke() in vitest
scope: global
trigger: writing vitest error-path tests that mock invoke() from @tauri-apps/api/core (or any async module)
enforcement: soft
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
---

## Rule

ALWAYS: When mocking `invoke()` from `@tauri-apps/api/core` (or any async function) in vitest error-path tests, use a lazy `mockImplementation` that constructs a fresh `Promise.reject(...)` inside the callback on each call. Do not embed `Promise.reject(new Error(...))` directly in a helper map like `mockCommands({ [cmd]: Promise.reject(...) })` — that creates the rejection eagerly at module-evaluation time, before any `.catch` or `await` handler is attached, producing `UnhandledPromiseRejection` warnings and flaky tests.

```ts
// BAD — rejection created eagerly
mockCommands({
  my_cmd: Promise.reject(new Error("boom")),
});

// GOOD — rejection created per call, with handler already attached
mockCommands({
  my_cmd: () => Promise.reject(new Error("boom")),
});
// or
vi.mocked(invoke).mockImplementation(async (cmd) => {
  if (cmd === "my_cmd") throw new Error("boom");
  // ...
});
```

## Rationale

`Promise.reject(...)` synchronously creates a rejected promise the moment the expression evaluates. When that expression sits inside a helper map that runs at module init, Node's unhandled-rejection detector fires before any test code has a chance to `.catch` it — even though the test eventually awaits and handles the rejection correctly. The warning floods test output and some CI configs fail on unhandled rejections. Wrapping the rejection in a thunk (`() => Promise.reject(...)`) or a `mockImplementation` defers construction until the mock is actually called, at which point the caller's `await`/`.catch` is already in place. Captured 2026-04-21 during hq-installer vitest error-path work.
