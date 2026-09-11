# hq-core: public
# Grok MCP default-on set (HQ project)

Grok-only. Do not mirror into Claude hooks.

Project `.mcp.json` default-on servers must stay **healthy**. Closed desktop apps that handshake-fail on every session start dump transport noise into the model prompt.

## Default-on (HQ project)

- `hq-work` — keep. HQ Board / work-mesh MCP.

## Not default-on

- **Figma** (`http://localhost:3845/mcp`) and **Paper** (`mcp-remote` to `127.0.0.1:29979`) live in `.mcp.optional.json`. Merge them into `.mcp.json` only when those desktop apps are running.
- **Superhuman** profiles (`superhuman-*`) come from the **user-global** Grok MCP config (`~/.grok`), not this HQ project. HQ does not rewrite that file. To kill `auth_required` start banners, disable or complete OAuth for those servers in Grok settings. Dead `gmail`/`slack` stderr under `~/.grok/logs/mcp` is history unless those servers are still registered.

## Enable path

Copy the `figma` and/or `paper` objects from `.mcp.optional.json` into `.mcp.json` `mcpServers` when you need those tools, then remove them again when the apps are closed.
