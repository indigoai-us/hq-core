# Command Reference

Complete reference for all agent-browser commands. For quick start and common patterns, see SKILL.md.

## Navigation

```bash
agent-browser open <url>      # Navigate to URL (aliases: goto, navigate)
                              # Supports: https://, http://, file://, about:, data://
                              # Auto-prepends https:// if no protocol given
agent-browser back            # Go back
agent-browser forward         # Go forward
agent-browser reload          # Reload page
agent-browser close           # Close browser (aliases: quit, exit)
agent-browser connect 9222    # Connect to browser via CDP port
```

## Snapshot (page analysis)

```bash
agent-browser snapshot            # Full accessibility tree
agent-browser snapshot -i         # Interactive elements only (recommended)
agent-browser snapshot -c         # Compact output
agent-browser snapshot -d 3       # Limit depth to 3
agent-browser snapshot -s "#main" # Scope to CSS selector
```

## Interactions (use @refs from snapshot)

```bash
agent-browser click @e1           # Click
agent-browser click @e1 --new-tab # Click and open in new tab
agent-browser dblclick @e1        # Double-click
agent-browser focus @e1           # Focus element
agent-browser fill @e2 "text"     # Clear and type
agent-browser type @e2 "text"     # Type without clearing
agent-browser press Enter         # Press key (alias: key)
agent-browser press Control+a     # Key combination
agent-browser keydown Shift       # Hold key down
agent-browser keyup Shift         # Release key
agent-browser hover @e1           # Hover
agent-browser check @e1           # Check checkbox
agent-browser uncheck @e1         # Uncheck checkbox
agent-browser select @e1 "value"  # Select dropdown option
agent-browser select @e1 "a" "b"  # Select multiple options
agent-browser scroll down 500     # Scroll page (default: down 300px)
agent-browser scrollintoview @e1  # Scroll element into view (alias: scrollinto)
agent-browser drag @e1 @e2        # Drag and drop
agent-browser upload @e1 file.pdf # Upload files
agent-browser download @e1 ./out  # Download file by clicking element
```

## Get Information

```bash
agent-browser get text @e1        # Get element text
agent-browser get html @e1        # Get innerHTML
agent-browser get value @e1       # Get input value
agent-browser get attr @e1 href   # Get attribute
agent-browser get title           # Get page title
agent-browser get url             # Get current URL
agent-browser get count ".item"   # Count matching elements
agent-browser get box @e1         # Get bounding box
agent-browser get styles @e1      # Get computed styles (font, color, bg, etc.)
agent-browser get cdp-url         # Get CDP WebSocket URL for external tools
```

## Check State

```bash
agent-browser is visible @e1      # Check if visible
agent-browser is enabled @e1      # Check if enabled
agent-browser is checked @e1      # Check if checked
```

## Screenshots and PDF

```bash
agent-browser screenshot              # Save to temporary directory
agent-browser screenshot path.png     # Save to specific path
agent-browser screenshot --full       # Full page
agent-browser screenshot --annotate   # Labeled screenshot with bounding boxes + ref labels (for vision models)
agent-browser screenshot --screenshot-dir ./captures    # Persistent output directory
agent-browser screenshot --screenshot-quality 80        # JPEG/WebP quality (0-100)
agent-browser screenshot --screenshot-format jpeg       # Format: png (default), jpeg, webp
agent-browser pdf output.pdf          # Save as PDF
```

## Clipboard

```bash
agent-browser clipboard read          # Read clipboard contents
agent-browser clipboard write "text"  # Write text to clipboard
agent-browser clipboard copy          # Trigger Ctrl+C (copy selection)
agent-browser clipboard paste         # Trigger Ctrl+V (paste)
```

## Video Recording

```bash
agent-browser record start ./demo.webm    # Start recording
agent-browser click @e1                   # Perform actions
agent-browser record stop                 # Stop and save video
agent-browser record restart ./take2.webm # Stop current + start new
```

## Wait

```bash
agent-browser wait @e1                     # Wait for element
agent-browser wait 2000                    # Wait milliseconds
agent-browser wait --text "Success"        # Wait for text (or -t)
agent-browser wait --url "**/dashboard"    # Wait for URL pattern (or -u)
agent-browser wait --load networkidle      # Wait for network idle (or -l)
agent-browser wait --fn "window.ready"     # Wait for JS condition (or -f)
```

