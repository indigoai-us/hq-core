# Terminal & Session UX Specs

Detailed UX specifications for enhanced command palette, session tab bar, checkpoint/handoff controls, context usage meter, session resume flow, and auto-handoff notification. Built on the gap analysis from `terminal-session-audit.md` (US-016).

**Target repo:** `repos/private/hq-desktop`
**Addresses gaps:** G1-G9, G19-G20 from US-016 audit

---

## 1. Enhanced Command Palette

### 1.1 Full Command Registry (27 commands)

All 27 HQ slash commands registered with proper categories, descriptions, argument schemas, and icons.

**Categories expanded from 4 to 7:**

| Category | Label | Commands |
|----------|-------|----------|
| `worker` | Workers | `/run`, `/newworker` |
| `session` | Session | `/checkpoint`, `/handoff`, `/reanchor` |
| `project` | Projects | `/nexttask`, `/execute-task`, `/run-project`, `/plan`, `/pr` |
| `system` | System | `/cleanup`, `/metrics`, `/search`, `/search-reindex`, `/learn`, `/remember`, `/decide` |
| `content` | Content | `/contentidea`, `/generateimage` |
| `social` | Social | `/post-now`, `/preview-post`, `/scheduleposts`, `/suggestposts`, `/social-setup` |
| `email` | Email | `/checkemail`, `/email` |

### 1.2 Argument Input Mode

When a command requires arguments, the palette transitions to an argument input state instead of immediately executing.

**Flow:**

```
[User types in palette] -> [Select command] -> [Needs args?]
   |                                               |
   No                                             Yes
   |                                               |
   v                                               v
Execute immediately                    Show argument input field
                                               |
                                               v
                                       [User types args + Enter]
                                               |
                                               v
                                          Execute with args
```

**Argument-input state UI:**

```
┌──────────────────────────────────────────────┐
│ /execute-task ▸ [project/story-id          ] │
│                                              │
│  Examples:                                   │
│  · campaign-migration/CAM-003                │
│  · hq-desktop-epics/US-017                   │
│                                              │
│  [↵ execute]  [esc cancel]                   │
└──────────────────────────────────────────────┘
```

**Commands requiring arguments:**

| Command | Argument | Placeholder |
|---------|----------|-------------|
| `/run` | `{worker}` or `{worker}:{skill}` | `worker-id` or `worker:skill` |
| `/execute-task` | `{project}/{story-id}` | `project/STORY-001` |
| `/run-project` | `{project}` | `project-name` |
| `/plan` | `{project-name}` | `my-project` |
| `/newworker` | `{worker-id}` | `worker-name` |
| `/contentidea` | `{topic}` | `topic or brief` |
| `/search` | `{query}` | `search query` |
| `/email` | `{recipient}` | `email address or name` |
| `/learn` | (optional context) | `learning context` |
| `/remember` | `{rule}` | `rule to remember` |

Commands without arguments execute immediately on selection (current behavior).

### 1.3 Execution in Integrated PTY (Fixes G1)

**Critical change:** Commands execute in the active integrated PTY terminal tab, NOT in external Terminal.app via `spawn_worker_skill`.

**Execution logic:**

```typescript
async function executeInPTY(command: HQCommand, args?: string) {
  const sessionStore = useSessionStore.getState()
  let sessionId = sessionStore.activeSessionId

  // If no active session, spawn a new one
  if (!sessionId) {
    sessionId = await invoke<string>('spawn_pty', {
      cmd: null, cwd: null, cols: 120, rows: 30
    })
    sessionStore.addSession({
      id: sessionId,
      type: 'claude',
      cwd: '~/Documents/HQ',
      status: 'running',
      startedAt: new Date().toISOString(),
      title: `/${command.id}`,
    })
  }

  // Write the claude slash command into PTY
  const fullCommand = args
    ? `claude "/${command.id} ${args}"\n`
    : `claude "/${command.id}"\n`

  await invoke('write_pty', {
    sessionId,
    data: Array.from(new TextEncoder().encode(fullCommand)),
  })
}
```

**Behavior decisions:**
- If an active terminal tab exists and is idle (shell prompt visible), execute there
- If no terminal tabs exist, auto-spawn a new shell session first
- If active terminal is busy (Claude is running), spawn a new tab for the command
- Session `type` set to `'claude'` when launching a slash command (fixes G9)

