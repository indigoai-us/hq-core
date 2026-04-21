---
id: hq-preview-start-launch-registry-is-global
title: "preview_start reads the user-level launch registry, not repo-local .claude/launch.json"
scope: global
trigger: "attempting to preview_start a server by name in a repo that has its own .claude/launch.json"
enforcement: soft
public: true
version: 1
created: 2026-04-17
updated: 2026-04-17
source: session-learning
---

## Rule

`preview_start { name: "..." }` resolves the server name against the **user-level** Claude Preview launch registry, NOT the repo-local `.claude/launch.json` you may find committed in a repo. Adding an entry to `repos/.../foo/.claude/launch.json` does NOT register it — `preview_start` will still fail with "No server named 'foo' found".

Before running `preview_start`:

1. Check the existing registry with `preview_list` to see what names are actually registered.
2. If the server is absent, either (a) start it manually with the appropriate `bun nx run {app}:dev` / `bun run --filter {app} dev` command, or (b) add it via the Claude Preview settings UI at the user level — editing repo-local JSON is a no-op.
3. If you can't register it and the feature requires authentication (e.g. admin dashboard), explicitly tell the user you can't verify in-browser, and fall back to type-check + lint + targeted grep as coverage. Do NOT claim visual verification you didn't perform.

## Examples

**Correct:** run `preview_list` first. If the server isn't registered and can't be added, tell the user: "Can't drive the authenticated super-admin screen in preview — relying on TypeScript + lint + grep for coverage instead."

**Incorrect:** add a block to repo-local `.claude/launch.json` and assume `preview_start { name: "..." }` now works.
