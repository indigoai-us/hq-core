# Notification & Event System Specs

> US-020: Detailed specs for the notification center, event stream, toast system, badge counts, and file watcher architecture. Builds on the event sources inventory from US-019.

## 1. File Watcher Architecture

### 1.1 Current State

Desktop has two independent file watchers sharing a single `FileWatcherState` mutex, plus a 2-second polling interval for orchestrator state. The shared mutex means `start_threads_watcher` overwrites `start_prd_watcher`'s handle, silently killing the PRD watcher. No notification infrastructure exists on either the Rust or React side.

### 1.2 WatcherManager (Rust-Side)

Replace the single `FileWatcherState` struct with a centralized `WatcherManager` that owns all watchers independently.

```rust
use std::collections::HashMap;
use notify::RecommendedWatcher;
use std::sync::Mutex;

pub struct WatcherManager {
    watchers: HashMap<String, RecommendedWatcher>,
}

impl Default for WatcherManager {
    fn default() -> Self {
        Self { watchers: HashMap::new() }
    }
}

impl WatcherManager {
    pub fn register(&mut self, id: String, watcher: RecommendedWatcher) {
        // Drop any previous watcher with same ID (stops watching)
        self.watchers.insert(id, watcher);
    }

    pub fn unregister(&mut self, id: &str) -> bool {
        self.watchers.remove(id).is_some()
    }

    pub fn is_active(&self, id: &str) -> bool {
        self.watchers.contains_key(id)
    }

    pub fn active_ids(&self) -> Vec<String> {
        self.watchers.keys().cloned().collect()
    }
}
```

Register as Tauri managed state in `lib.rs`:
```rust
.manage(Mutex::new(WatcherManager::default()))
```

Remove `FileWatcherState` and `ThreadsWatcherState` entirely.

### 1.3 Watcher Definitions

Six scoped watchers, each with dedicated debounce and event types.

| ID | Watch Path (relative to HQ) | Recursive | Debounce | File Filter | Events Emitted |
|----|----------------------------|-----------|----------|-------------|----------------|
| `workspace` | `workspace/` | Yes | 300ms | `*.json`, `*.md` | `hq://thread-created`, `hq://thread-updated`, `hq://handoff-changed`, `hq://checkpoint-created`, `hq://learning-captured`, `hq://report-created` |
| `projects` | `projects/` | Yes | 500ms | `prd.json`, `executions/*.json` | `hq://prd-changed`, `hq://execution-changed` |
| `workers` | `workers/` | Yes | 1000ms | `registry.yaml`, `worker.yaml` | `hq://registry-changed`, `hq://worker-updated` |
| `companies` | `companies/` | Depth 2 | 1000ms | `manifest.yaml`, any | `hq://manifest-changed`, `hq://company-changed` |
| `knowledge` | `knowledge/` | Yes | 2000ms | `*.md` | `hq://knowledge-changed` |
| `claude-sessions` | `~/.claude/projects/-Users-*` | No | 1000ms | `*.jsonl` | `hq://claude-session-changed` |

### 1.4 Unified Tauri Command

Replace per-watcher `start_*_watcher` / `stop_*_watcher` commands with a single pair:

```rust
#[tauri::command]
pub fn start_watcher(app: AppHandle, watcher_id: String) -> Result<(), String>;

#[tauri::command]
pub fn stop_watcher(app: AppHandle, watcher_id: String) -> Result<(), String>;

#[tauri::command]
pub fn list_active_watchers(app: AppHandle) -> Result<Vec<String>, String>;
```

The `start_watcher` command looks up the watcher definition by ID, creates the `RecommendedWatcher` with the correct path, recursive mode, and debounce, then registers it in `WatcherManager`.

### 1.5 Event Pipeline (Rust to React)

```
filesystem change
  -> notify::Event (raw)
  -> debounce window (per watcher config)
  -> path classification (which subdirectory changed?)
  -> payload construction (parse changed file if needed)
  -> Tauri emit (typed event name + JSON payload)
  -> React event listener (useEffect + listen())
  -> notification dispatch (toast/badge/silent based on event tier)
  -> state refresh (invoke Tauri command to re-fetch data)
```