## Mouse Control

```bash
agent-browser mouse move 100 200      # Move mouse
agent-browser mouse down left         # Press button
agent-browser mouse up left           # Release button
agent-browser mouse wheel 100         # Scroll wheel
```

## Semantic Locators (alternative to refs)

```bash
agent-browser find role button click --name "Submit"
agent-browser find text "Sign In" click
agent-browser find text "Sign In" click --exact      # Exact match only
agent-browser find label "Email" fill "user@test.com"
agent-browser find placeholder "Search" type "query"
agent-browser find alt "Logo" click
agent-browser find title "Close" click
agent-browser find testid "submit-btn" click
agent-browser find first ".item" click
agent-browser find last ".item" click
agent-browser find nth 2 "a" hover
```

## Browser Settings

```bash
agent-browser set viewport 1920 1080          # Set viewport size
agent-browser set viewport 1440 900 --scale 2 # Retina / device scale factor
agent-browser set device "iPhone 14"          # Emulate device
agent-browser set geo 37.7749 -122.4194       # Set geolocation (alias: geolocation)
agent-browser set offline on                  # Toggle offline mode
agent-browser set headers '{"X-Key":"v"}'     # Extra HTTP headers
agent-browser set credentials user pass       # HTTP basic auth (alias: auth)
agent-browser set media dark                  # Emulate color scheme
agent-browser set media light reduced-motion  # Light mode + reduced motion
```

## Cookies and Storage

```bash
agent-browser cookies                     # Get all cookies
agent-browser cookies set name value      # Set cookie
agent-browser cookies clear               # Clear cookies
agent-browser storage local               # Get all localStorage
agent-browser storage local key           # Get specific key
agent-browser storage local set k v       # Set value
agent-browser storage local clear         # Clear all
```

## Network

```bash
agent-browser network route <url>              # Intercept requests
agent-browser network route <url> --abort      # Block requests
agent-browser network route <url> --body '{}'  # Mock response
agent-browser network unroute [url]            # Remove routes
agent-browser network requests                 # View tracked requests
agent-browser network requests --filter api    # Filter requests
```

## Tabs and Windows

```bash
agent-browser tab                 # List tabs
agent-browser tab new [url]       # New tab
agent-browser tab 2               # Switch to tab by index
agent-browser tab close           # Close current tab
agent-browser tab close 2         # Close tab by index
agent-browser window new          # New window
```

## Frames

```bash
agent-browser frame "#iframe"     # Switch to iframe
agent-browser frame main          # Back to main frame
```

## Dialogs

```bash
agent-browser dialog accept [text]  # Accept dialog
agent-browser dialog dismiss        # Dismiss dialog
```

## JavaScript

```bash
agent-browser eval "document.title"          # Simple expressions only
agent-browser eval -b "<base64>"             # Any JavaScript (base64 encoded)
agent-browser eval --stdin                   # Read script from stdin
```

Use `-b`/`--base64` or `--stdin` for reliable execution. Shell escaping with nested quotes and special characters is error-prone.

```bash
# Base64 encode your script, then:
agent-browser eval -b "ZG9jdW1lbnQucXVlcnlTZWxlY3RvcignW3NyYyo9Il9uZXh0Il0nKQ=="

# Or use stdin with heredoc for multiline scripts:
cat <<'EOF' | agent-browser eval --stdin
const links = document.querySelectorAll('a');
Array.from(links).map(a => a.href);
EOF
```

## State Management

```bash
agent-browser state save auth.json    # Save cookies, storage, auth state
agent-browser state load auth.json    # Restore saved state
agent-browser state list              # List saved session states
agent-browser state show <name>       # Display session state details
agent-browser state rename <old> <new> # Rename saved state
agent-browser state clear [name]      # Clear saved states (--all for all)
agent-browser state clean --older-than 30  # Delete states older than N days
```

## Global Options

