---
id: hq-no-screencapture-self-verify-gui
title: Do not rely on screencapture to self-verify GUI output
scope: global
trigger: Verifying GUI output of an app from within an agent session on macOS
enforcement: soft
public: true
version: 1
created: 2026-05-29
updated: 2026-05-29
source: success-pattern
---

## Rule

NEVER: Rely on `screencapture` to self-verify GUI output in an agent session — it fails ('could not create image') without Screen Recording permission. Diagnose via app logs and ask the user for screenshots instead.

## Rationale

User-validated finding from a session shipping custom notification banners in HQ Sync. `screencapture` requires Screen Recording permission the agent session lacks, so it returns 'could not create image' — diagnose via app logs and request screenshots from the user.
