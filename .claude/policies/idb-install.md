---
id: idb-install
title: Facebook idb Installation
scope: command
trigger: installing idb for iOS simulator control
enforcement: soft
---

## Rule

To install Facebook's `idb` (iOS debug bridge) for iOS simulator control:

```bash
brew tap facebook/fb
brew install idb-companion
pip3 install fb-idb  # Python client, installs to ~/Library/Python/3.9/bin/idb
```

Do NOT use `brew install --cask companion` — that installs Bitfocus Companion (Streamdeck software), not idb.

The `ios-simulator-mcp` MCP server wraps `idb_companion`. After installing and adding the MCP server (`claude mcp add ios-simulator npx ios-simulator-mcp`), restart the Claude Code session for the MCP server to connect.

