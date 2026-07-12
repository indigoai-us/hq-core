---
id: hq-never-echo-tokens-stdout
title: Never echo API keys or tokens to stdout
when: secret || credential || credentials || password || passphrase || token || apikey || api_key
on: [UserPromptSubmit, AssistantIntent, PreToolUse]
enforcement: hard
tier: 1
version: 1
created: 2026-03-28
updated: 2026-03-28
source: back-pressure-failure
public: true
---

## Rule

NEVER print raw API keys, tokens, or secrets to stdout in CLI setup/config commands. Use `<your-api-key>` or `<paste-your-key>` placeholders instead. CLI setup commands are designed for headless/CI environments where stdout is captured in build logs, terminal recordings, or shell history.

## Rationale

The fallback code path printed the actual API key value when no supported AI tool was detected, leaking credentials to anyone with access to CI logs.
