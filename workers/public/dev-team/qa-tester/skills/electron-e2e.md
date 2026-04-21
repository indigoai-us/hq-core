# electron-e2e

Drive the {company} NX Electron app through `electron-test-mcp` — take screenshots, assert DOM state, click UI elements, fill inputs, evaluate JavaScript, and verify multi-window behavior. Use this skill for any E2E verification task on the Electron renderer process.

---

## Prerequisites

All of the following must be true before running any tool:

1. **Electron app is running** — `cd apps/electron && pnpm run start` (CDP on port 9222)
2. **electron-test-mcp is loaded** — starts automatically via `.mcp.json` stdio transport in Claude Code; or manually: `cd apps/electron-test-mcp && npx tsx src/server.ts`
3. **Backend API is reachable** — `http://localhost:8080` (required for `login` tool's JWT fetch)
4. **LangGraph** (optional) — `http://localhost:2024` (only needed for agent/graph features)

---

## Startup Instructions

### Step 1 — Start the Electron app

```bash
cd /path/to/{your-repo}/apps/electron
pnpm run start
```

Wait for the app window to appear. The webpack dev server runs on port 1212; the main process exposes CDP on port 9222.

### Step 2 — Verify MCP connection

The MCP server starts automatically in Claude Code via `.mcp.json`. To verify it is connected, call `get_windows` — it should return at least one window entry with a URL containing `localhost:1212`.

```json
// get_windows — no inputs required
{}
```

Expected output:
```json
{
  "success": true,
  "data": [
    {
      "id": 1,
      "url": "http://localhost:1212/",
      "title": "{company}",
      "bounds": { "x": 0, "y": 0, "width": 1280, "height": 800 }
    }
  ]
}
```

If `success` is false or `data` is empty, the Electron app is not running or CDP is not on port 9222.

### Step 3 — Manual MCP start (fallback)

If the MCP server is not auto-loaded, start it manually in a separate terminal:

```bash
cd /path/to/{your-repo}/apps/electron-test-mcp
npx tsx src/server.ts
```

---

## Login Flow

Always call `login` before any test that requires an authenticated session. The tool:
1. Fetches a JWT from `http://localhost:8080` for the given email
2. Injects it into the Electron renderer via IPC channel `auth:authenticate`
3. Waits until `[data-user-profile-button]` is visible in the DOM

```json
// login — authenticate with default test user
{
  "email": "devin@{your-domain}"
}
```

Successful response:
```json
{ "success": true }
```

Failed response (backend unreachable, invalid user, or profile button never appeared):
```json
{ "success": false, "error": "..." }
```

After a successful `login`, the app is in an authenticated state and ready for interaction. Call `snapshot` or `screenshot` to verify the UI is fully loaded before proceeding.

---

## Selector Cheat Sheet

| Element | CSS Selector |
|---------|-------------|
| User profile button | `[data-user-profile-button]` |
| Command palette trigger | invoke `eval` with `window.dispatchEvent(new KeyboardEvent('keydown', {key:'i', altKey:true}))` |
| Chat message input | `textarea[data-message-input]` or `[data-chat-input] textarea` |
| Send button | `[data-send-button]` or `button[type="submit"]` near message input |
| Library sidebar | `[data-library-sidebar]` |
| @ mention trigger | Type `@` in chat input |
| Command palette search | `[data-command-palette] input`, `[data-command-search]` |
| Command palette window | check `get_windows` for a window with `command-palette` in its URL/title |

> These selectors are derived from known `data-*` attribute conventions in the codebase. Use `snapshot` to discover the exact rendered HTML if a selector does not match.

---

## Tool Reference

### `snapshot`

Returns the full HTML of the active renderer page as a string. Use this to inspect the current DOM, discover selectors, or verify content.

**Inputs:** none

**Output:**
```json
{ "success": true, "data": "<html>...</html>" }
```

---

### `screenshot`

Captures a PNG screenshot of the active renderer window. Returns base64-encoded image data.

**Inputs:**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `width` | integer | no | Override capture width in pixels |
| `height` | integer | no | Override capture height in pixels |

**Output:**
```json
{ "success": true, "data": "<base64-encoded PNG>" }
```

---

### `click`

Clicks the first DOM element matching the given CSS selector.

**Inputs:**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `selector` | string | yes | CSS selector for the target element |

**Output:**
```json
{ "success": true }
// or on failure:
{ "success": false, "error": "Element not found: [data-send-button]" }
```

---

### `fill`

Clears an input or textarea and types the specified value.

**Inputs:**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `selector` | string | yes | CSS selector for the input element |
| `value` | string | yes | Text to type into the input |

**Output:**
```json
{ "success": true }
// or on failure:
{ "success": false, "error": "..." }
```

---

### `eval`

Evaluates arbitrary JavaScript in the active renderer page context. Use for keyboard event dispatch, reading DOM properties, or calling window-level APIs.

**Inputs:**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `code` | string | yes | JavaScript expression or statement(s) to evaluate |

**Output:**
```json
{ "success": true, "result": <any serializable value> }
// or on failure:
{ "success": false, "error": "ReferenceError: ..." }
```

---

### `login`

Fetches a JWT from the backend API, injects it into the app via IPC, and waits for the profile button to appear. This is the canonical way to authenticate in tests.

**Inputs:**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `email` | string | no | Test user email. Defaults to `devin@{your-domain}` |

**Output:**
```json
{ "success": true }
// or on failure:
{ "success": false, "error": "..." }
```

---

### `navigate`

Navigates the app to a named route using the `navigate-assistant` IPC channel, which drives React MemoryRouter.

**Inputs:**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `path` | string | yes | Route path (e.g. `/chat`, `/library`, `/settings`) |

**Output:**
```json
{ "success": true }
// or on failure:
{ "success": false, "error": "..." }
```

---

### `get_windows`

Lists all currently open BrowserWindow instances in the Electron process.

**Inputs:** none

**Output:**
```json
{
  "success": true,
  "data": [
    {
      "id": 1,
      "url": "http://localhost:1212/",
      "title": "{company}",
      "bounds": { "x": 0, "y": 0, "width": 1280, "height": 800 }
    }
  ]
}
```

---

### `ipc_invoke`

Calls `ipcRenderer.invoke` on the active renderer with the given channel and arguments. Use for low-level IPC operations not covered by other tools.

**Inputs:**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `channel` | string | yes | IPC channel name |
| `args` | array | no | Arguments to pass to the handler |

**Output:**
```json
{ "success": true, "result": <any> }
// or on failure:
{ "success": false, "error": "No handler for channel: ..." }
```

---

### `assert`

Performs structured DOM assertions against an element. Supports visibility, text content, count, attribute value, enabled state, and a configurable timeout. Returns a structured result rather than throwing.

**Inputs:**
| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `selector` | string | yes | CSS selector for the target element(s) |
| `window_id` | integer | no | Target a specific BrowserWindow by ID (from `get_windows`) |
| `visible` | boolean | no | Assert the element is visible |
| `hidden` | boolean | no | Assert the element is hidden (not in DOM or display:none) |
| `text` | string | no | Assert the element's text content contains this string |
| `count` | integer | no | Assert the number of matching elements |
| `attribute` | `{name: string, value: string}` | no | Assert an attribute has a specific value |
| `enabled` | boolean | no | Assert the element is not disabled |
| `timeout` | integer | no | Max wait in ms before failing. Default: 5000 |

**Output:**
```json
{
  "pass": true,
  "actual": { "visible": true, "text": "Devin", "count": 1 },
  "expected": { "visible": true },
  "selector": "[data-user-profile-button]",
  "conditions_checked": ["visible"]
}
```

On failure `pass` is `false` and `actual` shows what was found.

---

## Common Test Patterns

### Wait for element to become visible

Use `assert` with `visible: true` and a generous `timeout` instead of sleeping:

```json
{
  "selector": "[data-user-profile-button]",
  "visible": true,
  "timeout": 10000
}
```

### Assert text content

```json
{
  "selector": "[data-message-bubble]:last-child",
  "text": "Hello from the test",
  "visible": true
}
```

### Assert element count

```json
{
  "selector": "[data-chat-message]",
  "count": 3
}
```

### Assert element is hidden

```json
{
  "selector": "[data-loading-spinner]",
  "hidden": true,
  "timeout": 8000
}
```

### Read a DOM value via eval

```json
{
  "code": "document.querySelector('[data-user-profile-button]')?.getAttribute('data-email')"
}
```

### Dispatch a keyboard shortcut

```json
{
  "code": "window.dispatchEvent(new KeyboardEvent('keydown', { key: 'i', altKey: true, bubbles: true }))"
}
```

### Verify a second window opened

```json
// get_windows — no inputs
{}
// Then check data.length === 2 and inspect the new window's url/title
```

### Invoke IPC directly

```json
{
  "channel": "auth:authenticate",
  "args": [{ "token": "eyJ..." }]
}
```

---

## Example Test Sequences

### 1. Auth Flow

Verify the app starts, the user can log in, the profile button is visible, and capture a snapshot.

**Step 1 — Verify Electron is running**
```json
// get_windows
{}
```
Assert: `data` has at least one window.

**Step 2 — Log in**
```json
// login
{ "email": "devin@{your-domain}" }
```
Assert: `success: true`

**Step 3 — Assert profile button is visible**
```json
// assert
{
  "selector": "[data-user-profile-button]",
  "visible": true,
  "timeout": 8000
}
```
Assert: `pass: true`

**Step 4 — Take snapshot**
```json
// snapshot
{}
```
Inspect the returned HTML to confirm the main shell is rendered.

**Step 5 — Take screenshot**
```json
// screenshot
{}
```
Visual confirmation of authenticated state.

---

### 2. Send Message

Log in, navigate to the chat view, type a message, send it, and assert it appears in the thread.

**Step 1 — Log in**
```json
// login
{ "email": "devin@{your-domain}" }
```

**Step 2 — Navigate to chat**
```json
// navigate
{ "path": "/chat" }
```

**Step 3 — Wait for message input to be ready**
```json
// assert
{
  "selector": "textarea[data-message-input]",
  "visible": true,
  "timeout": 8000
}
```

**Step 4 — Fill the message input**
```json
// fill
{
  "selector": "textarea[data-message-input]",
  "value": "Hello from the E2E test"
}
```

**Step 5 — Click send**
```json
// click
{ "selector": "[data-send-button]" }
```

**Step 6 — Assert message appears in thread**
```json
// assert
{
  "selector": "[data-chat-message]",
  "text": "Hello from the E2E test",
  "visible": true,
  "timeout": 10000
}
```

**Step 7 — Screenshot**
```json
// screenshot
{}
```

---

### 3. Command Palette Open / Search

Log in, trigger the command palette with Alt+I, verify the palette window appears, and assert the search input is visible.

**Step 1 — Log in**
```json
// login
{ "email": "devin@{your-domain}" }
```

**Step 2 — Capture baseline window count**
```json
// get_windows
{}
```
Note the current window count (typically 1).

**Step 3 — Dispatch Alt+I keyboard shortcut**
```json
// eval
{
  "code": "window.dispatchEvent(new KeyboardEvent('keydown', { key: 'i', altKey: true, bubbles: true, cancelable: true }))"
}
```

**Step 4 — Verify palette window opened**
```json
// get_windows
{}
```
Assert: `data.length` is one greater than baseline, and the new entry has a URL or title referencing `command-palette`.

**Step 5 — Assert search input is visible in palette window**
```json
// assert
{
  "selector": "[data-command-search]",
  "visible": true,
  "timeout": 5000
}
```
If the palette opens in a separate `window_id`, pass that ID:
```json
// assert
{
  "selector": "[data-command-search]",
  "window_id": 2,
  "visible": true,
  "timeout": 5000
}
```

**Step 6 — Screenshot to confirm**
```json
// screenshot
{}
```
