# HQ Desktop UI Component Audit

**Story:** US-005 - Audit existing UI components & patterns
**Date:** 2026-02-11
**Scope:** All React components, CSS classes, and design tokens in `repos/private/hq-desktop/src/`

---

## 1. Complete Component Inventory

### 1.1 Empire Components (`components/empire/`)

| Component | File | Purpose | Key Props |
|-----------|------|---------|-----------|
| `GlassCard` | `glass-card.tsx` | Primary card container with glass morphism | `title`, `count`, `subtitle`, `statusDots`, `onClick`, `selected`, `size` (sm/md/lg), `className` |
| `GlassChip` | `glass-card.tsx` | Pill-style toggle/filter button | `label`, `color`, `onClick`, `active` |
| `EmpireView` | `empire-view.tsx` | Root empire view with grid/graph toggle and drill-down routing | None (uses `useEmpireData` hook internally) |
| `DrillHeader` | `empire-view.tsx` | Back-navigation header for drill-down views | `title`, `subtitle`, `onBack` |
| `StatsHeader` | `stats-header.tsx` | Top stats bar with view switcher, stat badges, company filter, action buttons | `data`, `activeCount`, `companyFilter`, `onCompanyFilterChange`, `view`, `onViewChange`, `terminalCount`, `onNewTerminal` |
| `StatBadge` | `stats-header.tsx` | Numeric stat display (internal) | `label`, `value`, `highlight` |
| `WorkersDrill` | `workers-drill.tsx` | Worker list view grouped by team | `workers`, `workerStates`, `onSelect`, `onBack` |
| `WorkerDetail` | `worker-detail.tsx` | Single worker detail with skills and thread history | `workerId`, `onBack` |
| `CompaniesDrill` | `companies-drill.tsx` | Company list view | `companies`, `onSelect`, `onBack` |
| `CompanyDetailView` | `company-detail.tsx` | Company detail showing settings/data/knowledge files | `companyId`, `onBack` |
| `ProjectsDrill` | `projects-drill.tsx` | Project list view | `projects`, `onSelect`, `onBack` |
| `ProjectDetailView` | `project-detail.tsx` | Project detail with README viewer | `projectName`, `onBack` |
| `GraphView` | `graph-view.tsx` | 2D force-directed graph of HQ entities | `data`, `workerStates`, `onNodeClick`, `width`, `height` |
| `GraphViewContainer` | `graph-view.tsx` | Auto-sizing wrapper for GraphView | `data`, `workerStates`, `onNodeClick` |
| `ActivityFeed` | `activity-feed.tsx` | Combined thread + Claude session activity list | `threads`, `claudeSessions`, `workerTypes`, `onThreadClick`, `onSessionClick` |
| `ThreadInspector` | `thread-inspector.tsx` | Slide-in panel showing thread details | `thread`, `workerType`, `onClose` |
| `AbstractBackground` | `abstract-background.tsx` | Fixed background with gradient orbs, grid, noise | None |
| `TopBar` | `top-bar.tsx` | Top navigation bar with view mode tabs | `viewMode`, `onViewModeChange` |
| `LeftSidebar` | `left-sidebar.tsx` | Intervention queue + active jobs sidebar | `interventions`, `jobs`, `onInterventionAction` |
| `RightSidebar` | `right-sidebar.tsx` | Skills panel + HQ file tree sidebar | `onSpawnSkill` |
| `FilesSidebar` | `files-sidebar.tsx` | Standalone HQ file tree sidebar | `onSpawnSkill` |
| `ProjectsSidebar` | `projects-sidebar.tsx` | Active projects + CLI sessions sidebar | `projects`, `agents`, `onProjectSelect`, `onRunProject`, `selectedProject` |
| `IsometricMap` | `isometric-map.tsx` | 3D isometric visualization with Three.js/R3F | `nodes`, `selectedNode`, `onNodeSelect` |
| `types.ts` | `types.ts` | Type definitions: `NodeStatus`, `NodeType`, `EmpireNode` | N/A |

### 1.2 Terminal Components (`components/terminal/`)

