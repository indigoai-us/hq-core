---
id: hq-preview-eval-react-input-native-setter
title: Use the native value setter when driving React-controlled inputs via preview_eval
scope: global
trigger: preview_eval or preview_fill setting the value of a React-controlled <input> / <textarea>
enforcement: soft
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
---

## Rule

When setting the value of a React-controlled `<input>` or `<textarea>` through `preview_eval`, use the native prototype setter and dispatch a real input event:

```js
const el = document.querySelector(selector);
const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
setter.call(el, newValue);
el.dispatchEvent(new Event('input', { bubbles: true }));
```

For `<textarea>`, swap `HTMLInputElement.prototype` for `HTMLTextAreaElement.prototype`.

Do NOT rely on plain `el.value = newValue` — and do not assume `preview_fill` is equivalent in every case. Neither reliably triggers React's synthetic `onChange`, so downstream state (e.g. an Add button that stays `disabled={!draft.trim()}`) never updates and the verification run reads a stale UI.

## Rationale

React overrides the `value` property on input/textarea DOM nodes with its own descriptor so it can intercept changes and run them through the synthetic event system. Assigning `el.value = x` writes to React's own descriptor and does not emit a native `input` event — React's change tracker sees the assignment as "programmatic" and skips the onChange dispatch. The prototype-level setter (`HTMLInputElement.prototype`'s `value` setter) bypasses React's override, mutates the underlying DOM value directly, and then the manually-dispatched `input` event lets React pick up the change through its normal delegation path.

`preview_fill` sometimes hits the same trap when the MCP backend chooses `element.value = …` rather than simulating per-character keystrokes. Using the explicit setter is defensive and keeps the verification deterministic.
