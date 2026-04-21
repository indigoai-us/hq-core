---
type: analysis
domain: [engineering, product]
status: canonical
tags: [desktop-app, claude-code, file-locking, mcp, concurrency, integration]
relates_to: []
---

# Desktop <-> Claude Code Integration

> US-024: Analysis of how HQ Desktop and Claude Code coexist -- shared file access patterns, concurrent editing safety, MCP server potential, and Desktop-as-MCP-client architecture.

## 1. File Locking & Concurrency

### Current State

Desktop and Claude Code share the same HQ filesystem (`~/Documents/HQ/`). Today there is **no file locking** on either side:

- **Desktop reads**: All Rust commands (`list_prds`, `list_workers`, `list_threads`, `get_empire_data`, `read_file_content`, `read_json`, `read_yaml`) use `std::fs::read_to_string` with no locking, advisory or otherwise.
- **Claude Code writes**: Claude Code (via its tools) writes files atomically using temp-file-then-rename, but does not acquire locks visible to other processes.
- **File watchers**: Desktop uses `notify` (kqueue on macOS) to watch `projects/`, `apps/`, `repos/private/`, and `workspace/threads/` for changes. These react to completed writes (after rename), so they are inherently safe from partial-read issues.

### Safe Operations (No Conflict Risk)

| Desktop Operation | Claude Code Operation | Why Safe |
|---|---|---|
| `list_prds` / `list_workers` / `list_threads` | Writing any HQ file | Desktop reads entire file into memory; if file is mid-rename, `read_to_string` returns the old version or errors (handled gracefully) |
| `get_empire_data` (aggregator) | Worker execution writing threads | Thread watcher triggers refresh after write completes |
| `read_dir_tree` (file navigator) | Creating new files/dirs | readdir is atomic per entry; worst case is stale listing, fixed by next refresh |
| `start_prd_watcher` | `/prd` command creating/updating prd.json | Watcher has 100ms debounce; picks up final state |

### Unsafe / Risky Operations

| Scenario | Risk | Current Status |
|---|---|---|
| Desktop `update_project_state` while Claude writes `state.json` | Last-write-wins race condition. Both do read-modify-write with no coordination | **Active risk.** `orchestrator.rs::update_project_state` reads, modifies, and writes `state.json` without locking. If Claude's `/run-project` updates state simultaneously, one write is lost |
| Desktop `read_file_content` on a file Claude is actively streaming to | Could read partial content if file is being written incrementally (not atomically) | **Low risk.** Most HQ files are written atomically. Risk exists for large files written via streaming (e.g., report generation) |
| Desktop `spawn_worker_skill` triggering Claude Code while another Claude session is active | Two Claude Code sessions modifying same repo simultaneously | **Medium risk.** Claude Code itself serializes within a single session, but Desktop can spawn multiple PTY sessions each running independent Claude instances |

### Recommended Mitigations

1. **Advisory file locking for `state.json`**: Use `flock` (or Rust `fs2` crate) for read-modify-write on orchestrator state. This prevents Desktop and Claude from clobbering each other's state updates.

2. **Optimistic concurrency for state files**: Add a `version` counter to `state.json`. Both Desktop and Claude check version before write; reject if stale. This is a lightweight alternative to file locking.

3. **Single-writer principle for PTY sessions**: Desktop should warn before spawning a new Claude session if another is already active in the same repo. Display: "Claude session already running in {repo}. Launch anyway?"

4. **Watcher debounce alignment**: Current 100ms debounce in `start_prd_watcher` is adequate. No change needed.

## 2. MCP Integration Analysis

### Can Desktop Expose an MCP Server?

**Yes, and this is the highest-value integration path.**

MCP (Model Context Protocol) servers are stdio-based JSON-RPC processes. Desktop (Tauri) could expose an MCP server that Claude Code connects to, giving Claude real-time access to Desktop state:

