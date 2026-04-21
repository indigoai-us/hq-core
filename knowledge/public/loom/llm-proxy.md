---
type: reference
domain: [engineering]
status: canonical
tags: [loom, llm-proxy, api-keys, server-side, anthropic]
relates_to: []
---

# LLM Proxy Architecture

Loom uses a server-side proxy for all LLM interactions. API keys stay on the server; clients communicate through proxy endpoints.

**Source**: `crates/loom-server-llm-proxy/`, `crates/loom-server-llm-service/`

## Architecture

```
┌─────────────┐      HTTP       ┌─────────────┐     Provider API    ┌─────────────┐
│  loom-cli   │ ───────────────▶│ loom-server │ ──────────────────▶ │  Anthropic  │
│             │ /proxy/{provider}│             │                     │   OpenAI    │
│ ProxyLlm-   │  /complete      │  LlmService │                     │  Vertex AI  │
│ Client      │  /stream        │             │                     │             │
└─────────────┘ ◀─────────────  └─────────────┘ ◀────────────────── └─────────────┘
                  SSE stream                        SSE stream
```

## Supported Providers

| Provider | Crate | Endpoint |
|----------|-------|----------|
| Anthropic (Claude) | `loom-server-llm-anthropic` | `/proxy/anthropic/stream` |
| OpenAI | `loom-server-llm-openai` | `/proxy/openai/stream` |
| Vertex AI | `loom-server-llm-vertex` | `/proxy/vertex/stream` |

## LlmClient Trait

```rust
pub trait LlmClient: Send + Sync {
    async fn complete(&self, request: LlmRequest) -> Result<LlmResponse, LlmError>;
    async fn complete_streaming(&self, request: LlmRequest) -> Result<LlmStream, LlmError>;
}
```

## Request/Response Types

```rust
pub struct LlmRequest {
    pub model: String,
    pub messages: Vec<Message>,
    pub tools: Vec<ToolDefinition>,
    pub max_tokens: Option<u32>,
    pub temperature: Option<f32>,
}

pub struct LlmResponse {
    pub message: Message,
    pub tool_calls: Vec<ToolCall>,
    pub usage: Option<Usage>,
    pub finish_reason: Option<String>,
}
```

## Streaming Events

SSE wire format uses `LlmStreamEvent`:

```rust
pub enum LlmStreamEvent {
    TextDelta { content: String },
    ToolCallDelta { call_id: String, tool_name: String, arguments_fragment: String },
    ServerQuery(ServerQuery),        // Phase 2: server→client queries
    Completed { response: LlmProxyResponse },
    Error { message: String },
}
```

SSE format:
```
event: llm
data: {"type":"text_delta","content":"Hello"}

event: llm
data: {"type":"completed","response":{...}}
```

## ProxyLlmClient (Client Side)

```rust
pub struct ProxyLlmClient {
    base_url: String,
    provider: LlmProvider,
    http_client: reqwest::Client,
    auth_token: Option<SecretString>,
}

// Factory methods
ProxyLlmClient::anthropic("http://loom.server")
ProxyLlmClient::openai("http://loom.server")
ProxyLlmClient::vertex("http://loom.server")
```

## Stream Parsing

Client buffers SSE chunks until `\n\n` separator:

```rust
pub struct ProxyLlmStream {
    inner: Pin<Box<dyn Stream<Item = Result<Bytes, reqwest::Error>> + Send>>,
    buffer: String,
}
```

Parsing flow:
1. Buffer bytes until `\n\n`
2. Extract `event: llm` and `data: {...}`
3. Parse JSON as `LlmStreamEvent`
4. Convert to `LlmEvent` for agent

## Server Query (Phase 2)

Enables server to request client actions during streaming:

```rust
pub enum ServerQueryKind {
    ReadFile { path: String },
    ExecuteCommand { command, args, timeout_secs },
    RequestUserInput { prompt, input_type, options },
    GetEnvironment { keys: Vec<String> },
    GetWorkspaceContext,
    Custom { name, payload },
}
```

Currently scaffolded but not fully implemented.

## Security

- API keys stored server-side only
- Clients authenticate via session token
- No direct LLM API access from clients