### 1.6 Typed Event Payloads

Every Tauri event carries a typed payload (no more empty `()` payloads):

```rust
#[derive(Debug, Serialize, Clone)]
pub struct HqEvent {
    pub event_type: String,       // e.g. "thread-created"
    pub source_path: String,      // absolute path that changed
    pub relative_path: String,    // path relative to HQ root
    pub timestamp: String,        // ISO 8601
    pub watcher_id: String,       // which watcher detected this
    pub payload: Option<serde_json::Value>,  // parsed content if applicable
}
```

For high-value events (PRD changes, thread creation), the payload includes parsed content. For bulk events (knowledge edits), payload is `None` -- the frontend refetches on demand.

### 1.7 Debounce & Coalescing

Implement debounce in the watcher callback using a channel-based approach:

```rust
// Per watcher: spawn a debounce thread
// Watcher callback sends raw events to channel
// Debounce thread collects events over the debounce window
// After window expires, coalesces events by path (dedup same-file events)
// Emits single HqEvent per unique file changed
```

Coalescing rules:
1. **Same-file dedup**: Multiple modifications to the same file within the debounce window emit one event (latest timestamp)
2. **Batch threshold**: When >5 events fire in one debounce window, emit a single `hq://batch-update` event with an array of affected paths instead of individual events
3. **Payload-aware filtering** (PRD watcher only): Parse prd.json before and after; only emit if `passes` count or story list actually changed

---

## 2. Notification Priority Levels

### 2.1 Level Definitions

| Level | Name | Icon | Color | Duration | Sound | Native |
|-------|------|------|-------|----------|-------|--------|
| 1 | `info` | Info circle | `rgba(147, 197, 253, 0.9)` (blue) | 4s auto-dismiss | None | No |
| 2 | `success` | Check circle | `rgba(134, 239, 172, 0.9)` (green) | 5s auto-dismiss | None | No |
| 3 | `warning` | Alert triangle | `rgba(253, 224, 71, 0.9)` (yellow) | 8s auto-dismiss | None | Optional |
| 4 | `attention-required` | Bell ring | `rgba(252, 165, 165, 0.9)` (red) | Sticky until dismissed | System alert | Yes |

### 2.2 Event-to-Level Mapping

| Event | Level | Notification Text Template |
|-------|-------|---------------------------|
| `thread-created` | `info` | "Thread created: {title}" |
| `thread-updated` | silent | (no notification) |
| `handoff-changed` | `success` | "Session handed off. Context preserved." |
| `checkpoint-created` | `info` | "Checkpoint saved: {summary}" |
| `learning-captured` | silent | (no notification) |
| `report-created` | `success` | "New report: {filename}" |
| `prd-changed` (story completed) | `success` | "Story {id} completed in {project}" |
| `prd-changed` (other) | silent | (no notification) |
| `execution-changed` | silent | (no notification) |
| `registry-changed` | `info` | "Worker registry updated" |
| `worker-updated` | silent | (no notification) |
| `manifest-changed` | `info` | "Company manifest updated" |
| `company-changed` | silent | (no notification) |
| `knowledge-changed` | silent | (no notification) |
| `claude-session-changed` | silent | (no notification) |
| `batch-update` | silent | (no notification) |
| `auto-handoff-warning` | `attention-required` | "Context at {pct}% remaining. Auto-handoff imminent." |
| `project-blocked` | `warning` | "Project {name} blocked: {reason}" |
| `back-pressure-failure` | `attention-required` | "Back pressure failed in {worker}: {check}" |

---

## 3. Toast System

### 3.1 Visual Design

Toasts appear as floating glass cards in the bottom-right corner, stacking upward. They match the Desktop's liquid glass aesthetic.

```
+--------------------------------------------------+
|  [icon]  Toast title text                    [x]  |
|          Optional secondary line                  |
+--------------------------------------------------+
```

