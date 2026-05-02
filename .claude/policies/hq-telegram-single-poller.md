---
id: hq-telegram-single-poller
title: Telegram allows only one bot poller per token
scope: global
trigger: when deploying or configuring Telegram bots
enforcement: soft
version: 1
created: 2026-03-25
updated: 2026-03-25
source: back-pressure-failure
public: true
---

## Rule

Telegram's Bot API allows only ONE active `getUpdates` (long-polling) connection per bot token. A second poller causes 409 Conflict errors and crashes the newer instance.

Before starting a new Telegram bot with an existing token:
1. Stop ALL other processes using the same token (`pkill -f "telegram"` or disable the MCP plugin)
2. Wait ~30s for Telegram to release the connection
3. Then start the new bot

The Claude Code Telegram MCP plugin (`~/.claude/plugins/cache/claude-plugins-official/telegram/`) spawns a separate bun process per Claude Desktop session — ALL of them poll the same token. Disabling the `.env` file is not enough if sessions are already running; must kill existing plugin processes.

## Rationale

hq-cloud deployment (2026-03-25): ECS host crashed in a loop with grammy `GrammyError: 409 Conflict: terminated by other getUpdates request`. Root cause: 7 local Claude Desktop sessions each had the Telegram MCP plugin running and polling the same bot token. Renaming `.env` stopped new sessions but didn't kill existing ones. Required `pkill -f "telegram/0.0.1.*start"` to clear all pollers.