| Component | File | Purpose | Key Props |
|-----------|------|---------|-----------|
| `TerminalPanel` | `terminal-panel.tsx` | Multi-tab terminal container with session management | None (uses `useSessionStore`) |
| `TerminalTab` | `terminal-header.tsx` | Individual tab button with status dot and company color | `session`, `isActive`, `onClick`, `onClose` |
| `TerminalContextBar` | `terminal-header.tsx` | Bottom context bar showing worker/company/project info | `session` |
| `TerminalTabView` | `terminal-tab.tsx` | Xterm.js terminal renderer | `sessionId`, `isVisible` |
| `SessionLauncher` | `session-launcher.tsx` | Modal for spawning shell or worker sessions | `isOpen`, `onClose` |

### 1.3 UI Primitives (`components/ui/`)

| Component | File | Purpose | Key Props |
|-----------|------|---------|-----------|
| `Button` | `button.tsx` | CVA-based button with variants | `variant` (default/destructive/outline/secondary/ghost/link/glass), `size` (default/sm/lg/icon/icon-sm/icon-lg), `asChild` |
| `Badge` | `badge.tsx` | CVA-based status badge | `variant` (default/secondary/destructive/outline/working/pending/attention/error/idle), `asChild` |
| `Card` | `card.tsx` | Standard card container | `className` |
| `GlassCard` (ui) | `card.tsx` | Simplified glass card via CSS class | `className` |
| `CardHeader` | `card.tsx` | Card header region | `className` |
| `CardTitle` | `card.tsx` | Card title text | `className` |
| `CardDescription` | `card.tsx` | Card description text | `className` |
| `CardContent` | `card.tsx` | Card content region | `className` |
| `CardFooter` | `card.tsx` | Card footer region | `className` |
| `ScrollArea` | `scroll-area.tsx` | Simple overflow-y-auto wrapper | `className` |

### 1.4 Command Palette (`components/command-palette.tsx`)

| Component | File | Purpose | Key Props |
|-----------|------|---------|-----------|
| `CommandPalette` | `command-palette.tsx` | Cmd+K command search/execute overlay | `isOpen`, `onClose` |
| `useCommandPalette` | `command-palette.tsx` | Hook for palette state + keyboard shortcut | Returns `isOpen`, `open`, `close`, `toggle` |

### 1.5 Quick Actions (`components/quick-actions.tsx`)

| Component | File | Purpose | Key Props |
|-----------|------|---------|-----------|
| `QuickActions` | `quick-actions.tsx` | Categorized skill launcher list | `onSpawnSkill` |

### 1.6 Dashboard Components (`components/dashboard/`)

| Component | File | Purpose | Key Props |
|-----------|------|---------|-----------|
| `DashboardOverview` | `overview.tsx` | Dashboard view with stat cards, recent threads, quick actions | `onNavigate`, `onRunWorker` |
| `ProjectsDashboard` | `projects-dashboard.tsx` | Projects view (not audited in detail) | - |
| `ProjectDetail` (dashboard) | `project-detail.tsx` | Project detail (dashboard variant) | - |

### 1.7 Other Components

| Component | File | Purpose | Key Props |
|-----------|------|---------|-----------|
| `WorkerCard` | `workers/worker-card.tsx` | Card for worker in registry view | `worker`, `onRun` |
| `WorkersRegistry` | `workers/index.tsx` | Full worker registry view | `onRunWorker` |
| Chat components | `chat/` | Conversation, message, multi-select | Various |
| File navigator | `file-navigator/` | File tree + preview | Various |
| Kanban components | `kanban/` | Board, column, card | Various |
| Thread components | `threads/` | Thread list + detail | Various |

### 1.8 App Shell (`App.tsx`)

Root component that composes: `StatsHeader`, `ActivityFeed`, `EmpireView`, `TerminalPanel`, `CommandPalette`, `ThreadInspector`, `SessionLauncher`. Uses `useEmpireData`, `useSessionStore`, `useCommandPalette`.

---

## 2. Design Tokens

### 2.1 CSS Custom Properties (`:root` in `index.css`)

