---
type: reference
domain: [engineering]
status: canonical
tags: [loom, state-machine, event-driven, agent, conversation-flow]
relates_to: []
---

# Agent State Machine

The core of Loom is an explicit, event-driven state machine that manages conversation flow and tool execution.

**Source**: `crates/loom-common-core/src/state.rs`, `crates/loom-common-core/src/agent.rs`

## Design Principles

1. **Predictable** - All transitions are explicit and testable
2. **Self-contained** - Each state carries its required context
3. **Pure** - No async in state machine; caller drives I/O
4. **Deterministic** - Same events → same actions (enables replay)

## States

| State | Description | Key Fields |
|-------|-------------|------------|
| `WaitingForUserInput` | Idle, ready for user message | `conversation` |
| `CallingLlm` | LLM request in flight | `conversation`, `retries` |
| `ProcessingLlmResponse` | Examining LLM response | `conversation`, `response` |
| `ExecutingTools` | Running tool calls in parallel | `conversation`, `executions` |
| `PostToolsHook` | Running post-tool hooks (auto-commit) | `conversation`, `pending_llm_request`, `completed_tools` |
| `Error` | Recoverable error with retry | `conversation`, `error`, `retries`, `origin` |
| `ShuttingDown` | Terminal state | (none) |

## Events

| Event | Description |
|-------|-------------|
| `UserInput(Message)` | User submitted message |
| `LlmEvent::TextDelta` | Streaming text from LLM |
| `LlmEvent::ToolCallDelta` | Streaming tool call data |
| `LlmEvent::Completed(LlmResponse)` | LLM finished |
| `LlmEvent::Error(LlmError)` | LLM error |
| `ToolCompleted { call_id, outcome }` | Tool execution finished |
| `PostToolsHookCompleted` | Hooks finished |
| `RetryTimeoutFired` | Retry backoff expired |
| `ShutdownRequested` | Graceful shutdown |

## Actions

Actions are returned to caller indicating what I/O to perform:

| Action | Description |
|--------|-------------|
| `SendLlmRequest(LlmRequest)` | Call LLM provider |
| `ExecuteTools(Vec<ToolCall>)` | Run tool calls |
| `RunPostToolsHook { completed_tools }` | Run auto-commit |
| `WaitForInput` | Idle |
| `DisplayMessage(String)` | Show to user |
| `DisplayError(String)` | Show error |
| `Shutdown` | Terminate |

## Transition Table

| Current State | Event | New State | Action |
|---------------|-------|-----------|--------|
| WaitingForUserInput | UserInput | CallingLlm | SendLlmRequest |
| CallingLlm | TextDelta | CallingLlm | DisplayMessage |
| CallingLlm | Completed | ProcessingLlmResponse | (internal) |
| CallingLlm | Error (retries < max) | Error | WaitForInput |
| CallingLlm | Error (retries >= max) | WaitingForUserInput | DisplayError |
| ProcessingLlmResponse | (has tool calls) | ExecutingTools | ExecuteTools |
| ProcessingLlmResponse | (no tools) | WaitingForUserInput | WaitForInput |
| ExecutingTools | ToolCompleted (some pending) | ExecutingTools | WaitForInput |
| ExecutingTools | ToolCompleted (all done, mutating) | PostToolsHook | RunPostToolsHook |
| ExecutingTools | ToolCompleted (all done, non-mutating) | CallingLlm | SendLlmRequest |
| PostToolsHook | PostToolsHookCompleted | CallingLlm | SendLlmRequest |
| Error | RetryTimeoutFired | CallingLlm | SendLlmRequest |
| *any* | ShutdownRequested | ShuttingDown | Shutdown |

## Flow Diagram

```mermaid
stateDiagram-v2
    [*] --> WaitingForUserInput : Agent::new()

    WaitingForUserInput --> CallingLlm : UserInput

    CallingLlm --> CallingLlm : TextDelta / ToolCallDelta
    CallingLlm --> ProcessingLlmResponse : Completed
    CallingLlm --> Error : Error (retries < max)
    CallingLlm --> WaitingForUserInput : Error (retries >= max)

    ProcessingLlmResponse --> ExecutingTools : has tool calls
    ProcessingLlmResponse --> WaitingForUserInput : no tool calls

    ExecutingTools --> ExecutingTools : ToolCompleted (some pending)
    ExecutingTools --> PostToolsHook : ToolCompleted (all done, mutating)
    ExecutingTools --> CallingLlm : ToolCompleted (all done, no mutation)

    PostToolsHook --> CallingLlm : PostToolsHookCompleted

    Error --> CallingLlm : RetryTimeoutFired

    WaitingForUserInput --> ShuttingDown : ShutdownRequested
    CallingLlm --> ShuttingDown : ShutdownRequested
    ExecutingTools --> ShuttingDown : ShutdownRequested

    ShuttingDown --> [*]
```

## Mutating Tools

Tools that modify files trigger `PostToolsHook` for auto-commit:
- `edit_file`
- `bash`

Non-mutating tools skip hooks and go directly back to `CallingLlm`.

## Key Implementation Pattern

```rust
// Agent is purely reactive - no async code
pub fn handle_event(&mut self, event: AgentEvent) -> AgentResult<AgentAction> {
    match (&mut self.state, event) {
        (AgentState::WaitingForUserInput { conversation }, AgentEvent::UserInput(msg)) => {
            conversation.messages.push(msg);
            self.state = AgentState::CallingLlm { conversation: conversation.clone(), retries: 0 };
            Ok(AgentAction::SendLlmRequest(request))
        }
        // ... more transitions
    }
}
```

**Inversion of control**: Caller executes actions (LLM calls, tool runs) and feeds events back. Enables:
- Offline operation
- Different async runtimes
- Comprehensive testing
- Replay/debugging
