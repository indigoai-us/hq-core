---
id: hq-email-ascii-subjects
title: ASCII Only in Email Subject Lines
scope: global
trigger: when composing email subject lines
enforcement: soft
version: 1
created: 2026-02-22
updated: 2026-02-22
source: migration
learned_from: "CLAUDE.md learned rules migration 2026-02-22"
public: true
---

## Rule

NEVER use special characters (em dash, curly quotes, Unicode punctuation) in email subject lines — they encode as garbled text. Plain ASCII only: hyphens not dashes, straight quotes.

## Rationale

Unicode characters in email subjects get garbled across email clients.