#### Base Colors (oklch)
| Token | Value | Usage |
|-------|-------|-------|
| `--background` | `oklch(0.03 0 0)` | Pure black app background |
| `--foreground` | `oklch(0.85 0 0)` | Primary text |
| `--card` | `oklch(0.06 0 0)` | Card backgrounds |
| `--popover` | `oklch(0.05 0 0)` | Popover backgrounds |
| `--primary` | `oklch(0.85 0 0)` | Primary UI elements |
| `--secondary` | `oklch(0.1 0 0)` | Secondary surfaces |
| `--muted` | `oklch(0.08 0 0)` | Muted backgrounds |
| `--muted-foreground` | `oklch(0.45 0 0)` | Muted text |
| `--accent` | `oklch(0.12 0 0)` | Accent surfaces |
| `--border` | `oklch(0.15 0 0)` | Border color |
| `--input` | `oklch(0.08 0 0)` | Input backgrounds |
| `--ring` | `oklch(0.3 0 0)` | Focus ring |
| `--sidebar` | `oklch(0.02 0 0)` | Sidebar background |

#### Status Colors (oklch, monochrome)
| Token | Value | Usage |
|-------|-------|-------|
| `--status-working` | `oklch(0.7 0 0)` | Working/active state |
| `--status-pending` | `oklch(0.55 0 0)` | Pending state |
| `--status-attention` | `oklch(0.6 0 0)` | Attention needed |
| `--status-error` | `oklch(0.5 0 0)` | Error state |
| `--status-idle` | `oklch(0.3 0 0)` | Idle state |

#### Glass Tokens
| Token | Value | Usage |
|-------|-------|-------|
| `--glass-bg` | `oklch(0.06 0 0 / 0.8)` | Glass panel background |
| `--glass-bg-solid` | `oklch(0.05 0 0 / 0.95)` | Solid glass background |
| `--glass-border` | `oklch(1 0 0 / 0.06)` | Default glass border |
| `--glass-border-light` | `oklch(1 0 0 / 0.08)` | Light glass border |
| `--glass-border-strong` | `oklch(1 0 0 / 0.12)` | Strong glass border |
| `--glass-highlight` | `oklch(1 0 0 / 0.02)` | Glass highlight |
| `--glass-shadow` | `oklch(0 0 0 / 0.6)` | Glass shadow |

#### Other
| Token | Value |
|-------|-------|
| `--radius` | `0.375rem` (6px) |
| Font family | `'Geist Mono', ui-monospace, 'SF Mono', SFMono-Regular, monospace` |

### 2.2 CSS Utility Classes

| Class | Background | Blur | Shadow | Usage |
|-------|-----------|------|--------|-------|
| `.glass-panel` | `oklch(0.1 0.008 260 / 0.4)` to `oklch(0.06 0.005 260 / 0.5)` | `blur(32px) saturate(150%)` | Inset top/bottom highlights + 1px border | Primary panels |
| `.glass-panel-light` | `oklch(0.12 0.006 260 / 0.3)` to `oklch(0.08 0.004 260 / 0.35)` | `blur(24px) saturate(140%)` | Lighter inset + 1px border | Lighter panels |
| `.glass-inset` | `oklch(1 0 0 / 0.03)` | `blur(12px)` | Inset shadow + 1px border | Inset inputs/controls |
| `.glass-button` | `oklch(1 0 0 / 0.05)` hover: `oklch(1 0 0 / 0.08)` | `blur(16px)` | Inset highlight + 1px border | Buttons |
| `.liquid-glass` | `oklch(0.04 0 0 / 0.95)` | None | `0 4px 20px` | Minimal panels |
| `.liquid-glass-card` | `oklch(0.06 0 0)` | None | None | Cards |
| `.liquid-glass-button` | `oklch(0.1 0 0)` hover: `oklch(0.14 0 0)` | None | None | Buttons |
| `.liquid-glass-sidebar` | `oklch(0.02 0 0)` | None | None | Sidebars |

### 2.3 Animations

| Class | Keyframe | Timing | Usage |
|-------|----------|--------|-------|
| `.animate-pulse-working` | `pulse-mono` | 1.5s ease-in-out infinite | Working status dots |
| `.animate-pulse-pending` | `pulse-mono` | 2s ease-in-out infinite | Pending status dots |
| `.animate-pulse-error` | `pulse-mono` | 1s ease-in-out infinite | Error status dots |
| `.animate-blink` | `blink` | 1s step-end infinite | Cursor blink |

---

## 3. Inconsistencies Across Components

### 3.1 Two Competing Glass Card Implementations

**Problem:** There are two `GlassCard` components with different APIs and styling approaches.