### 1.4 Keyboard Shortcuts

**Global shortcuts** (work from any view, not just when palette is open):

| Shortcut | Action |
|----------|--------|
| `Cmd+K` | Toggle command palette (existing) |
| `Cmd+N` | New session (existing) |
| `Cmd+Shift+C` | Quick `/checkpoint` |
| `Cmd+Shift+H` | Quick `/handoff` |
| `Cmd+Shift+S` | Quick `/search` (opens palette pre-filled with /search) |
| `Cmd+1` through `Cmd+9` | Switch to terminal tab 1-9 |
| `Cmd+W` | Close active terminal tab |
| `Cmd+T` | New terminal tab (alias for Cmd+N) |

**In-palette shortcuts:**

| Shortcut | Action |
|----------|--------|
| `↑/↓` | Navigate commands (existing) |
| `↵` | Execute/select (existing) |
| `Esc` | Close palette or cancel arg input (existing) |
| `Tab` | Auto-complete command name from partial match |
| `Cmd+↵` | Execute in new tab (force new session) |

### 1.5 Recently Used Persistence

Current: `localStorage` only (lost on app reinstall).
Enhanced: Persist to `~/.hq-desktop/preferences.json` via Rust command for durability across reinstalls.

---

## 2. Session Tab Bar

### 2.1 Enhanced Tab Design

Extends current `TerminalTab` component with additional metadata and controls.

**Tab anatomy:**

```
┌─────────────────────────────────────────────┐
│ [●] [█] claude: /run architect  [ctx:72%] × │
│  │   │          │                 │        │ │
│  │   │          │                 │        │ │
│  │   │          └─ title          │        │ │
│  │   └─ company color bar        │        │ │
│  └─ status dot                   │        │ │
│                   context meter ──┘  close ┘ │
└─────────────────────────────────────────────┘
```

**New tab features:**
- **Context meter** (mini): Tiny bar or percentage showing remaining context (see section 3)
- **Session type indicator**: Icon varies by type -- Terminal icon for `shell`, Zap for `worker`, Bot for `claude`
- **Named sessions**: Double-click tab title to rename
- **Tab drag-to-reorder**: Drag tabs to rearrange order
- **Tab overflow**: When too many tabs, show `>>` dropdown with full list

### 2.2 Session Types (Fixes G9, G20)

Expand session launcher with three primary options:

```
┌─────────────────────────────────────────────┐
│  🔍 Search workers or launch session...     │
├─────────────────────────────────────────────┤
│  ▸ New Shell                                │
│    Open terminal in HQ directory            │
│                                             │
│  ▸ New Claude Session                       │
│    Start Claude Code in HQ context          │
│                                             │
│  ▸ Resume from Thread...                    │
│    Continue from a previous handoff         │
├─────────────────────────────────────────────┤
│  Workers                                    │
│  ▸ architect                                │
│  ▸ backend-dev                              │
│  ...                                        │
└─────────────────────────────────────────────┘
```

**"New Claude Session"** spawns a PTY and types `claude` (no arguments) to start an interactive Claude Code session. Sets `type: 'claude'`.

**"Resume from Thread"** opens the thread picker (see section 4).

### 2.3 Session Store Enhancements

New fields added to `TerminalSession`:

```typescript
interface TerminalSession {
  // Existing fields
  id: string
  type: SessionType           // 'worker' | 'claude' | 'shell'
  workerId?: string
  skillId?: string
  projectName?: string
  company?: string
  cwd: string
  status: SessionStatus       // 'running' | 'exited'
  startedAt: string
  exitCode?: number
  title: string

  // New fields
  contextUsage?: number       // 0-100, percentage of context used
  threadId?: string           // Linked HQ thread ID (T-YYYYMMDD-...)
  claudeSessionId?: string    // Claude Code's internal session ID
  customTitle?: string        // User-set name (overrides auto title)
  lastActivity?: string       // ISO8601 timestamp of last output
  isClaudeActive?: boolean    // Whether Claude Code is running inside this PTY
}
```

