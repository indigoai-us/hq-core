---
id: tauri-event-payload-encoding
title: Tauri event payloads are double-JSON-encoded
scope: repo
trigger: tauri webview JS↔Rust communication
enforcement: soft
public: true
---

## Rule

When receiving data from Tauri's JS event system (`app.listen()` + `window.__TAURI__.event.emit()`), the payload arrives double-JSON-encoded. A JSON array `[{"path":"body"}]` arrives as `"[{\"path\":\"body\"}]"` — a JSON string containing escaped JSON.

Always use `serde_json::from_str::<String>(payload)` to unwrap the outer encoding before parsing the inner content. Simple string slicing (`&s[1..len-1]`) does NOT work because it leaves escape sequences (`\"`) intact.

Additionally, when injecting JS that returns a value through the event bridge, use `eval(json_string)` rather than wrapping in `(function() { {js} })()`. The latter creates a new function scope where IIFE return values are silently discarded.

## Rationale

Three failed attempts during tauri-agent-browser development: first returned `null` (IIFE scope issue), then returned unparseable escaped JSON (simple slice). Only `serde_json::from_str::<String>()` handles all Tauri payload edge cases.

## How to apply

Any code reading Tauri event payloads in Rust must deserialize the string wrapper first. Any code injecting JS for eval-and-return must use the eval pattern, not function wrapping.
