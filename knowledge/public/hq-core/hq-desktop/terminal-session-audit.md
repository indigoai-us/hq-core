# Terminal & Session Capabilities Audit

Comprehensive audit of the HQ Desktop terminal subsystem: PTY implementation, command palette scope, slash command coverage, thread lifecycle, session management, and the relationship between Desktop terminal sessions and Claude Code sessions.

## 1. Current terminal.rs Capabilities

### Rust PTY Commands (5 commands)

| Command | Signature | Behavior |
|---------|-----------|----------|
| `spawn_pty` | `(cmd, cwd, cols, rows) -> session_id` | Spawns PTY via `portable_pty`. Defaults to `$SHELL -l` (login shell), cwd defaults to `~/Documents/HQ`. Inherits full env, sets `TERM=xterm-256color`. Spawns reader thread that emits `pty-output` events. On exit, emits `pty-exit` with exit code and auto-cleans session. |
| `write_pty` | `(session_id, data: Vec<u8>)` | Writes raw bytes to PTY master. Flushes after write. |
| `resize_pty` | `(session_id, cols, rows)` | Resizes PTY via master handle. |
| `kill_pty` | `(session_id)` | Removes session from HashMap, kills child process. |
| `list_pty_sessions` | `() -> Vec<String>` | Returns list of active session IDs (UUIDs only, no metadata). |

### Rust State Management

- `PtyManagerState`: `HashMap<String, PtySession>` behind `Mutex`
- `PtySession` holds: `master` (Box<dyn MasterPty>), `writer` (Box<dyn Write>), `child` (Box<dyn Child>)
- Sessions auto-remove on PTY close (reader thread handles cleanup)
- No persistence -- all sessions lost on app restart

### Tauri Events Emitted

| Event | Payload | Frequency |
|-------|---------|-----------|
| `pty-output` | `{ session_id, data: Vec<u8> }` | High (every 4KB chunk of terminal output) |
| `pty-exit` | `{ session_id, code: Option<i32> }` | Once per session |

### Related Commands in files.rs

| Command | Purpose | Relevance |
|---------|---------|-----------|
| `spawn_worker_skill` | Opens macOS Terminal.app via AppleScript, runs `claude '/run {worker}:{skill}'` | EXTERNAL terminal, not integrated PTY |
| `open_terminal_in_hq` | Opens macOS Terminal.app via AppleScript, `cd` to HQ | EXTERNAL terminal, not integrated PTY |
| `list_claude_sessions` | Reads `.claude/projects/-Users-{your-name}-Documents-HQ/*.jsonl` | Read-only, returns last 20 sessions |

## 2. Frontend Session Layer

### session-store.ts (Zustand)

**State shape:**
```typescript
interface TerminalSession {
  id: string           // UUID from Rust PTY
  type: SessionType    // 'worker' | 'claude' | 'shell'
  workerId?: string
  skillId?: string
  projectName?: string
  company?: string
  cwd: string
  status: SessionStatus // 'running' | 'exited'
  startedAt: string
  exitCode?: number
  title: string
}
```

**Actions:** `addSession`, `removeSession`, `setActiveSession`, `updateSession`, `getSession`

**Gaps:**
- No session persistence (lost on reload/restart)
- No session history (once removed, gone forever)
- No session renaming
- `type: 'claude'` exists in types but is never used -- all sessions are 'shell' or 'worker'
- No context usage tracking (remaining %, auto-handoff threshold)
- No thread linkage (session is not connected to HQ thread files)
- No checkpoint/handoff state

### use-terminal.ts (Hook)

- Creates `xterm.js` Terminal instance with custom dark theme
- Loads `FitAddon` (responsive resize) and `WebLinksAddon` (clickable URLs)
- Listens for `pty-output` and `pty-exit` Tauri events
- Handles user input by writing to PTY via `write_pty`
- Manages resize via `ResizeObserver` -> `resize_pty`
- Web preview mode: shows `(web preview - no PTY)` fallback
- Scrollback: 10,000 lines
- Font: SF Mono / Menlo / Monaco, 13px

