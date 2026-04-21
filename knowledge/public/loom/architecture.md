---
type: reference
domain: [engineering]
status: canonical
tags: [loom, architecture, workspace-layout, crate-structure, rust]
relates_to: []
---

# Loom Architecture

## Workspace Layout

```
loom/
├── crates/           # 96 Rust crates
├── web/loom-web/     # Svelte 5 frontend
├── specs/            # 57 design specifications
├── infra/            # Nix/K8s infrastructure
│   ├── nixos-modules/
│   ├── pkgs/
│   └── machines/
├── docker/           # Container configs
├── scripts/          # Build utilities
├── tools/            # Tool definitions
└── ide/vscode/       # VS Code extension
```

## Crate Categories

### Core (shared types & abstractions)
| Crate | Purpose |
|-------|---------|
| `loom-common-core` | State machine, agent, LLM types, tool types |
| `loom-common-thread` | Thread/conversation model |
| `loom-common-config` | Shared configuration |
| `loom-common-http` | reqwest wrapper with retry |
| `loom-common-secret` | Secret handling (auto-redact) |

### CLI
| Crate | Purpose |
|-------|---------|
| `loom-cli` | Main CLI application |
| `loom-cli-tools` | Tool implementations |
| `loom-cli-auto-commit` | Git auto-commit hook |
| `loom-cli-git` | Git integration |
| `loom-cli-spool` | VCS (spool/jj) support |

### Server
| Crate | Purpose |
|-------|---------|
| `loom-server` | HTTP API (axum), migrations, main service |
| `loom-server-api` | API endpoints |
| `loom-server-db` | SQLite via sqlx |
| `loom-server-llm-service` | LLM orchestration |
| `loom-server-llm-proxy` | Client-side proxy handling |
| `loom-server-llm-anthropic` | Claude integration |
| `loom-server-llm-openai` | OpenAI integration |
| `loom-server-llm-vertex` | Google Vertex AI |

### Server Auth
| Crate | Purpose |
|-------|---------|
| `loom-server-auth` | Auth framework |
| `loom-server-auth-github` | GitHub OAuth |
| `loom-server-auth-google` | Google OAuth |
| `loom-server-auth-magiclink` | Magic link auth |
| `loom-server-auth-okta` | Okta SAML |
| `loom-server-auth-devicecode` | Device code flow |

### TUI (Terminal UI)
| Crate | Purpose |
|-------|---------|
| `loom-tui-app` | Main TUI application |
| `loom-tui-core` | Core types |
| `loom-tui-component` | Component framework |
| `loom-tui-widget-*` | Widgets (header, input, markdown, message-list, modal, scrollable, spinner, status-bar, thread-list, tool-panel) |

### Observability
| Crate | Purpose |
|-------|---------|
| `loom-analytics` | PostHog-style analytics |
| `loom-crash` | Crash reporting |
| `loom-crons` | Cron job monitoring |
| `loom-server-sessions` | Session tracking |

### Weaver (Remote Execution)
| Crate | Purpose |
|-------|---------|
| `loom-weaver-*` | Remote execution stack |
| `loom-wgtunnel-*` | WireGuard tunneling |
| `loom-weaver-ebpf` | eBPF syscall tracing |

## Server-Client Architecture

```
┌─────────────┐      HTTP       ┌─────────────┐     Provider API    ┌─────────────┐
│  loom-cli   │ ───────────────▶│ loom-server │ ──────────────────▶ │  Anthropic  │
│             │ /proxy/{provider}│             │                     │   OpenAI    │
│ ProxyLlm-   │  /complete      │  LlmService │                     │  Vertex AI  │
│ Client      │  /stream        │             │                     │             │
└─────────────┘ ◀─────────────  └─────────────┘ ◀────────────────── └─────────────┘
                  SSE stream                        SSE stream
```

**Key insight**: API keys stay server-side. Clients use proxy endpoints.

## Tech Stack

| Layer | Technology |
|-------|------------|
| Backend | Rust, Tokio async runtime, axum HTTP |
| Database | SQLite with sqlx |
| Web Frontend | Svelte 5 (runes), SvelteKit, Tailwind CSS 4, xstate |
| Build | Cargo, Nix (cargo2nix for reproducible builds) |
| Containers | Nix + Docker |
| Orchestration | Kubernetes (for Weaver pods) |
| i18n | GNU gettext with Lingui |
| Testing | proptest (property-based), vitest (web) |
| TUI | Ratatui 0.30 |

## Database

- SQLite via sqlx with compile-time query checking
- Migrations in `crates/loom-server/migrations/`
- Naming: `NNN_description.sql` (e.g., `020_scm_repos.sql`)
- Auto-run on server startup

## Deployment

- Production runs NixOS with auto-update
- `git push origin trunk` triggers deployment
- Update service polls every 10 seconds
- Health endpoint: `https://loom.ghuntley.com/health`