| Aspect | `empire/glass-card.tsx` | `ui/card.tsx` GlassCard |
|--------|------------------------|-------------------------|
| **API** | Rich props: `title`, `count`, `subtitle`, `statusDots`, `size`, `selected`, `onClick` | Simple `className` pass-through with `.glass-panel` class |
| **Styling** | Inline styles with `rgba()` values, `backdrop-filter: blur(40px) saturate(180%)` | CSS class `.glass-panel` using `oklch()`, `blur(32px) saturate(150%)` |
| **Border radius** | `rounded-3xl` (24px) via Tailwind | `rounded-xl` (12px) via Tailwind |
| **Hover effects** | Inline `<style>` tag for hover scale + color shift gradient overlay | None |
| **Usage** | Empire views (empire-view, workers-drill, companies-drill, projects-drill, worker-detail) | Dashboard views (overview, workers/worker-card, workers/index) |
| **Consumers** | ~10 components import from `empire/glass-card` | ~4 components import from `ui/card` |

**Impact:** Visual inconsistency between empire views and dashboard views. Two APIs to maintain.

### 3.2 Inconsistent Glass Background Values

Glass-effect backgrounds are defined in at least 5 different places with varying values:

| Location | Background | Blur | Saturate | Border |
|----------|-----------|------|----------|--------|
| `GlassCard` (empire) default | `rgba(255,255,255,0.08)` to `rgba(255,255,255,0.03)` | 40px | 180% | `rgba(255,255,255,0.1)` |
| `GlassCard` (empire) selected | `rgba(255,255,255,0.12)` to `rgba(255,255,255,0.06)` | 40px | 180% | `rgba(255,255,255,0.2)` |
| `GlassChip` active | `rgba(255,255,255,0.15)` to `rgba(255,255,255,0.08)` | 20px | N/A | `rgba(255,255,255,0.2)` |
| `StatsHeader` | `rgba(255,255,255,0.06)` to `rgba(255,255,255,0.02)` | 30px | 160% | `rgba(255,255,255,0.08)` |
| `DrillHeader` back button | `rgba(255,255,255,0.08)` to `rgba(255,255,255,0.03)` | 20px | 150% | `rgba(255,255,255,0.1)` |
| `ActivityFeed` | `rgba(255,255,255,0.04)` to `rgba(255,255,255,0.02)` | 20px | 150% | `rgba(255,255,255,0.06)` |
| `CommandPalette` | `rgba(30,30,30,0.95)` to `rgba(20,20,20,0.98)` | 40px | 180% | `rgba(255,255,255,0.1)` |
| `ThreadInspector` | `rgba(30,30,30,0.95)` to `rgba(20,20,20,0.98)` | 40px | 180% | `rgba(255,255,255,0.1)` |
| `SessionLauncher` | `rgba(30,30,50,0.95)` to `rgba(20,20,35,0.98)` | N/A | N/A | `rgba(255,255,255,0.1)` |
| `.glass-panel` CSS | `oklch(0.1 0.008 260 / 0.4)` to `oklch(0.06 0.005 260 / 0.5)` | 32px | 150% | via box-shadow |
| `.liquid-glass` CSS | `oklch(0.04 0 0 / 0.95)` | None | None | `oklch(1 0 0 / 0.08)` |
| Worker detail skills | `rgba(255,255,255,0.06)` to `rgba(255,255,255,0.02)` | 30px | 160% | `rgba(255,255,255,0.08)` |
| Worker detail threads | `rgba(255,255,255,0.02)` | N/A | N/A | `rgba(255,255,255,0.04)` |
| Recent activity in empire | `rgba(255,255,255,0.06)` to `rgba(255,255,255,0.02)` | 30px | 160% | `rgba(255,255,255,0.08)` |

**Impact:** No consistent glass treatment. Blur values range from 12px to 40px. Background opacities range from 0.02 to 0.15. Border opacities range from 0.04 to 0.2. Some use `rgba()`, some use `oklch()`. Some have CSS classes, most are inline styles.

### 3.3 Inconsistent Border Radius

