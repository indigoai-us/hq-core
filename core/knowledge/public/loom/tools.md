---
type: reference
domain: [engineering]
status: canonical
tags: [loom, tools, file-operations, commands, web-search, agent]
relates_to: []
---

# Tool System

Tools extend the agent's capabilities to perform file operations, execute commands, and search the web.

**Source**: `crates/loom-cli-tools/src/`

## Tool Trait

```rust
#[async_trait]
pub trait Tool: Send + Sync {
    fn name(&self) -> &str;
    fn description(&self) -> &str;
    fn input_schema(&self) -> serde_json::Value;
    async fn invoke(&self, args: serde_json::Value, ctx: &ToolContext) -> Result<serde_json::Value, ToolError>;
}
```

## ToolRegistry

HashMap-based dynamic dispatch for tool lookup:

```rust
pub struct ToolRegistry {
    tools: HashMap<String, Arc<dyn Tool>>,
}

impl ToolRegistry {
    pub fn register(&mut self, tool: Arc<dyn Tool>);
    pub fn get(&self, name: &str) -> Option<Arc<dyn Tool>>;
    pub fn list(&self) -> Vec<&str>;
}
```

## Built-in Tools

### File Operations

| Tool | Purpose |
|------|---------|
| `ReadFileTool` | Read file contents (truncates large files) |
| `ListFilesTool` | Directory listing with path validation |
| `EditFileTool` | Snippet-based text replacement (atomic edits) |

### Command Execution

| Tool | Purpose |
|------|---------|
| `BashTool` | Execute shell commands with timeout/truncation |

**Note**: `BashTool` is a "mutating" tool that triggers `PostToolsHook` for auto-commit.

### LLM/Search

| Tool | Purpose |
|------|---------|
| `OracleTool` | Consult secondary LLM via server proxy |
| `WebSearchToolGoogle` | Web search via Google CSE |
| `WebSearchToolSerper` | Web search via Serper API |

## Security

All tools validate paths against workspace boundaries:
- Prevents directory traversal (`../`)
- Restricts to project root
- Validates file existence

## Tool Execution Flow

1. LLM returns `tool_calls` in response
2. Agent transitions to `ExecutingTools` state
3. Caller invokes tools via `ToolRegistry.get(name).invoke(args, ctx)`
4. Each tool returns success/error outcome
5. Results collected in `ToolExecutionStatus`
6. When all complete → check if mutating → `PostToolsHook` or `CallingLlm`

## ToolContext

Passed to every tool invocation:

```rust
pub struct ToolContext {
    pub workspace_root: PathBuf,
    pub cwd: PathBuf,
    pub thread_id: Option<ThreadId>,
}
```

## Adding a New Tool

1. Implement the `Tool` trait
2. Register with `ToolRegistry`
3. Add to tool definitions sent to LLM
4. If mutating, ensure it triggers `PostToolsHook`
