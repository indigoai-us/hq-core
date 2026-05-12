---
id: hq-jsdom-vitest-storage-shim
title: Install Map-backed Storage shims for jsdom 28 + vitest 4 test setup
scope: global
trigger: Setting up vitest test environment with jsdom 28; suite-wide failures referencing `localStorage.clear is not a function` or similar Storage method errors
enforcement: soft
public: true
version: 1
created: 2026-04-25
updated: 2026-04-25
source: session-learning
---

## Rule

ALWAYS install Map-backed Storage shims for `localStorage` and `sessionStorage` in vitest test setup when running on jsdom 28. Use the same `Object.defineProperty(window, 'localStorage', { configurable: true, writable: true, value: createStorageMock() })` pattern already used elsewhere in the suite for `IntersectionObserver` and `clipboard`. The shim factory should expose `getItem`, `setItem`, `removeItem`, `clear`, `key`, and `length` — all backed by an internal `Map`.

Do NOT rely on jsdom's built-in Storage implementation. Do NOT lazy-patch only the methods that fail.

## Rationale

jsdom 28 ships a Storage prototype whose methods are not always directly callable in vitest 4 contexts — depending on how the test environment hoists globals, `window.localStorage.clear()` can throw `TypeError: localStorage.clear is not a function` even though `localStorage` itself is defined. The failure propagates across the entire suite because most test setups call `localStorage.clear()` in `beforeEach` to reset state, so a single broken method takes down hundreds of tests at once.

A Map-backed shim sidesteps the prototype-binding ambiguity entirely: each method is a plain function on a fresh object, and vitest sees a stable, callable API for the lifetime of the test run. The same shape that already works for `IntersectionObserver` and `clipboard` mocks generalizes cleanly to Storage.