```bash
agent-browser --session <name> ...    # Isolated browser session
agent-browser --json ...              # JSON output for parsing
agent-browser --headed ...            # Show browser window (not headless)
agent-browser --full ...              # Full page screenshot (-f)
agent-browser --cdp <port> ...        # Connect via Chrome DevTools Protocol
agent-browser -p <provider> ...       # Cloud browser provider (--provider)
agent-browser --proxy <url> ...       # Use proxy server
agent-browser --headers <json> ...    # HTTP headers scoped to URL's origin
agent-browser --executable-path <p>   # Custom browser executable
agent-browser --extension <path> ...  # Load browser extension (repeatable)
agent-browser --engine lightpanda     # Alternative browser engine (Lightpanda)
agent-browser --ignore-https-errors   # Ignore SSL certificate errors
agent-browser --auto-connect          # Auto-discover and connect to running Chrome
agent-browser --session-name <name>   # Auto-save/restore session state (cookies, localStorage)
agent-browser --config <path>         # Use custom config file (or AGENT_BROWSER_CONFIG env)
agent-browser --debug                 # Debug output
agent-browser --help                  # Show help (-h)
agent-browser --version               # Show version (-V)
agent-browser <command> --help        # Show detailed help for a command
```

## Debugging

```bash
agent-browser --headed open example.com   # Show browser window
agent-browser inspect                     # Open Chrome DevTools for active page
agent-browser --cdp 9222 snapshot         # Connect via CDP port
agent-browser connect 9222                # Alternative: connect command
agent-browser console                     # View console messages
agent-browser console --clear             # Clear console
agent-browser errors                      # View page errors
agent-browser errors --clear              # Clear errors
agent-browser highlight @e1               # Highlight element
agent-browser trace start                 # Start recording trace
agent-browser trace stop trace.zip        # Stop and save trace
agent-browser profiler start              # Start Chrome DevTools profiler
agent-browser profiler stop profile.json  # Stop and save profile
```

## Configuration

```bash
# agent-browser looks for config in (lowest to highest priority):
#   1. ~/.agent-browser/config.json    User-level defaults
#   2. ./agent-browser.json            Project-level overrides
#   3. Environment variables           Override config
#   4. CLI flags                       Override everything

# Example agent-browser.json:
# {"headed": true, "proxy": "http://localhost:8080", "profile": "./browser-data"}
```

## Environment Variables

```bash
AGENT_BROWSER_SESSION="mysession"            # Default session name
AGENT_BROWSER_SESSION_NAME="myapp"           # Auto-save/restore state persistence name
AGENT_BROWSER_ENCRYPTION_KEY="<64-hex>"      # AES-256-GCM key for state encryption
AGENT_BROWSER_STATE_EXPIRE_DAYS="30"         # Auto-delete states older than N days
AGENT_BROWSER_CONFIG="/path/to/config.json"  # Custom config file path
AGENT_BROWSER_EXECUTABLE_PATH="/path/chrome" # Custom browser path
AGENT_BROWSER_EXTENSIONS="/ext1,/ext2"       # Comma-separated extension paths
AGENT_BROWSER_ENGINE="lightpanda"            # Browser engine (chrome default, or lightpanda)
AGENT_BROWSER_PROVIDER="browserbase"         # Cloud browser provider (ios, browserbase, kernel, browseruse, browserless)
AGENT_BROWSER_SCREENSHOT_DIR="./captures"    # Persistent screenshot output directory
AGENT_BROWSER_SCREENSHOT_QUALITY="80"        # JPEG/WebP quality (0-100)
AGENT_BROWSER_SCREENSHOT_FORMAT="png"        # Screenshot format: png, jpeg, webp
AGENT_BROWSER_STREAM_PORT="9223"             # WebSocket streaming port
AGENT_BROWSER_AUTO_CONNECT="true"            # Auto-discover running Chrome
AGENT_BROWSER_ALLOW_FILE_ACCESS="true"       # Allow file:// URLs
AGENT_BROWSER_HEADED="true"                  # Show browser window
AGENT_BROWSER_JSON="true"                    # JSON output
AGENT_BROWSER_DEBUG="true"                   # Debug output
AGENT_BROWSER_IGNORE_HTTPS_ERRORS="true"     # Ignore SSL errors
AGENT_BROWSER_IOS_DEVICE="iPhone 16 Pro"     # Default iOS device name
AGENT_BROWSER_IOS_UDID="<udid>"              # Default iOS device UDID
```