**Session persistence (Fixes G2):**
- On `addSession` / `updateSession` / `removeSession`, serialize session array to `~/.hq-desktop/sessions.json` via Rust command
- On app startup, load `sessions.json` and attempt to reconnect to surviving PTY processes (if any)
- Exited sessions kept in a `sessionHistory` array (last 50) for the session history panel

---

## 3. Context Usage Meter

### 3.1 Context Detection Strategy

Claude Code outputs a status line in its terminal output that includes remaining context information. Desktop must parse PTY output to extract this.

**Detection approach:**

1. In the `pty-output` event handler, scan output chunks for Claude's context status pattern
2. Regex pattern: `/context[:\s]+(\d+)%\s*remaining/i` or Claude's specific format
3. On match, update `session.contextUsage` in the session store
4. Fallback: If no status line detected, context meter shows "N/A"

**Alternative approach (more reliable):**
- Claude Code's JSONL session files at `.claude/projects/{path}/*.jsonl` may contain token usage data
- Periodically read the active JSONL file via Rust command and extract cumulative token usage
- Compare against model context window (200K tokens for Claude) to compute percentage

### 3.2 Context Meter Placements

The context meter appears in three locations with increasing detail:

**Location 1: Tab bar (mini)**
- Thin colored bar at the bottom edge of the tab
- Color gradient: green (0-50% used) -> yellow (50-70%) -> orange (70-85%) -> red (85-100%)
- Only visible for `type: 'claude'` sessions
- Width: proportional to usage (full tab width = 100% used)

```
┌──────────────────────────────┐
│ ● claude: /run architect   × │
│ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░ │  <- 55% used, yellow
└──────────────────────────────┘
```

**Location 2: Context bar (detailed)**
- In `TerminalContextBar` at bottom of terminal panel
- Shows percentage text + colored dot + visual bar

```
┌──────────────────────────────────────────────────────────┐
│ 👤 architect  🏢 {company}  📊 Context: 72% remaining │
│                                   ▓▓▓▓▓▓▓▓░░░░░░░░░░░░ │
└──────────────────────────────────────────────────────────┘
```

**Location 3: Stats header (aggregate)**
- In the empire view's stats header, show active Claude session count with aggregate context
- "2 Claude sessions | Lowest context: 28% remaining"

### 3.3 Color Thresholds

| Context Remaining | Color | Hex | Behavior |
|-------------------|-------|-----|----------|
| 100-50% | Green | `#51cf66` | Normal |
| 50-30% | Yellow | `#ffd43b` | Attention |
| 30-15% | Orange | `#ff922b` | Warning, auto-handoff toast triggered at 30% |
| 15-0% | Red | `#ff6b6b` | Critical, pulsing animation |

---

## 4. Session Resume Flow

### 4.1 Thread Picker

Accessed from "Resume from Thread..." in the session launcher.

**Thread picker UI:**