**Styling (glass card variant):**
```css
.toast {
  background: linear-gradient(135deg, rgba(255,255,255,0.08) 0%, rgba(255,255,255,0.03) 100%);
  backdrop-filter: blur(30px) saturate(160%);
  -webkit-backdrop-filter: blur(30px) saturate(160%);
  border: 1px solid rgba(255,255,255,0.10);
  border-radius: 16px;
  box-shadow: 0 8px 32px rgba(0,0,0,0.25), inset 0 1px 0 rgba(255,255,255,0.06);
  padding: 12px 16px;
  min-width: 320px;
  max-width: 420px;
}
```

**Left accent stripe**: 3px wide vertical bar in the level color, rounded on the left side.

### 3.2 Animation

- **Enter**: Slide in from right (translateX(100%) to translateX(0)), 300ms ease-out, with subtle opacity fade (0 to 1)
- **Exit**: Slide out to right (translateX(0) to translateX(100%)), 200ms ease-in, with opacity fade (1 to 0)
- **Stack shift**: When a new toast pushes existing toasts up, animate with translateY, 200ms ease-in-out
- **Progress bar** (for auto-dismiss toasts): Thin 2px bar at the bottom of the toast, shrinking from full width to 0 over the dismiss duration. Color matches the level color at 30% opacity. Pauses on hover.

### 3.3 Behavior

- **Stacking**: Maximum 4 visible toasts. If a 5th arrives, the oldest auto-dismisses immediately
- **Hover pause**: Hovering over a toast pauses its auto-dismiss timer. All stacked toasts pause together
- **Click action**: Clicking a toast's body (not the X) navigates to the relevant view (e.g., clicking a "Story completed" toast navigates to the project detail view)
- **Dismiss**: Click the X button or swipe right (trackpad gesture)
- **Persistent toasts** (attention-required): No auto-dismiss, no progress bar. Must be manually dismissed or resolved

### 3.4 React Component API

```typescript
interface Toast {
  id: string;
  level: 'info' | 'success' | 'warning' | 'attention-required';
  title: string;
  body?: string;
  icon?: React.ReactNode;
  duration?: number; // ms, 0 = sticky
  action?: {
    label: string;
    onClick: () => void;
  };
  onDismiss?: () => void;
  navigateTo?: string; // drill path to navigate on click
}

interface ToastContextValue {
  toasts: Toast[];
  addToast: (toast: Omit<Toast, 'id'>) => string;
  dismissToast: (id: string) => void;
  dismissAll: () => void;
  pauseAll: () => void;
  resumeAll: () => void;
}
```

### 3.5 ToastProvider

Wrap the app in `<ToastProvider>` at the root level. The provider manages toast state and renders the toast container as a portal.

```tsx
<ToastProvider maxVisible={4} position="bottom-right">
  <App />
</ToastProvider>
```

---

## 4. Badge Count System

### 4.1 Badge Placement

Badges appear on navigation items in the sidebar / empire overview cards to indicate unread or new items since last viewed.

| Nav Item / Card | Badge Source | Reset Trigger |
|-----------------|-------------|---------------|
| Threads | Count of threads created since last threads view visit | User navigates to threads list |
| Projects | Count of stories completed since last projects view visit | User navigates to projects list |
| Checkpoints | Count of checkpoints created since last checkpoints view visit | User navigates to checkpoints list |
| Reports | Count of reports created since last reports view visit | User navigates to reports list |
| Workers | No badge (changes too rare to track) | N/A |
| Knowledge | No badge (changes too frequent, would be noisy) | N/A |

### 4.2 Badge State Management

```typescript
interface BadgeState {
  // Key: entity type (threads, projects, checkpoints, reports)
  // Value: { count, lastViewedAt }
  [key: string]: {
    count: number;
    lastViewedAt: string; // ISO 8601
  };
}
```

**Storage**: Persist in `localStorage` so badge counts survive app restarts. Key: `hq-desktop-badges`.

**Increment logic**: When a file watcher event fires for a watched entity type, compare the event timestamp against `lastViewedAt`. If the event is newer, increment the count.

**Reset logic**: When the user navigates to the relevant view, set `lastViewedAt` to `now()` and `count` to 0.

### 4.3 Badge Visual Design

```
  +----+
  | 3  |    <- red/blue circle with count
  +----+
```

