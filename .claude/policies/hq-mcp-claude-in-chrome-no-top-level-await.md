---
id: hq-mcp-claude-in-chrome-no-top-level-await
title: MCP Claude-in-Chrome javascript_tool runs in a non-async scope — never use top-level await
scope: global
trigger: passing JS code to the Claude-in-Chrome MCP `javascript_tool` (or any MCP that wraps user code in a non-async eval scope)
enforcement: soft
public: true
version: 1
created: 2026-04-19
updated: 2026-04-19
source: session-learning
---

## Rule

The Claude-in-Chrome MCP `javascript_tool` evaluates the supplied code inside a non-async function scope. Top-level `await` throws:

```
SyntaxError: await is only valid in async functions and the top level bodies of modules
```

NEVER write code like:

```js
await new Promise(r => setTimeout(r, 2000));
const result = await fetch('/api/...');
console.log(result);
```

Always use Promise chains for any delayed or async work:

```js
new Promise(r => setTimeout(r, 2000))
  .then(() => fetch('/api/...'))
  .then(res => res.json())
  .then(data => console.log(data))
  .catch(err => console.error(err));
```

If you need to sequence multiple async steps, chain `.then()` calls or wrap the whole body in an IIFE:

```js
(async () => {
  await new Promise(r => setTimeout(r, 2000));
  const res = await fetch('/api/...');
  console.log(await res.json());
})();
```

The IIFE pattern restores the async scope locally and is acceptable. Top-level `await` outside an IIFE / async function will always throw.

## Rationale

Root cause: the MCP wrapper does not wrap user code in `(async () => { ... })()`, so top-level `await` is a syntax error in the eval context. Capturing as a hard rule because the failure mode is generic across any future use of the tool — and the fix (Promise chain or IIFE) is mechanical.