**Gaps:**
- No search-in-terminal (xterm.js `SearchAddon` not loaded)
- No copy/paste handling beyond default
- No terminal multiplexing (split panes)
- No output capture/logging for later review
- No ANSI output parsing for structured data extraction

### terminal-panel.tsx

- Tab bar with session tabs + "New Session" button
- All terminals render simultaneously (`visibility: hidden` for inactive)
- Context bar at bottom shows worker/company/project for active session
- Empty state with "New Session" button and `Cmd+N` hint

### terminal-header.tsx

- `TerminalTab`: Status dot (green pulse=running, gray=exited), company color bar, title, close button
- `TerminalContextBar`: Shows workerId:skillId, company, projectName, or cwd fallback
- Company colors: {company}=#74c0fc, {company}=#da77f2, personal=#ffd43b, golden-thread=#ff922b

### session-launcher.tsx

- Modal dialog for spawning new sessions
- Options: "New Shell" (spawns login shell in HQ) or select a worker
- Worker list loaded from `list_workers` Rust command
- Worker session: spawns PTY, then auto-types `claude "/run {worker.id}"` into terminal
- Company inference by worker ID substring matching (fragile)
- Search/filter by worker id, type, description, team

**Gaps:**
- No "New Claude Session" option (resume from thread)
- No custom command input (only shell or worker)
- No cwd picker (always HQ)
- No session template/preset system
- Worker spawning types `claude "/run {worker}"` but doesn't wait for Claude to be ready
- Company inference is substring-based, not from registry.yaml `company` field

## 3. Command Palette (command-palette.tsx)

### Currently Registered Commands (10 of 27)

| Command | Category | Present |
|---------|----------|---------|
| `/run` | worker | YES |
| `/checkpoint` | session | YES |
| `/handoff` | session | YES |
| `/nexttask` | project | YES |
| `/reanchor` | session | YES |
| `/newworker` | worker | YES |
| `/execute-task` | project | YES |
| `/run-project` | project | YES |
| `/cleanup` | system | YES |
| `/metrics` | system | YES |

### Missing Commands (17 not registered)

| Command | Category | Why It Matters |
|---------|----------|----------------|
| `/checkemail` | system | Email triage workflow |
| `/contentidea` | content | Content generation |
| `/decide` | system | Batch decision UI |
| `/email` | system | Email composition |
| `/generateimage` | content | Image generation |
| `/learn` | system | Learning capture |
| `/post-now` | social | Social posting |
| `/pr` | project | Pull request creation |
| `/plan` | project | PRD generation |
| `/preview-post` | social | Social preview |
| `/remember` | system | Manual learning capture |
| `/scheduleposts` | social | Schedule social posts |
| `/search` | system | qmd search |
| `/search-reindex` | system | Rebuild search index |
| `/social-setup` | social | Social account setup |
| `/suggestposts` | social | Generate post ideas |

### Execution Mechanism

- Commands execute via `spawn_worker_skill` which opens macOS Terminal.app (NOT the integrated PTY)
- Uses AppleScript: `tell application "Terminal" do script "cd HQ && claude '/run hq:{command}'""`
- Result: clicking a command in Desktop opens a SEPARATE Terminal.app window
- No feedback loop back to Desktop about command execution status