- **Position**: Top-right of the nav item icon, overlapping by 4px
- **Size**: 18px diameter (single digit), auto-width for 2+ digits with 6px horizontal padding
- **Background**: For attention-required items, use `rgba(239, 68, 68, 0.9)` (red). For informational, use `rgba(96, 165, 250, 0.8)` (blue)
- **Text**: 11px, white, font-weight 600
- **Animation**: Scale-in from 0 to 1 with a subtle bounce (transform: scale, 300ms spring easing) when count increases
- **Max display**: Show "9+" for counts above 9

### 4.4 React Hook

```typescript
interface UseBadgesReturn {
  getBadgeCount: (entity: string) => number;
  incrementBadge: (entity: string) => void;
  resetBadge: (entity: string) => void;
  totalUnread: number;
}

function useBadges(): UseBadgesReturn;
```

---

## 5. Notification Center (Panel)

### 5.1 Purpose

A persistent, scrollable panel showing the history of all notifications and events. Accessible via a bell icon in the app header or a keyboard shortcut.

### 5.2 Information Architecture

```
Notification Center
+--------------------------------------------------+
| [Bell icon] Notifications          [Mark all read] |
| [All] [Unread] [Filter v]                         |
+--------------------------------------------------+
| Today                                              |
|                                                    |
| [icon] Story US-020 completed         2 min ago    |
|        hq-desktop-epics                            |
|                                                    |
| [icon] Checkpoint saved               15 min ago   |
|        tam-automation progress                     |
|                                                    |
| [icon] Thread created                 1 hr ago     |
|        {company}-gtm dashboard deploy            |
|                                                    |
| Yesterday                                          |
|                                                    |
| [icon] Session handed off             18 hr ago    |
|        Context at 28% remaining                    |
|                                                    |
+--------------------------------------------------+
```

### 5.3 Data Model

```typescript
interface Notification {
  id: string;
  type: string;          // matches HqEvent.event_type
  level: 'info' | 'success' | 'warning' | 'attention-required';
  title: string;
  body?: string;
  timestamp: string;     // ISO 8601
  read: boolean;
  source_path?: string;  // file that triggered this
  navigateTo?: string;   // drill path for click-through
  metadata?: Record<string, unknown>; // event-specific data
}
```

### 5.4 Storage

**In-memory ring buffer**: Keep the most recent 200 notifications in React state. Older notifications are dropped (no persistence across app restarts for v1).

**Future consideration**: Persist to a local SQLite database via `tauri-plugin-sql` for full history, search, and filtering. Not required for initial implementation.

### 5.5 Filtering & Grouping

- **Tabs**: All | Unread
- **Filter dropdown**: By level (info, success, warning, attention-required) and by source (threads, projects, workers, system)
- **Time grouping**: Group by "Today", "Yesterday", "This Week", "Older"
- **Unread indicator**: Blue dot on the left side of unread notifications

### 5.6 Interactions

- **Click notification**: Navigate to relevant view (same as toast click-through). Mark as read
- **Mark all read**: Button in the header. Resets all unread indicators and badge counts
- **Dismiss**: Swipe left to dismiss a single notification from history
- **Panel toggle**: Click bell icon or press `Cmd+N` to open/close the panel
- **Panel position**: Slides in from the right edge, overlaying the main content. Width: 380px. Same glass card styling as the rest of the app.

### 5.7 Bell Icon Badge

The bell icon in the app header shows the total unread count as a badge. This is the sum of all unread notifications, not the per-entity badges on nav items.

---

## 6. Event Stream (Real-Time Log)

### 6.1 Purpose

A developer-facing real-time log of all file system events, useful for debugging and monitoring HQ activity. Separate from the notification center (which is user-facing and curated).

### 6.2 Access

Available as a tab in the terminal panel or as a toggleable overlay. Not visible by default -- power-user feature.

### 6.3 Display Format