| Value | Where Used |
|-------|-----------|
| `rounded-3xl` (24px) | `GlassCard` (empire), `DrillHeader` back button |
| `rounded-2xl` (16px) | `StatsHeader`, `ActivityFeed`, `GraphView`, worker detail items, recent activity, `CommandPalette` (16px via inline), `LeftSidebar` icon containers, `RightSidebar` |
| `rounded-xl` (12px) | `GlassCard` (ui), view mode toggle, company filter, action buttons, file items, thread items, `ProjectsSidebar` items |
| `rounded-lg` (8px) | `TopBar` view tabs, command palette items, file tree items, zoom controls |
| `rounded-md` (6px) | File tree items, `Badge` |
| `rounded` (4px) | `.liquid-glass-card`, `.liquid-glass-button` |
| Custom `16px` | `CommandPalette` (inline borderRadius) |

**Impact:** No consistent hierarchy of border radii for component types. Cards range from 4px to 24px.

### 3.4 Inconsistent Typography Scale

| Size | Where Used | Notes |
|------|-----------|-------|
| `text-2xl` | `StatBadge` value, `DashboardOverview` stat value | Large numbers |
| `text-xl` | `StatsHeader` "HQ FORGE", empire title, drill headers | Section headings |
| `text-lg` | `ThreadInspector` title, `WorkersRegistry` heading | Sub-headings |
| `text-sm` | Most body text across all components | Primary body |
| `text-xs` | Labels, descriptions, timestamps, badges | Secondary text |
| `text-[13px]` | `LeftSidebar` items, `ProjectsSidebar` items | Custom between xs and sm |
| `text-[12px]` | File tree items, `QuickActions` skill names, `CLI session` names | Custom small |
| `text-[11px]` | Section headers (uppercase tracking), context bar | Micro labels |
| `text-[10px]` | Badges, counts, minimap labels, timestamps | Micro text |
| `text-[9px]` | Job type badges in LeftSidebar | Extreme micro |

**Impact:** Mix of Tailwind scale (`text-xs`, `text-sm`) and arbitrary values (`text-[11px]`, `text-[13px]`). The arbitrary values create an inconsistent type ramp that's hard to maintain.

### 3.5 Inconsistent Text Opacity Scale

White text opacities used across components:

| Opacity | Usage Pattern | Frequency |
|---------|--------------|-----------|
| `text-white/90` or `text-white` | Primary text, active states | Frequent |
| `text-white/80` | Secondary important text | Frequent |
| `text-white/70` | Tertiary text | Moderate |
| `text-white/60` | De-emphasized text, file names | Moderate |
| `text-white/50` | Section headers, labels | Frequent |
| `text-white/40` | Descriptions, timestamps, subtitles | Very frequent |
| `text-white/30` | Muted info, icons, counts | Very frequent |
| `text-white/25` | Timestamps in activity feed | Rare |
| `text-white/20` | Very muted (placeholders, separators, folder counts) | Moderate |
| `text-white/15` | Keyboard shortcut hints | Rare |
| `text-foreground/...` | TopBar, LeftSidebar, RightSidebar uses `foreground` token | Moderate |

**Impact:** Two opacity systems running in parallel: `text-white/{opacity}` (empire components) vs `text-foreground/{opacity}` (sidebar/topbar components). No semantic meaning to specific opacity levels.

### 3.6 Inconsistent Color Systems for Status

| System | Working | Pending/Attention | Error | Idle/Default | Where Used |
|--------|---------|-------------------|-------|-------------|-----------|
| CSS vars (oklch monochrome) | `oklch(0.7 0 0)` | `oklch(0.55-0.6 0 0)` | `oklch(0.5 0 0)` | `oklch(0.3 0 0)` | Badge variants, LeftSidebar, Minimap |
| Inline RGB (colored) | `#4ade80` / `rgb(74,222,128)` | `#fbbf24` / `rgb(251,191,36)` | `#f87171` / `rgb(248,113,113)` | `rgba(100,100,100,0.5)` | GraphView, IsometricMap, LeftSidebar JobItem, ActivityFeed |
| Tailwind colors | `text-green-400`, `bg-green-500/20` | `text-yellow-400`, `bg-yellow-500/20` | `text-red-400`, `bg-red-500/20` | `text-white/40` | WorkerCard, thread state badges, empire activity |
| Tailwind + semantic | `bg-status-working` | `bg-status-attention` | `bg-status-error` | `bg-status-idle` | ProjectsSidebar, LeftSidebar |

**Impact:** Same statuses rendered with different colors depending on which component displays them. Monochrome CSS vars conflict with colored inline RGB values.

### 3.7 Duplicated File Tree Components

