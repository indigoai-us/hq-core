# agent-browser with Tauri apps (macOS / WebKit)

`agent-browser` uses Chrome DevTools Protocol by default. macOS Tauri apps run on WKWebView, which doesn't expose CDP. Use the `tauri-plugin-agent-test` MCP plugin instead.

## How it works

The plugin starts an MCP HTTP+SSE server inside your Tauri app. The `agent-browser-provider-tauri` crate (or the `tauri://` connect URL) translates standard agent-browser commands to MCP tool calls against that server.

```
agent-browser connect tauri://localhost:9876
```

After connecting, all standard commands work: `snapshot`, `click`, `fill`, `screenshot`, `navigate`, `close`.

## Setup (Tauri app side)

Add to your Tauri app as a **dev dependency only**:

```toml
# src-tauri/Cargo.toml
[dependencies]
tauri-plugin-agent-test = { git = "https://github.com/{your-name}/tauri-agent-browser" }
```

Register in `main.rs`:

```rust
fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_agent_test::init())  // default: localhost:9876
        .run(tauri::generate_context!())
        .unwrap();
}
```

## Connecting

```bash
# In one terminal — launch your Tauri app in dev mode
pnpm tauri dev

# In another terminal
agent-browser connect tauri://localhost:9876
snapshot               # accessibility tree with @ref identifiers
click e3               # click element by ref
fill e5 "user@test.com"
screenshot             # PNG returned as base64
navigate https://...
close
```

## Snapshot output

The `snapshot` tool returns an accessibility tree. Interactive elements have stable `@ref` identifiers (`e1`, `e2`, …) that persist across multiple snapshot calls until navigation occurs.

```json
[
  {
    "ref": "e1",
    "element_type": "button[type=submit]",
    "text": "Login",
    "bounds": {"x": 40, "y": 350, "width": 120, "height": 36},
    "interactive": true,
    "children": []
  }
]
```

Pass `{"interactive_only": true}` to filter to clickable/fillable elements only.

## Key differences from CDP

| | CDP (web/Electron) | Tauri MCP plugin |
|---|---|---|
| Connection | `agent-browser connect <cdp-url>` | `agent-browser connect tauri://localhost:9876` |
| Platform | Chrome, Edge, Electron | macOS WKWebView (Tauri v2) |
| Ref IDs | DOM node IDs | Path-fingerprint based (`e1`, `e2`, …) |
| Screenshot | Native CDP | macOS `CGWindowListCreateImage` |
| Port default | 9222 | 9876 |

## Required: withGlobalTauri

The host Tauri app must have `withGlobalTauri: true` in `tauri.conf.json`:

```json
{
  "app": {
    "withGlobalTauri": true
  }
}
```

Without this, the JS→Rust event bridge (`window.__TAURI__.event.emit`) is not available and all tool calls will timeout.

## Verified on

- **{your-app}** (Tauri v2 + React 19): 24 interactive elements detected (icon rail, company selector, all navigation buttons)
- MCP protocol: initialize, tools/list, tools/call all work over HTTP+SSE
- 98 unit tests in the plugin repo, 493 tests in the upstream agent-browser fork

## Upstream PR

PR #921 to `vercel-labs/agent-browser` adds `--provider tauri` support: https://github.com/vercel-labs/agent-browser/pull/921

## Repo

`repos/public/tauri-agent-browser` — Cargo workspace with `shared`, `tauri-plugin-agent-test`, `agent-browser-provider-tauri`.
GitHub: https://github.com/{your-name}/tauri-agent-browser
