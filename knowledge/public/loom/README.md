# Loom

AI-powered coding agent built in Rust by Geoffrey Huntley.

**Repo**: `repos/public/loom/` | **GitHub**: https://github.com/ghuntley/loom

## What Is Loom?

Loom is a REPL-based AI coding agent with:
- **96 Rust crates** organized as a Cargo workspace
- **Server-side LLM proxy** - API keys never leave the server
- **Tool system** for file ops, bash, web search
- **Weaver** - remote execution via K8s pods
- **Svelte 5 web frontend**

## Core Principles

1. **Modularity** - Clean separation via trait implementations
2. **Extensibility** - Easy addition of LLM providers and tools
3. **Reliability** - Retry mechanisms, structured logging

## Knowledge Base

| Doc | Description |
|-----|-------------|
| [architecture.md](architecture.md) | System design, crate organization, tech stack |
| [state-machine.md](state-machine.md) | Core agent loop (7-state FSM) |
| [tools.md](tools.md) | Tool trait, registry, built-in tools |
| [llm-proxy.md](llm-proxy.md) | LLM provider abstraction, SSE streaming |
| [thread-system.md](thread-system.md) | Conversation persistence, search |
| [weaver.md](weaver.md) | Remote execution, K8s, WireGuard |
| [web-frontend.md](web-frontend.md) | Svelte 5 runes, xstate patterns |
| [code-style.md](code-style.md) | Rust/Svelte conventions |

## Quick Reference

```
loom/
├── crates/           # 96 Rust crates
├── web/loom-web/     # Svelte 5 frontend
├── specs/            # 57 design specs
├── infra/            # Nix/K8s infrastructure
└── AGENTS.md         # Development guidelines
```

## Key Files

- `AGENTS.md` - Build commands, deployment, code style
- `specs/README.md` - Spec index by category
- `specs/state-machine.md` - Agent FSM spec
- `crates/loom-common-core/src/` - Core types and state machine
