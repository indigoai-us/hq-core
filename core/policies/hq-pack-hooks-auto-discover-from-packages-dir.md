---
id: hq-pack-hooks-auto-discover-from-packages-dir
title: HQ pack hooks auto-discover from core/packages/*/hooks/ — no settings.json edit needed
scope: global
trigger: shipping a PreToolUse/SessionStart/Stop/PostToolUse/etc. hook from inside an HQ pack
enforcement: soft
public: true
version: 1
created: 2026-05-27
updated: 2026-05-27
source: session-learning
tags: [hooks, packages, infrastructure]
---

## Rule

ALWAYS rely on `master-hook.sh` auto-discovery for pack-scoped hooks — do NOT hand-edit `settings.json` to register them. To ship a pack hook:

1. Place the script under `packages/<pack>/hooks/<event>/` in the `hq-packages` repo (e.g. `packages/hq-pack-engineering/hooks/PreToolUse/`).
2. Name the file `<NN>-<matcher>--<name>.sh`, where:
   - `<NN>` is a two-digit order prefix.
   - `<matcher>` is the tool/event matcher (`*` → `.*`, `,` → `|`); `master-hook.sh` anchors it as `^(<matcher>)$`.
   - `<name>` is a kebab-case slug describing the hook.
3. Declare the hook in the pack's `package.yaml` `hooks:` list for documentation/auditing (declaration is informational; loading is driven by filesystem discovery).
4. Once the pack is installed (symlinked into `core/packages/<pack>/`), `master-hook.sh` picks it up on the next tool event — no `.claude/settings.json` mutation required.

## Rationale

The dispatcher already enumerates `core/packages/*/hooks/<event-name>/*.sh` alongside `core/hooks/`, `personal/hooks/`, and `companies/<active>/hooks/`. Hand-editing `settings.json` to wire a pack hook duplicates auto-discovery, drifts on `hq install/uninstall`, and risks leaving dangling entries pointing at uninstalled packs. Keep the pack self-describing: filesystem layout + `package.yaml` is the contract, and the global `settings.json` matcher pointing at `master-hook.sh` is the only registration that ever needs to exist.