`FilesSidebar` and `RightSidebar` both contain nearly identical `FileTreeNode` implementations. The `FileTreeNode` function is duplicated ~90 lines across both files with the same logic, same folder colors, same icon mapping.

### 3.8 Inconsistent Hover Background Values

| Value | Where Used |
|-------|-----------|
| `hover:bg-white/[0.015]` | LeftSidebar interventions, jobs |
| `hover:bg-white/[0.02]` | Thread inspector file items |
| `hover:bg-white/[0.03]` | ActivityFeed items, file tree, ProjectsSidebar |
| `hover:bg-white/[0.04]` | TopBar tabs, QuickActions |
| `hover:bg-white/[0.06]` | ThreadInspector close button, QuickActions active |
| `hover:bg-white/[0.08]` | StatsHeader filter, terminal button, worker detail run button |
| `hover:bg-white/[0.1]` | Empire retry button, GlassCard inline hover |
| `hover:bg-white/5` | DashboardOverview items, WorkerCard |

**Impact:** Hover states are ad-hoc. No consistent mapping from "component depth/importance" to "hover opacity."

### 3.9 Inline Styles vs CSS Classes vs Tailwind

| Approach | Components Using It |
|----------|-------------------|
| **Inline `style={{}}` only** | GlassCard (empire), GlassChip, StatsHeader, DrillHeader, ActivityFeed, ThreadInspector, CommandPalette, SessionLauncher, TerminalPanel, TerminalTab, TerminalContextBar, EmpireView (recent activity, view toggle), WorkerDetail (skills section) |
| **CSS utility classes** (`.glass-panel`, `.liquid-glass`, etc.) | Card (ui), TopBar, LeftSidebar, RightSidebar, FilesSidebar, QuickActions, IsometricMap (minimap, zoom) |
| **Tailwind only** | Button, Badge, ScrollArea, FileTreeNode, WorkerCard, WorkersRegistry, DashboardOverview |

**Impact:** The most visually important components (GlassCard, StatsHeader, CommandPalette) all use inline styles, making token extraction and theming impossible without refactoring.

### 3.10 Company Color Definitions

Company-specific colors appear in two places with different values:

| Company | `terminal-header.tsx` | `right-sidebar.tsx` / `files-sidebar.tsx` (folder colors) |
|---------|----------------------|----------------------------------------------------------|
| {company} | `#74c0fc` | N/A |
| {company} | `#da77f2` | N/A |
| personal | `#ffd43b` | N/A |
| golden-thread | `#ff922b` | N/A |
| projects folder | N/A | `text-blue-400/60` |
| workers folder | N/A | `text-green-400/60` |
| knowledge folder | N/A | `text-purple-400/60` |
| companies folder | N/A | `text-emerald-400/60` |

No centralized color mapping for companies.

---

## 4. Recommendations for Token Standardization

### 4.1 Consolidate Glass Tiers

Reduce the 12+ glass background variants to 4 semantic tiers:

| Tier | Purpose | Proposed Background | Blur | Border |
|------|---------|-------------------|------|--------|
| `glass-surface` | Primary cards, panels | `rgba(255,255,255,0.08)` gradient | `blur(40px) saturate(180%)` | `rgba(255,255,255,0.1)` |
| `glass-surface-elevated` | Selected cards, modals | `rgba(255,255,255,0.12)` gradient | `blur(40px) saturate(180%)` | `rgba(255,255,255,0.15)` |
| `glass-overlay` | Command palette, inspectors | `rgba(25,25,25,0.95)` solid | `blur(40px) saturate(180%)` | `rgba(255,255,255,0.1)` |
| `glass-inset` | Nested inputs, badges | `rgba(255,255,255,0.03)` | `blur(12px)` | `rgba(255,255,255,0.04)` |

### 4.2 Standardize Border Radius Scale

| Token | Value | Usage |
|-------|-------|-------|
| `--radius-card` | `16px` | All cards and panels |
| `--radius-button` | `12px` | All buttons and interactive controls |
| `--radius-badge` | `20px` | Chips, badges, pills |
| `--radius-input` | `8px` | Inputs, selects |
| `--radius-sm` | `6px` | Inline elements, small badges |

### 4.3 Standardize Typography Scale

Map arbitrary px values to semantic tokens:

| Token | Size | Usage |
|-------|------|-------|
| `--text-display` | `24px` (`text-2xl`) | Large stat numbers |
| `--text-heading` | `20px` (`text-xl`) | Section headings |
| `--text-subheading` | `16px` (`text-base`) | Sub-headings |
| `--text-body` | `14px` (`text-sm`) | Primary body text |
| `--text-caption` | `12px` (`text-xs`) | Labels, descriptions, timestamps |
| `--text-micro` | `11px` | Section labels (uppercase) |
| `--text-nano` | `10px` | Badges, counts, timestamps |

### 4.4 Standardize Text Opacity Scale

Reduce to 5 semantic levels:

| Token | Opacity | Usage |
|-------|---------|-------|
| `--text-primary` | `90%` | Primary content, active text |
| `--text-secondary` | `70%` | Secondary labels, important descriptions |
| `--text-muted` | `50%` | Section headers, tertiary content |
| `--text-dim` | `35%` | Timestamps, metadata, icons |
| `--text-faint` | `20%` | Dividers, disabled text, hints |

### 4.5 Unify Status Color System

Pick one system and use it everywhere. Recommendation: use Tailwind colors (green/yellow/red) consistently, map through CSS variables:

| Token | Value | Usage |
|-------|-------|-------|
| `--status-working` | `#4ade80` (green-400) | Active/executing |
| `--status-pending` | `#facc15` (yellow-400) | Queued/pending |
| `--status-attention` | `#fb923c` (orange-400) | Needs attention |
| `--status-error` | `#f87171` (red-400) | Error/failed |
| `--status-idle` | `rgba(255,255,255,0.3)` | Idle/default |
| `--status-completed` | `rgba(255,255,255,0.5)` | Done |

### 4.6 Unify GlassCard Components

Merge the two `GlassCard` implementations into a single component with:
- Props from `empire/glass-card.tsx` (title, count, statusDots, size, selected)
- Styling via CSS class tokens instead of inline styles
- Place in `ui/glass-card.tsx` as the canonical version
- Delete `ui/card.tsx` GlassCard variant

### 4.7 Extract Reusable Patterns

| Pattern | Current | Proposed |
|---------|---------|----------|
| FileTreeNode | Duplicated in `files-sidebar.tsx` and `right-sidebar.tsx` | Extract to `components/shared/file-tree-node.tsx` |
| Status dot + pulse | Reimplemented ~8 times across components | Extract `StatusDot` component with `color`, `pulsing`, `size` props |
| Glass list item | Repeated in thread lists, file lists, worker lists | Extract `GlassListItem` component |
| Section header | `text-white/50 text-xs font-medium uppercase tracking-wider` repeated ~10x | Extract `SectionHeader` component |
| Company colors | Defined in `terminal-header.tsx` only | Move to shared `constants/colors.ts` |

### 4.8 Hover State Scale

Standardize hover backgrounds:

| Token | Value | Usage |
|-------|-------|-------|
| `--hover-subtle` | `rgba(255,255,255,0.03)` | List items, feed items |
| `--hover-default` | `rgba(255,255,255,0.06)` | Cards, buttons |
| `--hover-strong` | `rgba(255,255,255,0.1)` | Primary actions |

---

## 5. Summary

The HQ Desktop codebase contains **~50 React components** across 12 directories. The visual language is "dark glass morphism" (inspired by macOS Tahoe/liquid glass), but its implementation is fragmented across inline styles, CSS classes, and Tailwind utilities with no single source of truth.

**Key findings:**
1. Two competing GlassCard implementations with incompatible APIs
2. 12+ unique glass background treatments with different opacity/blur/saturate values
3. Border radius values range from 4px to 24px with no semantic hierarchy
4. Four parallel status color systems (oklch monochrome, RGB colored, Tailwind, semantic CSS vars)
5. Typography uses a mix of Tailwind scale and arbitrary pixel values
6. Most glass styling is inline, making theme-ability impossible
7. Duplicated code patterns (FileTreeNode, status dots, section headers)

**Recommended priority for standardization:**
1. Create canonical design tokens file (CSS custom properties)
2. Merge GlassCard implementations
3. Refactor inline glass styles to use token-based CSS classes
4. Extract duplicated patterns into shared components
5. Standardize status colors to one system
6. Formalize typography and opacity scales