```
┌──────────────────────────────────────────────────────────┐
│  🔍 Search threads...                              [×]  │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  Latest Handoff                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │ T-20260212-043000-{product}-deploy                       │  │
│  │ "Fixed SST deploy config for {PRODUCT} runtime"          │  │
│  │ 🏢 {company}  👤 backend-dev  🕐 2h ago         │  │
│  │ Next: Run smoke tests on staging                   │  │
│  │                           [Resume in New Tab →]    │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  Recent Threads                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │ Next: Review report, publish to CMO HQ             │  │
│  │                           [Resume in New Tab →]    │  │
│  └────────────────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────────────────┐  │
│  │ T-20260211-180000-{company}-billing                   │  │
│  │ "Closed 18 billing issues in GitHub"               │  │
│  │ 🏢 {company}  🕐 12h ago                              │  │
│  │                           [Resume in New Tab →]    │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

**Data source:** `workspace/threads/*.json` via existing `list_threads` Rust command + `handoff.json` for the latest handoff pointer.

### 4.2 Resume Flow

When user clicks "Resume in New Tab":

```
1. Read thread JSON for context
2. Spawn new PTY session
3. Set session metadata:
   - type: 'claude'
   - threadId: thread.thread_id
   - workerId: thread.worker?.id
   - company: inferred from thread
   - title: thread.metadata.title or thread_id
4. Write claude command into PTY:
   claude --resume "Read workspace/threads/{thread_path} and continue: {thread.next_steps[0]}"
5. Focus the new tab
```

**Resume prompt construction:**

```typescript
function buildResumeCommand(thread: ThreadJSON): string {
  const parts = ['claude']

  // Build a prompt that gives Claude the thread context
  const prompt = [
    `Read the thread at workspace/threads/${thread.thread_id}.json.`,
    thread.conversation_summary ? `Previous work: ${thread.conversation_summary}` : '',
    thread.next_steps?.length ? `Continue with: ${thread.next_steps[0]}` : 'Review thread and continue.',
  ].filter(Boolean).join(' ')

  return `${parts.join(' ')} "${prompt}"\n`
}
```

### 4.3 Handoff.json Quick Resume

In the empire view or terminal empty state, show a persistent "Resume Last Handoff" card if `workspace/threads/handoff.json` exists and is recent (< 24h).

```
┌─────────────────────────────────────────────┐
│  ↪ Resume Last Handoff                      │
│                                             │
│  "Fixed SST deploy config for {PRODUCT} runtime"  │
│  2 hours ago · {company}                  │
│                                             │
│  Next: Run smoke tests on staging           │
│                                             │
│  [Resume →]                                 │
└─────────────────────────────────────────────┘
```

---

## 5. Checkpoint & Handoff Controls

### 5.1 Terminal Header Buttons

Add checkpoint and handoff buttons to the terminal context bar (bottom of terminal panel). These appear only when a Claude session is detected as active (`isClaudeActive: true`).

**Updated context bar layout:**

```
┌──────────────────────────────────────────────────────────────────────┐
│ 👤 architect:system-design  🏢 {company}  📊 72%  [💾 Checkpoint] [↗ Handoff] │
└──────────────────────────────────────────────────────────────────────┘
```

**Button specs:**

| Button | Icon | Label | Action | Shortcut |
|--------|------|-------|--------|----------|
| Checkpoint | `Save` (lucide) | Checkpoint | Types `/checkpoint` into active PTY | `Cmd+Shift+C` |
| Handoff | `ArrowUpRight` (lucide) | Handoff | Types `/handoff` into active PTY | `Cmd+Shift+H` |

**Button states:**
- **Default**: Glass button with white/40 text, white/6 background
- **Hover**: white/70 text, white/10 background
- **Active** (command sent): Brief pulse animation + "Sent" text for 2 seconds
- **Disabled**: When session status is 'exited' or no Claude detected

### 5.2 Confirmation for Handoff

Handoff is a session-ending action (commits repos, writes final state). Show a brief confirmation:

```
┌──────────────────────────────────────┐
│  Hand off this session?              │
│                                      │
│  This will:                          │
│  · Save current thread state         │
│  · Commit dirty repos                │
│  · Write handoff pointer             │
│                                      │
│  [Cancel]  [Hand Off →]              │
└──────────────────────────────────────┘
```

Checkpoint does NOT need confirmation (non-destructive).

### 5.3 Post-Handoff State

After handoff completes (detected by parsing PTY output for handoff completion markers):
- Tab title updates to "{title} (handed off)"
- Status dot changes to blue
- Context bar shows: "Session handed off. Start new session or resume."
- Auto-suggest: "Resume from this handoff?" button appears

---

## 6. Auto-Handoff Notification

### 6.1 Trigger Conditions

Auto-handoff toast fires when:
- Context remaining drops to 30% or below (matching CLAUDE.md rule)
- Session type is `'claude'` and `isClaudeActive` is true
- Toast has not already been shown for this session (one-time per session, re-arms if context recovers above 35%)

### 6.2 Toast Design

**Position:** Top-right of the Desktop window, above terminal content. Slides in from right.

**Anatomy:**

```
┌─────────────────────────────────────────────┐
│  ⚠ Context Running Low                      │
│                                             │
│  Session "architect:system-design" is at    │
│  28% context remaining.                     │
│                                             │
│  Claude will auto-handoff soon, or you can  │
│  trigger it now to preserve continuity.     │
│                                             │
│  [Dismiss]  [Handoff Now →]                 │
│                                             │
│  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░  72%     │
└─────────────────────────────────────────────┘
```

**Visual treatment:**
- Glass card with orange/amber border glow (`border: 1px solid rgba(255, 146, 43, 0.4)`)
- Warm gradient background: `linear-gradient(135deg, rgba(255,146,43,0.08), rgba(30,30,30,0.95))`
- Auto-dismiss after 30 seconds if user doesn't interact
- "Handoff Now" button types `/handoff` into the relevant PTY session

### 6.3 Escalation

If context drops below 15%:
- Toast changes to red/critical styling
- Toast becomes persistent (no auto-dismiss)
- Text: "Context critically low (12% remaining). Handoff immediately to avoid data loss."
- Sound: System alert sound (via `NSSound` via Tauri)

### 6.4 macOS System Notification (Optional)

When Desktop is not in focus and context drops below 30%:
- Fire a macOS notification via Tauri's notification API
- Title: "HQ: Context Running Low"
- Body: "Session '{title}' at {remaining}% context. Click to handoff."
- Click action: Bring Desktop to front, focus the relevant tab

---

## 7. Component Architecture

### 7.1 New Components

| Component | File | Purpose |
|-----------|------|---------|
| `CommandArgumentInput` | `components/command-palette.tsx` | Inline arg input when command needs params |
| `ContextMeter` | `components/terminal/context-meter.tsx` | Reusable context % display (bar, text, dot) |
| `ContextMeterMini` | `components/terminal/context-meter.tsx` | Tiny version for tab bar |
| `CheckpointButton` | `components/terminal/terminal-controls.tsx` | Glass button that sends /checkpoint |
| `HandoffButton` | `components/terminal/terminal-controls.tsx` | Glass button with confirm dialog |
| `HandoffConfirmDialog` | `components/terminal/terminal-controls.tsx` | Confirmation modal for handoff |
| `AutoHandoffToast` | `components/terminal/auto-handoff-toast.tsx` | Warning toast for low context |
| `ThreadPicker` | `components/terminal/thread-picker.tsx` | Modal for selecting thread to resume |
| `ThreadPickerCard` | `components/terminal/thread-picker.tsx` | Individual thread in picker list |
| `HandoffResumeCard` | `components/terminal/handoff-resume-card.tsx` | Quick resume from latest handoff |
| `SessionTypeSelector` | `components/terminal/session-launcher.tsx` | Enhanced launcher with Shell/Claude/Resume options |

### 7.2 Modified Components

| Component | File | Changes |
|-----------|------|---------|
| `CommandPalette` | `components/command-palette.tsx` | Add all 27 commands, arg input mode, PTY execution, new categories |
| `TerminalTab` | `components/terminal/terminal-header.tsx` | Add context meter mini, type icon, rename on double-click |
| `TerminalContextBar` | `components/terminal/terminal-header.tsx` | Add context meter, checkpoint/handoff buttons |
| `TerminalPanel` | `components/terminal/terminal-panel.tsx` | Add handoff resume card in empty state, tab reordering |
| `SessionLauncher` | `components/terminal/session-launcher.tsx` | Add "New Claude Session" and "Resume from Thread" options |
| `useTerminal` | `hooks/use-terminal.ts` | Add context usage parsing from PTY output |
| `useSessionStore` | `stores/session-store.ts` | Add new fields, persistence, session history |

### 7.3 New Hooks

| Hook | File | Purpose |
|------|------|---------|
| `useContextMeter` | `hooks/use-context-meter.ts` | Parses PTY output for context %, manages thresholds |
| `useAutoHandoff` | `hooks/use-auto-handoff.ts` | Monitors context across sessions, fires toast at 30% |
| `useSessionPersistence` | `hooks/use-session-persistence.ts` | Saves/loads sessions via Rust commands |
| `useHandoff` | `hooks/use-handoff.ts` | Reads `handoff.json`, provides latest handoff data |

### 7.4 New Rust Commands Needed

| Command | Signature | Purpose |
|---------|-----------|---------|
| `save_sessions` | `(sessions: Vec<SessionData>) -> ()` | Persist sessions to `~/.hq-desktop/sessions.json` |
| `load_sessions` | `() -> Vec<SessionData>` | Load persisted sessions on startup |
| `read_handoff` | `() -> Option<HandoffData>` | Read `workspace/threads/handoff.json` |
| `save_preferences` | `(prefs: Preferences) -> ()` | Persist preferences (recent commands, etc.) |
| `load_preferences` | `() -> Preferences` | Load preferences on startup |

---

## 8. Interaction Patterns Summary

### 8.1 Command Execution (New Flow)

```
User presses Cmd+K
  → Palette opens with all 27 commands
  → User types to filter
  → User selects command
    → Command needs args?
      → YES: Show inline arg input, user types args, presses Enter
      → NO: Execute immediately
    → Execute in active PTY tab (or spawn new if none/busy)
    → Palette closes
    → Terminal tab activates and shows Claude running the command
```

### 8.2 Session Lifecycle (New Flow)

```
User opens new session
  → Choose: Shell / Claude / Worker / Resume from Thread
    → Shell: Spawn PTY with login shell
    → Claude: Spawn PTY, type `claude` to start interactive session
    → Worker: Spawn PTY, type `claude "/run {worker}"` (existing)
    → Resume: Open thread picker, select thread, spawn PTY with resume prompt
  → Tab appears in tab bar
  → User works in terminal
  → Context meter updates as Claude runs
  → At 30% remaining: auto-handoff toast
  → User clicks Checkpoint or Handoff button
  → On handoff: tab marked as handed off
  → Tab kept in history on close
```

### 8.3 Thread Resume (New Flow)

```
User clicks "Resume from Thread" in session launcher
  → Thread picker opens
  → Shows latest handoff prominently + recent threads
  → User can filter by company, search by title
  → User clicks "Resume in New Tab"
  → New PTY tab opens
  → Claude starts with thread context pre-loaded
  → Tab linked to thread via threadId
```

---

## 9. Design Tokens (Glass Theme Alignment)

All new components follow the existing glass card design system from `glass-card.tsx` and `ui-component-audit.md`.

### Buttons (Terminal Controls)

```css
/* Default */
background: linear-gradient(135deg, rgba(255,255,255,0.06) 0%, rgba(255,255,255,0.02) 100%);
border: 1px solid rgba(255,255,255,0.08);
color: rgba(255,255,255,0.5);
border-radius: 8px;
font-size: 11px;
padding: 4px 10px;

