---
id: hq-codex-sdk-config-vs-typed-fields
title: Route codex-sdk options through typed ThreadOptions first, CodexOptions.config only as fallback
when: codex || sdk
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
public: true
version: 1
created: 2026-04-25
updated: 2026-04-25
source: session-learning
---

## Rule

When wrapping `@openai/codex-sdk`, follow this two-tier routing for any option you want to forward to the spawned `codex` CLI subprocess:

1. **Tier 1 — typed field on the matching options interface.** If the SDK exposes the option as a first-class typed field, use that field. Match the scope:
   - Per-turn / per-thread cost knobs (e.g. `modelReasoningEffort`) → `ThreadOptions`. The SDK serializes these onto its own `--config model_reasoning_effort=...` arg path.
   - Per-instance / global behaviour → `CodexOptions` typed fields.
2. **Tier 2 — `CodexOptions.config` (generic catch-all).** If the SDK does NOT expose the flag as a typed field, route it via the nested `config` object. Example: a Codex CLI feature flag like `fast_mode` is not a typed `CodexOptions` field, so pass it as `config: { features: { fast_mode: true } }`. The SDK's `serializeConfigOverrides` flattens dotted paths and forwards them as `--config features.fast_mode=true` when spawning the codex subprocess — semantically identical to `--enable fast_mode`.

**Never** stuff a Tier-1 option into `config` "because both work" — it strips type-safety and can collide with the SDK's own serializer if the field name later becomes typed. **Never** invent a typed field the SDK doesn't expose; route through `config`.

Reasoning effort is per-turn-cost (Thread); fast_mode is a CLI feature toggle (Codex constructor). Keep that scope discipline when deciding which interface receives the option.

## Rationale

Two failure modes drove this rule:

- **Skipping Tier 1** loses TypeScript guarantees. The SDK's own `serializeConfigOverrides` may name-mangle differently than the typed setter, producing a CLI arg path that the codex binary doesn't recognise. The bug surfaces as "the flag silently does nothing" — no error, no log line, just stale behaviour.
- **Skipping Tier 2 / fabricating a typed field** is a compile-time error if `tsc` is honest, or a silent type-cast if you `as any` your way out. Either way the option never reaches the subprocess.

The `config: { dotted: { path: value } }` escape hatch exists exactly because Codex CLI ships flags faster than the SDK can type them. Use it knowingly, not as a default.