**Gaps:**
- Commands should execute in the integrated PTY terminal, not external Terminal.app
- No command argument input (commands that need args like `/execute-task project/story` can't receive them)
- No execution feedback (success/failure/progress)
- Categories limited to worker/session/project/system -- missing content and social
- No keyboard shortcuts for individual commands
- No "recently used" persistence across app restarts (localStorage only)

## 4. Thread Lifecycle

### HQ Thread System (as designed)

```
Creation (/checkpoint)
    |
    v
Thread JSON (workspace/threads/T-{date}-{slug}.json)
    |
    v
Checkpoint (/checkpoint updates thread)
    |
    v
Handoff (/handoff commits, updates INDEX, writes handoff.json)
    |
    v
Resume (new session reads handoff.json or specific thread)
```

### Thread Schema (thread-schema.md)

```json
{
  "thread_id": "T-YYYYMMDD-HHMMSS-slug",
  "version": 1,
  "created_at": "ISO8601",
  "updated_at": "ISO8601",
  "workspace_root": "/path/to/HQ",
  "cwd": "relative/path",
  "git": {
    "branch": "string",
    "remote_url": "string",
    "initial_commit": "sha",
    "current_commit": "sha",
    "commits_made": ["sha: message"],
    "dirty": false
  },
  "worker": {
    "id": "worker-id",
    "skill": "skill-name",
    "state": "idle|loading|executing|verifying|completed|error",
    "started_at": "ISO8601",
    "completed_at": "ISO8601"
  },
  "conversation_summary": "What happened",
  "files_touched": ["paths"],
  "next_steps": ["what remains"],
  "metadata": {
    "title": "Human-readable title",
    "tags": ["searchable", "tags"]
  }
}
```

### Desktop's Thread Access (current)

- `list_threads`: Reads `workspace/threads/*.json`, extracts `thread_id`, `created_at`, title (from `metadata.title`), `worker_id`, `worker_state`, `conversation_summary`. Sorts by `created_at` descending.
- `list_checkpoints`: Reads `workspace/checkpoints/*.json`, extracts `task_id`, `completed_at`, `summary`. Separate from threads.
- `start_threads_watcher` / `stop_threads_watcher`: Watches `workspace/threads/` for changes, emits `threads-changed` event.

**Gaps in Desktop thread handling:**
- No thread detail view (can list but not inspect full thread JSON)
- No thread-to-session linkage (can't resume work from a thread by opening a terminal pre-loaded with context)
- No thread search/filter (by tags, worker, date range, company)
- No thread timeline/history visualization
- No handoff.json display (the most recent handoff pointer is never surfaced in UI)
- No git state display from thread (branch, commits, dirty state)
- No next_steps display (the "what remains" field is captured but never shown)
- `list_checkpoints` and `list_threads` are separate, but modern HQ uses threads as superset of checkpoints

### Handoff Flow (as designed)

1. `/checkpoint` creates/updates a thread JSON with current state
2. `/handoff` commits dirty repos, updates `workspace/threads/recent.md` and INDEX files, writes `handoff.json` with pointer to latest thread
3. New session reads `handoff.json` (7 lines) to know where to resume
4. `handoff.json` contains: `created_at`, `message`, `last_thread`, `thread_path`, `context_notes`

**Desktop has NO handoff UI:**
- No "checkpoint" button in terminal header
- No "handoff" button
- No handoff notification when context is running low
- No auto-handoff trigger (CLAUDE.md mandates at 70% context usage)
- No session resume flow from handoff.json

## 5. Desktop Terminal Sessions vs Claude Code Sessions

### Two Separate Concepts

| Aspect | Desktop PTY Session | Claude Code Session |
|--------|-------------------|-------------------|
| Origin | `spawn_pty` in terminal.rs | Claude Code CLI (`claude` binary) |
| Storage | In-memory HashMap (volatile) | `.claude/projects/{path}/*.jsonl` |
| ID Format | UUID v4 | Claude's internal session ID |
| Lifecycle | App open -> app close | Persistent across CLI invocations |
| Content | Raw terminal I/O bytes | Structured JSONL (messages, tool calls) |
| Access | Direct PTY read/write | `list_claude_sessions` (read-only listing) |

### How They Currently Interact

1. Desktop spawns a PTY shell session
2. User (or session-launcher) types `claude "/run worker"` into the PTY
3. Claude Code starts inside the PTY, creates its own `.jsonl` session file
4. Desktop has no awareness that Claude is running inside the PTY -- it only sees raw terminal bytes
5. `list_claude_sessions` can separately enumerate Claude's `.jsonl` files, but there's no linkage to the PTY session that spawned them

### Integration Gaps

1. **No Claude session detection within PTY**: Desktop can't tell when Claude starts/stops inside a terminal tab
2. **No context meter**: Claude Code exposes remaining context via its status line, but Desktop doesn't parse terminal output to extract this
3. **No session continuation**: Can't click a Claude `.jsonl` session in Desktop to resume it in a new PTY
4. **No structured output extraction**: Claude Code outputs structured data (JSON results, back-pressure results), but Desktop only receives raw ANSI bytes
5. **No bidirectional communication**: Desktop can write bytes to PTY but can't send structured commands to Claude Code running inside
6. **Dual terminal problem**: `spawn_worker_skill` and command palette open macOS Terminal.app while session-launcher opens integrated PTY -- inconsistent

## 6. Gap Summary (Prioritized)

### Critical Gaps (Block core interactive use)

| # | Gap | Impact |
|---|-----|--------|
| G1 | Command palette executes in external Terminal.app, not integrated PTY | Commands launched from Desktop leave Desktop entirely |
| G2 | No session persistence (volatile in-memory) | All sessions lost on app restart or reload |
| G3 | 17 of 27 slash commands missing from palette | Users can only trigger 10 commands via Desktop |
| G4 | No command argument input | Commands needing args (most do) can't be invoked properly |

### High-Priority Gaps (Degrade experience significantly)

| # | Gap | Impact |
|---|-----|--------|
| G5 | No checkpoint/handoff buttons in terminal UI | Users must type commands manually |
| G6 | No context usage meter | No visual warning before context exhaustion |
| G7 | No thread resume flow | Can't start new session from handoff/thread state |
| G8 | No auto-handoff notification | Desktop can't warn when Claude session is nearing limit |
| G9 | `type: 'claude'` session type never used | No distinction between shell-with-Claude and plain shell |

### Medium-Priority Gaps (Missing features for power use)

| # | Gap | Impact |
|---|-----|--------|
| G10 | No search in terminal output | Can't find text in scrollback |
| G11 | No session history/log | Closed sessions disappear completely |
| G12 | No thread detail view | Can list threads but not inspect them |
| G13 | No handoff.json display in UI | Latest handoff context never surfaced |
| G14 | No cwd picker in session launcher | Always starts in HQ root |
| G15 | Worker company inference is fragile (substring) | Should use registry.yaml `company` field |

### Low-Priority Gaps (Polish and advanced features)

| # | Gap | Impact |
|---|-----|--------|
| G16 | No terminal split panes | Single terminal per tab |
| G17 | No output capture/export | Can't save terminal output to file |
| G18 | No Claude session <-> PTY linkage | Two separate worlds |
| G19 | No keyboard shortcuts for individual commands | Only Cmd+K for palette, Cmd+N for new session |
| G20 | Session launcher has no "New Claude Session" option | Only shell or worker |

## 7. Recommendations for Child PRD (US-017/US-018)

### Phase 1: Fix Command Execution Path
- Route command palette execution through integrated PTY instead of external Terminal.app
- Add argument input field to command palette for commands that need args
- Register all 27 slash commands in command palette

### Phase 2: Session Lifecycle
- Persist sessions to disk (survive restart)
- Add checkpoint/handoff buttons to terminal header
- Add context usage meter to terminal context bar
- Implement session resume from thread/handoff

### Phase 3: Claude Integration
- Detect Claude Code running inside PTY (parse terminal output for Claude prompt markers)
- Extract context usage percentage from Claude's status line
- Surface auto-handoff notification when context drops below 30%
- Link Claude `.jsonl` sessions to the PTY tab that spawned them

### Phase 4: Power Features
- Terminal search (xterm.js SearchAddon)
- Session history/log viewer
- Thread detail viewer with git state, next_steps, files_touched
- Terminal split panes