| MCP Tool | Purpose | Implementation |
|---|---|---|
| `desktop.get_empire_data` | Full HQ status (workers, threads, projects, companies, sessions) | Proxy to existing `get_empire_data` Rust command |
| `desktop.get_worker_state` | Current worker execution state from Desktop's session store | Read from Zustand-backed state, emit via IPC |
| `desktop.notify` | Push notifications to Desktop UI (toasts, badges) | Tauri event emission from MCP handler |
| `desktop.get_active_sessions` | List all PTY sessions (running Claude instances) | Proxy to `list_pty_sessions` |
| `desktop.update_dashboard` | Request Desktop to refresh specific panels | Targeted Tauri event emission |

**Architecture:**

```
Claude Code --stdio--> MCP Server (Node.js child process)
                           |
                           +--> Tauri IPC --> Desktop Rust backend
                           +--> Direct fs reads (HQ workspace files)
```

The MCP server would be a Node.js process spawned by Desktop (or installed globally), with its config added to Claude Code's `.claude/settings.json` under `mcpServers`. This is the standard MCP integration pattern.

**Key benefit:** Claude Code currently has no awareness of Desktop state. With an MCP server, Claude could check "is a worker already executing in Desktop?" before spawning, or push completion notifications to the Desktop dashboard.

### Can Desktop Consume Worker MCP Servers?

**Partially. Workers declare MCP servers in `worker.yaml`, but Desktop is not currently an MCP client.**

Worker MCP server declarations (from `worker.yaml`):
```yaml
mcp:
  server:
    command: node
    args: [dist/mcp-server.js]
    cwd: workers/public/dev-team/architect
  tools:
    - system_design
    - api_design
    - code_review_plan
    - refactor_plan
```

For Desktop to consume these:

1. **Desktop would need an MCP client library** (Rust or Node.js). The `@modelcontextprotocol/sdk` npm package provides a TypeScript client, which could run in the Tauri webview or in a sidecar Node process.

2. **Worker MCP servers are designed for Claude, not humans.** Their tools expect LLM-generated prompts as input (e.g., `system_design` expects a feature description). Desktop could present these as "run this tool with parameters" forms, but the UX would be developer-oriented.

3. **Better approach: Desktop triggers Claude, Claude uses MCP tools.** Rather than Desktop directly invoking worker MCP servers, Desktop spawns a Claude session (via PTY) that invokes `/run {worker}:{skill}`, and Claude connects to the worker's MCP server. Desktop monitors progress via thread/checkpoint file watchers.

**Recommendation:** Desktop should not directly consume worker MCP servers. Instead, it should expose its own MCP server (see above) and let Claude Code be the MCP client for worker tools. Desktop's role is orchestration and visualization, not tool execution.

## 3. Claude Code Session Awareness

### Current Implementation

Desktop already has Claude session awareness via `list_claude_sessions` (Rust command in `files.rs`, lines 577-678):

- **Data source**: Reads `.claude/projects/-Users-{your-name}-Documents-HQ/*.jsonl` files
- **Extracted fields**: `session_id`, `slug`, `cwd`, `git_branch`, `first_message`, `timestamp`, `size_bytes`
- **Display**: Shown in the Empire view as part of `EmpireData.claude_sessions`
- **Limitation**: Only reads sessions for the HQ project directory. Does not discover sessions from other repos (e.g., {PRODUCT}, {company}-site)

### Gaps and Enhancements Needed

| Gap | Current | Needed |
|---|---|---|
| Multi-repo session discovery | Only reads `~/.claude/projects/-Users-{your-name}-Documents-HQ/` | Scan all `~/.claude/projects/*/` directories, map to known repos via manifest |
| Live session detection | No way to distinguish active vs. completed sessions | Check for PTY sessions running `claude` process; cross-reference with session JSONL timestamps |
| Session content parsing | Reads first 10 lines only | Parse session JSONL fully for: tool usage, files modified, token consumption, error count |
| Terminal ↔ Session linking | Desktop PTY sessions track `sessionId` but not Claude session ID | When Desktop spawns `claude` via PTY, capture the Claude session ID from stdout and link it in the session store |
| Context usage tracking | No context meter | Parse Claude session output for context usage indicators; display as progress bar in terminal header |

