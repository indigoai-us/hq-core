---
id: acme-pin-widgetctl-before-deploy
title: Pin widgetctl 4.2 until the upload regression is fixed
when: widgetctl && deploy
on: [PreToolUse, PostToolUse, UserPromptSubmit, AssistantIntent]
enforcement: soft
public: false
status: active
version: 1
created: 2026-10-07
updated: 2026-10-07
source: back-pressure-failure
retire_when: widgetctl ships a release that fixes the upload regression
last_confirmed: 2026-10-07
---

## Rule

ALWAYS pin widgetctl to 4.1 when deploying; 4.2 has an upload regression that drops the last chunk.

## Rationale

Pinning the previous minor version avoids the truncated upload at the cost of missing 4.2 features.

## Provenance

Seen on acme ticket OPS-77 on 2026-10-01.