```
[18:04:23.456] workspace    thread-created     workspace/threads/T-20260211-test.json
[18:04:24.001] projects     prd-changed        projects/hq-desktop-epics/prd.json
[18:04:24.502] workspace    checkpoint-created  workspace/checkpoints/cp-001.json
[18:05:01.200] workspace    batch-update       3 files in workspace/
[18:05:03.100] workers      worker-updated     workers/public/dev-team/architect/worker.yaml
```

Each line:
- Timestamp (HH:MM:SS.mmm)
- Watcher ID (color-coded)
- Event type
- Relative file path

### 6.4 Features

- **Auto-scroll**: Locked to bottom by default. Unlocks when user scrolls up, re-locks when user scrolls to bottom
- **Pause**: Toggle button to freeze the stream (events still buffered, displayed when resumed)
- **Filter**: Text input to filter by path pattern or event type
- **Clear**: Button to clear the visible log
- **Max lines**: Keep 500 lines in the visible buffer. Older lines scroll out

### 6.5 React Hook

```typescript
interface EventLogEntry {
  id: string;
  timestamp: string;
  watcher_id: string;
  event_type: string;
  relative_path: string;
  payload?: unknown;
}

interface UseEventStreamReturn {
  entries: EventLogEntry[];
  paused: boolean;
  setPaused: (paused: boolean) => void;
  clear: () => void;
  filter: string;
  setFilter: (filter: string) => void;
}

function useEventStream(): UseEventStreamReturn;
```

---

## 7. macOS Native Notification Integration

### 7.1 Plugin

Use `tauri-plugin-notification` (Tauri v2 official plugin). Add to `Cargo.toml`:

```toml
tauri-plugin-notification = "2"
```

And register in `lib.rs`:
```rust
.plugin(tauri_plugin_notification::init())
```

### 7.2 When to Use Native Notifications

Native macOS notifications are sent **only** when:
1. The Desktop window is **not focused** (app is in background or minimized)
2. The notification level is `warning` or `attention-required`

This prevents duplicate notifications (in-app toast + native notification) during normal use.

### 7.3 Configuration

User-configurable in a future settings panel. Default: enabled for `attention-required` only.

```typescript
interface NotificationSettings {
  nativeNotificationsEnabled: boolean;
  nativeLevels: ('warning' | 'attention-required')[]; // which levels trigger native
  soundEnabled: boolean;
}
```

Store in `localStorage` key `hq-desktop-notification-settings`.

### 7.4 Native Notification Content

```typescript
// From Rust via tauri-plugin-notification
notification.title = "HQ Desktop";
notification.body = toast.title + (toast.body ? `: ${toast.body}` : '');
notification.icon = None; // Use default app icon
```

Clicking the native notification brings the Desktop window to focus.

---

## 8. React Integration Architecture

### 8.1 Event Bus Hook

Central hook that bridges Tauri events to React state:

```typescript
function useHqEvents(): void {
  // On mount: start all 6 watchers via invoke('start_watcher', { watcher_id })
  // Listen to all hq:// events via listen()
  // For each event:
  //   1. Dispatch to notification system (addToast if mapped, always add to notification center)
  //   2. Dispatch to badge system (incrementBadge for relevant entity)
  //   3. Dispatch to event stream (append to log)
  //   4. Trigger data refresh for affected hooks (invalidate relevant queries)
  // On unmount: stop all watchers
}
```

### 8.2 Data Refresh Dispatch

When an event fires, the event bus triggers selective data refreshes:

| Event | Hooks to Refresh |
|-------|-----------------|
| `thread-created`, `thread-updated`, `handoff-changed` | `useThreads` |
| `prd-changed` | `usePrd`, `useEmpireData` |
| `execution-changed` | `useOrchestrator` |
| `checkpoint-created` | `useThreads` (checkpoints) |
| `registry-changed`, `worker-updated` | `useWorkers`, `useEmpireData` |
| `company-changed`, `manifest-changed` | `useEmpireData` |
| `claude-session-changed` | `useEmpireData` |
| `report-created` | (future reports hook) |

Use a simple pub/sub pattern or React context to trigger refreshes without tight coupling.

### 8.3 Component Tree

