---
type: reference
domain: [engineering]
status: canonical
tags: [loom, threads, persistence, conversation-snapshot, git-context]
relates_to: []
---

# Thread System

Threads persist complete conversation snapshots including messages, agent state, and git context.

**Source**: `crates/loom-common-thread/src/`

## Thread Structure

```rust
pub struct Thread {
    pub id: ThreadId,                      // T-{uuid7}
    pub version: u64,                      // Optimistic locking

    // Timestamps
    pub created_at: String,
    pub updated_at: String,
    pub last_activity_at: String,

    // Environment snapshot
    pub workspace_root: Option<String>,
    pub cwd: Option<String>,
    pub loom_version: Option<String>,

    // Git context
    pub git_branch: Option<String>,
    pub git_remote_url: Option<String>,
    pub git_initial_branch: Option<String>,
    pub git_initial_commit_sha: Option<String>,
    pub git_current_commit_sha: Option<String>,
    pub git_start_dirty: Option<bool>,
    pub git_end_dirty: Option<bool>,
    pub git_commits: Vec<String>,          // All commits observed

    // Conversation
    pub provider: Option<String>,
    pub model: Option<String>,
    pub conversation: ConversationSnapshot,
    pub agent_state: AgentStateSnapshot,

    // Metadata
    pub metadata: ThreadMetadata,          // Title, tags, pinned
    pub visibility: ThreadVisibility,      // Organization/Private/Public
    pub is_private: bool,                  // Local-only (no sync)
    pub is_shared_with_support: bool,
}
```

## ThreadStore Trait

```rust
pub trait ThreadStore: Send + Sync {
    async fn load(&self, id: &ThreadId) -> Result<Option<Thread>, ThreadStoreError>;
    async fn save(&self, thread: &Thread) -> Result<(), ThreadStoreError>;
    async fn list(&self, limit: u32) -> Result<Vec<ThreadSummary>, ThreadStoreError>;
    async fn delete(&self, id: &ThreadId) -> Result<(), ThreadStoreError>;
    async fn save_and_sync(&self, thread: &Thread) -> Result<(), ThreadStoreError>;
}
```

## LocalThreadStore

Default implementation for local persistence:

- **Location**: `~/.local/share/loom/threads/{ThreadId}.json`
- **Atomic writes**: temp file + rename
- **Search**: FTS5 across title, branch, messages, tags, commit SHAs

## ConversationSnapshot

```rust
pub struct ConversationSnapshot {
    pub messages: Vec<Message>,
}

pub struct Message {
    pub role: Role,               // System, User, Assistant, Tool
    pub content: String,
    pub tool_call_id: Option<String>,
    pub name: Option<String>,
    pub tool_calls: Vec<ToolCall>,
}
```

## ThreadMetadata

```rust
pub struct ThreadMetadata {
    pub title: Option<String>,
    pub tags: Vec<String>,
    pub pinned: bool,
}
```

## Visibility

```rust
pub enum ThreadVisibility {
    Organization,    // Visible to org members
    Private,         // Only visible to owner
    Public,          // Publicly shareable
}
```

## Key Features

1. **Complete snapshot** - Full conversation + agent state + git context
2. **Optimistic locking** - Version numbers prevent conflicts
3. **FTS5 search** - Full-text across all thread content
4. **Local-first** - `is_private` keeps threads from syncing
5. **Git tracking** - Captures branch, commits, dirty state

## Persistence Flow

1. Agent processes events
2. Thread updated after each action
3. `save()` writes atomic JSON
4. Optional `save_and_sync()` for server sync
