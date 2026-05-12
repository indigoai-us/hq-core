---
type: reference
domain: [engineering]
status: canonical
tags: [loom, web-frontend, svelte, sveltekit, tailwind, xstate]
relates_to: []
---

# Web Frontend

Svelte 5 web application with SvelteKit, Tailwind CSS 4, and xstate state machines.

**Source**: `web/loom-web/`

## Tech Stack

| Technology | Version | Purpose |
|------------|---------|---------|
| Svelte | 5 | UI framework (runes syntax) |
| SvelteKit | 2 | App framework |
| Tailwind CSS | 4 | Styling |
| xstate | - | State machines |
| xterm.js | - | Terminal emulator |
| marked | - | Markdown rendering |
| Storybook | - | Component development |
| Vitest | - | Testing |
| Lingui | - | i18n |

## Svelte 5 Runes (NOT Svelte 4)

**Always use Svelte 5 patterns. Never use Svelte 4.**

| Category | Svelte 5 | Svelte 4 (DO NOT USE) |
|----------|----------|----------------------|
| State | `let count = $state(0);` | `let count = 0;` |
| Derived | `const doubled = $derived(count * 2);` | `$: doubled = count * 2;` |
| Effects | `$effect(() => { ... });` | `$: { ... }` |
| Props | `let { foo, bar } = $props();` | `export let foo;` |
| Events | `onclick={handler}` | `on:click={handler}` |
| Custom events | `onsave={fn}` (callback props) | `createEventDispatcher` |
| Slots | `{@render children()}` | `<slot />` |

## Project Structure

```
web/loom-web/
├── src/
│   ├── app.html              # Root HTML
│   ├── app.css               # Global styles
│   ├── routes/               # SvelteKit routes
│   │   ├── (app)/            # Protected app routes
│   │   │   ├── admin/        # Admin panel
│   │   │   ├── dashboard/    # Main dashboard
│   │   │   ├── threads/      # Conversation threads
│   │   │   └── weavers/      # Remote execution
│   │   ├── (docs)/           # Documentation
│   │   ├── api/              # API routes
│   │   └── login/            # Auth flow
│   └── lib/
│       ├── api/              # HTTP client
│       ├── auth/             # Auth store & machine
│       ├── components/       # Page components
│       ├── docs/             # Doc system
│       ├── i18n/             # Internationalization
│       ├── logging/          # Client logging
│       ├── realtime/         # WebSocket/SSE
│       ├── state/            # State machines
│       └── ui/               # Reusable UI components
├── package.json
├── svelte.config.js
├── tailwind.config.cjs
└── vite.config.ts
```

## Key Components

### Page Components (`src/lib/components/`)

| Component | Purpose |
|-----------|---------|
| `MessageList.svelte` | Conversation message display |
| `MessageBubble.svelte` | Individual message |
| `MessageInput.svelte` | User input |
| `ThreadListPane.svelte` | Thread sidebar |
| `ThreadListItem.svelte` | Thread entry |
| `ToolExecutionPanel.svelte` | Tool call display |
| `WeaverTerminal.svelte` | xterm.js integration |
| `AgentStateTimeline.svelte` | State visualization |
| `ConnectionStatusIndicator.svelte` | Connection status |

### UI Components (`src/lib/ui/`)

| Component | Purpose |
|-----------|---------|
| `Button.svelte` | Button variants |
| `Input.svelte` | Text input |
| `Card.svelte` | Card container |
| `Badge.svelte` | Status badges |
| `Skeleton.svelte` | Loading skeleton |
| `Modal.svelte` | Modal dialog |
| `LoomFrame.svelte` | Main frame wrapper |
| `ThemeProvider.svelte` | Theme context |

## State Machines (`src/lib/state/`)

Uses xstate for complex state management:

| Machine | Purpose |
|---------|---------|
| `authMachine.ts` | Authentication flow |
| `connectionMachine.ts` | WebSocket connection |
| `conversationMachine.ts` | Conversation flow |
| `threadListMachine.ts` | Thread list state |

## Auth Store (`src/lib/auth/`)

```typescript
// authStore.svelte.ts - Svelte 5 runes store
let user = $state<User | null>(null);
let isAuthenticated = $derived(user !== null);
```

## Development

```bash
cd web/loom-web

# Install dependencies
pnpm install

# Development server
pnpm dev

# Run tests
pnpm test

# Storybook
pnpm storybook
```
