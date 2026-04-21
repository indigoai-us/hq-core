---
type: reference
domain: [engineering]
status: canonical
tags: [loom, code-style, rust, formatting, conventions]
relates_to: []
---

# Code Style & Conventions

## Rust Formatting

```toml
# rustfmt.toml
hard_tabs = true
tab_spaces = 2
max_width = 100
```

## Error Handling

```rust
// Use thiserror for error enums
use thiserror::Error;

#[derive(Error, Debug)]
pub enum MyError {
    #[error("failed to do X: {0}")]
    SomeFailure(String),
}

// Use anyhow for propagation
use anyhow::Result;

pub fn do_thing() -> Result<()> {
    // ...
}
```

## Async

- Runtime: Tokio
- Trait methods: `async-trait`

```rust
use async_trait::async_trait;

#[async_trait]
pub trait MyTrait: Send + Sync {
    async fn do_thing(&self) -> Result<()>;
}
```

## HTTP Clients

**Never use `reqwest::Client` directly.** Use `loom-http` wrapper:

```rust
use loom_http::{new_client, builder};

// Consistent User-Agent and retry logic
let client = new_client()?;
```

## Secrets

Use `loom-secret` for API keys, tokens, passwords:

```rust
use loom_secret::{Secret, SecretString};

let api_key: SecretString = SecretString::new("sk-xxx");

// Access via expose()
api_key.expose()

// Auto-redacts in Debug/Display/Serialize/tracing
```

## Imports

Group in order:
1. `std` crates
2. External crates
3. Internal `loom-*` crates

```rust
use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

use loom_common_core::Message;
use loom_secret::SecretString;
```

## Naming

| Category | Style |
|----------|-------|
| Functions/variables | `snake_case` |
| Types | `PascalCase` |
| Constants | `SCREAMING_CASE` |

## Comments

**Minimal comments.** Only add when code is complex and requires context.

**Copyright header required** on all files.

## Logging

Use `tracing` with structured fields:

```rust
use tracing::{info, instrument};

#[instrument(skip(self, secrets, large_args), fields(id = %id))]
async fn do_thing(&self, id: Uuid, secrets: SecretString) -> Result<()> {
    info!("doing thing");
    // ...
}
```

**Always skip secrets in instrument.**

## Testing

| Type | Use Case |
|------|----------|
| `proptest` | Property-based tests (preferred for complex logic) |
| Unit tests | Simple cases |
| Integration tests | End-to-end flows |

```rust
use proptest::prelude::*;

proptest! {
    #[test]
    fn test_invariant(input in any::<u32>()) {
        prop_assert!(invariant_holds(input));
    }
}
```

## i18n (Internationalization)

Uses GNU gettext with `.po` files:

```rust
use loom_i18n::{t, t_fmt, is_rtl, resolve_locale};

// Simple translation
let subject = t("es", "server.email.magic_link.subject");

// With variables
let body = t_fmt("es", "server.email.invitation.subject", &[
    ("org_name", "Acme Corp"),
]);

// RTL support
if is_rtl(locale) {
    // Use dir="rtl" in HTML
}
```

**String naming**: `{prefix}.{domain}.{component}.{element}`
- Prefixes: `server.` (backend), `client.` (CLI)
- Domains: `email`, `api`, `auth`, `org`

**Supported locales**: `en`, `es`, `ar` (RTL)

## Svelte (Web)

See [web-frontend.md](web-frontend.md) for Svelte 5 patterns.

Key rule: **Always use Svelte 5 runes, never Svelte 4.**
