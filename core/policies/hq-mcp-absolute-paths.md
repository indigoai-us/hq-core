---
id: hq-mcp-absolute-paths
title: Use absolute paths for Homebrew binaries (MCP + Bash tool)
scope: global
trigger: mcp, .mcp.json, stdio, npx, node, aws, brew, homebrew, bash tool
when: .mcp.json || mcp
on: [UserPromptSubmit, AssistantIntent]
enforcement: hard
tier: 1
version: 3
created: 2026-04-01
updated: 2026-04-02
source: success-pattern
public: true
---

## Rule

ALWAYS use absolute paths (e.g. `/opt/homebrew/bin/npx`, `/opt/homebrew/bin/node`) for `command` fields in `.mcp.json` stdio-type servers. Bare `npx` or `node` fail silently because Claude Code spawns MCP subprocesses without the full shell profile — `/opt/homebrew/bin` is not on PATH.

ALWAYS include `"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"` in the `env` block of stdio MCP servers that use `npx tsx` or similar wrappers. Absolute path on `command` only fixes the first hop — `npx tsx` internally spawns `node` with a bare name, which fails without PATH set in the subprocess environment.

ALWAYS use full paths for Homebrew-installed binaries in the Bash tool. Claude Code's shell environment does NOT include `/opt/homebrew/bin/` in PATH. Common binaries affected: `/opt/homebrew/bin/aws`, `/opt/homebrew/bin/brew`, `/opt/homebrew/bin/node`, `/opt/homebrew/bin/npx`. Bare `aws` or `brew` will exit 127 ("command not found").

HTTP-type MCP servers are unaffected (they connect to already-running processes).

## Rationale

The root cause was `"command": "npx"` resolving to nothing in the subprocess environment. Fixed by replacing with `/opt/homebrew/bin/npx` and `/opt/homebrew/bin/node`.

Same root cause — Homebrew bin not on Claude Code's Bash PATH. Fixed by using full path.
