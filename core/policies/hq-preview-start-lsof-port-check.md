---
id: hq-preview-start-lsof-port-check
title: Probe the target port with lsof before preview_start on a fresh launch.json entry
scope: global
trigger: when calling preview_start on a newly-added server entry in the Claude Preview launch registry
enforcement: soft
public: true
version: 1
created: 2026-04-22
updated: 2026-04-22
source: session-learning
---

## Rule

Before invoking `preview_start { name: "..." }` on a server entry that was just added (or whose port was just changed), probe the target port:

```bash
lsof -i :PORT
```

- If the port is free → `preview_start` normally.
- If another process already holds the port → **edit `launch.json` to pick a free port** (or stop the conflicting process). Do not try to evict the existing Claude Preview reservation — reservations are persistent across sessions and `preview_start` will attach to whatever is bound there, producing confusing "already running" or cross-server output.

This probe is cheap (sub-second) and prevents a class of silent failures where `preview_start` reports success but the logs stream belongs to a different app.

## Rationale

The preview reservation survived an explicit evict attempt and kept routing to the old process. Resolution required editing `launch.json` to a free port. An `lsof -i :PORT` check before `preview_start` would have surfaced the collision upfront and saved the evict detour.

## Relates To

- `hq-preview-start-launch-registry-is-global` — complementary rule on *where* the registry lives (user-level, not repo-local). This rule covers *port hygiene* once the entry is registered.
