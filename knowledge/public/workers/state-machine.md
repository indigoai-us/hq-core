---
type: reference
domain: [engineering]
status: canonical
tags: [worker, state-machine, execution-flow, lifecycle, fsm]
relates_to: []
---

# Worker State Machine

Workers follow an explicit state machine for predictable execution. Inspired by Loom's agent FSM.

## States

```
Idle → Loading → Planning → Executing → Verifying → PostHook → Completed
                              ↓
                            Error → (retry or fail)
```

| State | Description |
|-------|-------------|
| `idle` | Worker ready, no active task |
| `loading` | Loading context (worker.yaml, knowledge files) |
| `planning` | Analyzing task, determining approach |
| `executing` | Running skill logic |
| `verifying` | Running verification checks |
| `post_hook` | Auto-checkpoint, metrics logging |
| `completed` | Skill finished successfully |
| `error` | Recoverable error, may retry |

## State Transitions

| From | Event | To |
|------|-------|----|
| idle | skill_requested | loading |
| loading | context_loaded | planning |
| loading | load_failed | error |
| planning | plan_ready | executing |
| executing | execution_done | verifying |
| executing | execution_failed | error |
| verifying | verification_passed | post_hook |
| verifying | verification_failed | error |
| post_hook | hook_complete | completed |
| error | retry | loading |
| error | max_retries | completed (with error) |

## State in Thread

When saving a thread, capture current worker state:

```json
{
  "worker": {
    "id": "cfo-{company}",
    "skill": "mrr",
    "state": "completed",
    "started_at": "ISO8601",
    "completed_at": "ISO8601",
    "error": null
  }
}
```

## Hooks

### post_execute

Runs after successful execution, before completion:
- `auto_checkpoint` - Save thread to workspace/threads/
- `log_metrics` - Append to workspace/metrics/metrics.jsonl

### on_error

Runs when entering error state:
- `log_error` - Record error details
- `checkpoint_error_state` - Save thread with error info

## worker.yaml Schema Addition

```yaml
worker:
  id: example-worker
  # ... existing fields ...

state_machine:
  enabled: true
  max_retries: 1

  hooks:
    post_execute:
      - auto_checkpoint
      - log_metrics
    on_error:
      - log_error
      - checkpoint_error_state
```

## Benefits

1. **Predictable** - Every worker follows same lifecycle
2. **Debuggable** - State captured in threads
3. **Resilient** - Retry logic built-in
4. **Observable** - Metrics on state transitions

## See Also

- [Thread Schema](../hq-core/thread-schema.md) - Thread format
- [Loom State Machine](../loom/state-machine.md) - Inspiration
- [Worker Framework](./README.md) - Worker docs