/* Hover */
background: linear-gradient(135deg, rgba(255,255,255,0.1) 0%, rgba(255,255,255,0.05) 100%);
color: rgba(255,255,255,0.8);

/* Active (pulsing after click) */
border-color: rgba(81, 207, 102, 0.3);   /* checkpoint = green */
border-color: rgba(116, 192, 252, 0.3);  /* handoff = blue */
```

### Toast (Auto-Handoff)

```css
/* Warning (30%) */
background: linear-gradient(135deg, rgba(255,146,43,0.06) 0%, rgba(30,30,30,0.95) 100%);
border: 1px solid rgba(255,146,43,0.3);
box-shadow: 0 8px 32px rgba(0,0,0,0.4), 0 0 20px rgba(255,146,43,0.05);

/* Critical (15%) */
background: linear-gradient(135deg, rgba(255,107,107,0.08) 0%, rgba(30,30,30,0.95) 100%);
border: 1px solid rgba(255,107,107,0.4);
animation: pulse 2s ease-in-out infinite;
```

### Context Meter Bar

```css
/* Track */
background: rgba(255,255,255,0.06);
height: 3px;
border-radius: 1.5px;

/* Fill */
background: var(--context-color);  /* green/yellow/orange/red per thresholds */
height: 3px;
border-radius: 1.5px;
transition: width 1s ease, background-color 0.5s ease;
```

---

## 10. Accessibility Notes

- All new buttons have ARIA labels: `aria-label="Save checkpoint"`, `aria-label="Hand off session"`
- Context meter has `role="meter"` with `aria-valuenow`, `aria-valuemin="0"`, `aria-valuemax="100"`, `aria-label="Context remaining"`
- Toast uses `role="alert"` for screen reader announcement
- Tab bar supports full keyboard navigation (arrow keys to switch, Cmd+W to close)
- Color coding always paired with text labels (never color-only information)
- Focus trap in modals (thread picker, handoff confirmation)