```
<App>
  <ToastProvider>
    <NotificationProvider>
      <BadgeProvider>
        <HqEventBridge />     <!-- starts watchers, routes events -->
        <Layout>
          <Sidebar>
            <NavItem badge={useBadges().getBadgeCount('threads')} />
            <NavItem badge={useBadges().getBadgeCount('projects')} />
          </Sidebar>
          <Header>
            <NotificationBell count={totalUnread} onClick={togglePanel} />
          </Header>
          <MainContent />
          <NotificationPanel />   <!-- slides in from right -->
          <ToastContainer />      <!-- portal, bottom-right -->
        </Layout>
      </BadgeProvider>
    </NotificationProvider>
  </ToastProvider>
</App>
```

---

## 9. Banner System (Persistent Alerts)

### 9.1 Purpose

Banners are for critical, persistent information that should not auto-dismiss and should remain visible until the user acknowledges or the condition resolves.

### 9.2 Placement

Full-width bar at the top of the main content area, below the header. Pushes content down (not an overlay).

### 9.3 Banner Types

| Type | Color | Condition | Auto-Resolve |
|------|-------|-----------|--------------|
| `auto-handoff` | Yellow/amber | `handoff-changed` event detected | Yes (when new session starts) |
| `project-blocked` | Red | Project state changes to BLOCKED | Yes (when unblocked) |
| `back-pressure-failure` | Red | Back pressure check fails during execution | No (manual dismiss) |
| `watcher-error` | Orange | File watcher fails to start or crashes | Yes (when watcher restarts) |

### 9.4 Visual Design

```css
.banner {
  background: linear-gradient(90deg, rgba(253,224,71,0.12) 0%, rgba(253,224,71,0.04) 100%);
  border-bottom: 1px solid rgba(253,224,71,0.15);
  padding: 10px 16px;
  display: flex;
  align-items: center;
  gap: 12px;
}
```

Icon on the left, message text in the center, dismiss/action button on the right.

### 9.5 React Component

```typescript
interface Banner {
  id: string;
  type: 'auto-handoff' | 'project-blocked' | 'back-pressure-failure' | 'watcher-error';
  message: string;
  action?: {
    label: string;
    onClick: () => void;
  };
  dismissable: boolean;
  autoResolveCondition?: string; // event type that clears this banner
}
```

---

## 10. Implementation Sequence

### Phase 1: Watcher Infrastructure (Rust)
1. Implement `WatcherManager` struct
2. Replace `FileWatcherState` and `ThreadsWatcherState` with `WatcherManager`
3. Implement `start_watcher`, `stop_watcher`, `list_active_watchers` commands
4. Add `HqEvent` struct with typed payloads
5. Implement debounce and coalescing logic
6. Define all 6 watcher configurations

### Phase 2: Event Bus (React)
7. Create `useHqEvents` hook (Tauri event listeners)
8. Create pub/sub system for data refresh dispatch
9. Wire event listeners to existing hooks (`useThreads`, `usePrd`, etc.)

### Phase 3: Toast System
10. Create `ToastProvider` and `ToastContainer` components
11. Create `Toast` component with glass card styling and animations
12. Wire event-to-toast mapping
13. Add progress bar and hover-pause behavior

### Phase 4: Badge Counts
14. Create `useBadges` hook with localStorage persistence
15. Add badge rendering to nav items / empire cards
16. Wire event-to-badge increment logic
17. Implement badge reset on view navigation

### Phase 5: Notification Center
18. Create `NotificationProvider` with ring buffer storage
19. Create `NotificationPanel` component (slide-in panel)
20. Create notification list with time grouping and filtering
21. Add bell icon with total unread badge to header
22. Wire click-through navigation

### Phase 6: Event Stream
23. Create `useEventStream` hook
24. Create event stream panel (terminal tab or overlay)
25. Implement auto-scroll, pause, filter, clear

### Phase 7: Banner System
26. Create `BannerProvider` and `Banner` component
27. Wire event-to-banner mapping for critical alerts
28. Implement auto-resolve logic

### Phase 8: Native Notifications
29. Add `tauri-plugin-notification` dependency
30. Implement window focus detection
31. Wire native notifications for background + high-priority events
32. Add notification settings to future settings panel