### Terminal Integration Architecture

Current flow:
```
Desktop UI --click "Run Worker"--> spawn_pty(shell)
                                      |
                                      +--> write_pty(`claude "/run worker:skill"\n`)
                                      |
                                      +--> PTY output streams to xterm.js via Tauri events
```

This works but is "fire and forget" -- Desktop has no structured understanding of what Claude is doing inside the PTY. Enhancement paths:

**Path A: Output Parsing (Low effort, medium value)**
- Parse PTY output stream for known patterns: `Task Complete:`, `Back Pressure:`, error markers
- Update Desktop UI based on detected patterns (status badges, progress indicators)
- Risk: Fragile; depends on Claude Code's output format remaining stable

**Path B: Sidecar Protocol (Medium effort, high value)**
- Instead of `claude` CLI, spawn `claude --output-format stream-json` (if available) or use Claude Code's SDK programmatically
- Structured JSON output enables reliable state tracking
- Desktop maintains a state machine per Claude session: `idle -> loading -> executing -> verifying -> done`

**Path C: MCP Server (Medium effort, highest value)**
- Desktop exposes MCP server (see section 2)
- Claude Code calls `desktop.notify` to push structured state updates
- Bidirectional: Desktop can also query Claude's state via MCP
- Most future-proof; aligns with MCP ecosystem direction

## 4. Architecture Recommendation

### Phased Approach

**Phase 1: Hardened File Concurrency (Now)**
- Add `fs2` crate for advisory file locking on `state.json` read-modify-write cycles
- Add version field to state files for optimistic concurrency checks
- Add "session already active" warning in session launcher

**Phase 2: Enhanced Session Awareness (Near-term)**
- Multi-repo Claude session discovery (scan all `~/.claude/projects/*/`)
- Live session detection via process inspection (check for running `claude` processes, correlate with PTY sessions)
- Link Desktop PTY session IDs to Claude session IDs by parsing initial JSONL output

**Phase 3: Desktop MCP Server (Medium-term)**
- Create `@hq/desktop-mcp-server` Node.js package
- Expose tools: `get_empire_data`, `get_active_sessions`, `notify`, `get_worker_state`
- Register in Claude Code's MCP server config
- Claude Code gains awareness of Desktop state; can push notifications

**Phase 4: Bidirectional Integration (Future)**
- Desktop acts as MCP client for desktop-mcp-server status queries
- Claude sessions report context usage, tool calls, and completion status via MCP
- Desktop renders real-time execution dashboards powered by MCP event streams
- Session resume from Desktop: select thread in UI, one-click open Claude with `--resume` flag

### Dependency Map

```
Phase 1 (file safety) ──> Phase 2 (session awareness)
                                    |
                                    v
                          Phase 3 (MCP server)
                                    |
                                    v
                          Phase 4 (bidirectional)
```

### Technology Choices

| Component | Technology | Rationale |
|---|---|---|
| File locking | `fs2` Rust crate | Lightweight, advisory locks, cross-platform |
| MCP server | Node.js + `@modelcontextprotocol/sdk` | Standard MCP SDK; matches worker MCP server pattern |
| MCP transport | stdio (standard) | Claude Code expects stdio-based MCP servers |
| Session discovery | Rust (`std::fs` + `sysinfo` crate) | Process inspection for live detection; file scanning for history |
| State protocol | JSON-RPC over MCP | Eliminates need for custom IPC; reuses MCP infrastructure |

### What NOT to Build

- **Desktop as direct MCP client to worker servers**: Workers are designed for LLM consumption, not GUI interaction. Let Claude be the intermediary.
- **Custom WebSocket/HTTP protocol between Desktop and Claude**: MCP already solves this. Adding a custom protocol creates maintenance burden.
- **File-based IPC (e.g., Desktop writes a command file, Claude polls it)**: Fragile, race-prone, and unnecessary when MCP provides structured bidirectional communication.
- **Desktop-embedded LLM**: Desktop should orchestrate, not execute. Claude Code is the execution engine.
