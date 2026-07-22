# Provider adapter contract

# hq-core: public

Shell contract every fleet provider runtime must satisfy. The contract lives in
hq-core (`core/scripts/lib/`) so agent boxes receive it via
`hq rescue --hq-root` and self-update. **Contract only** — concrete provider
implementations land under `core/scripts/lib/provider-adapters/<provider>.sh`
in follow-on stories (codex / grok / claude).

## Contract version

`1.0.0`

Single source of truth: `core/scripts/lib/provider-adapter-version.sh`
exports `HQ_ADAPTER_CONTRACT_VERSION`. `core/scripts/lib/provider-adapter.sh`
sources that file rather than redefining the string. `core/core.yaml` records
the same value as `adapterContractVersion`. The on-box reader
`core/scripts/hq-adapter-contract-version.sh` prints the installed version or
exits 3 with `adapter contract not installed`.

## Provider list

```bash
HQ_ADAPTER_PROVIDERS="codex grok claude"
```

`hq_adapter_load` exits 1 with `unknown provider: <name>` for any id outside
that list and never falls back to another provider.

## Required functions

| Function | Role |
|----------|------|
| `hq_adapter_id` | Print the provider id (one of the three) |
| `hq_adapter_capabilities` | Newline-delimited `key=value` capability descriptor |
| `hq_adapter_build_invocation` | Emit the provider command string (three args) |
| `hq_adapter_extract_reply` | Print the final assistant message from captured output |
| `hq_adapter_emit_usage` | Emit usage / token accounting for the turn |

Loader:

```bash
hq_adapter_load <provider>
```

Sources `core/scripts/lib/provider-adapters/<provider>.sh` (or
`$HQ_ADAPTER_DIR/<provider>.sh` when set for tests). Exits 1 with
`adapter contract violation: <provider> missing <fn>` when any of the five
functions is missing after source. On violation, default no-provider stubs
are restored so partially loaded symbols do not remain in scope.

## Capability descriptor

`hq_adapter_capabilities` emits exactly these keys, one `key=value` per line:

| Key | Allowed values |
|-----|----------------|
| `system_prompt` | `native` \| `emulated` \| `absent` |
| `resume` | `native` \| `emulated` \| `absent` |
| `hooks` | `native` \| `emulated` \| `absent` |
| `plan_mode` | `native` \| `emulated` \| `absent` |
| `durable_writes` | `native` \| `emulated` \| `absent` |
| `telegram_eligible` | `yes` \| `no` |
| `usage_source` | `transcript` \| `cli` \| `unavailable` |

## `hq_adapter_build_invocation`

Signature (exactly three arguments):

```bash
hq_adapter_build_invocation <task_file_path> <workdir_expression> <preflight_mode>
```

- `task_file_path` — path to the task / prompt file (a PATH, not the bytes)
- `workdir_expression` — shell expression or path used as the process cwd
- `preflight_mode` — `on` or `off` (mirrors `sessionPreflightEnabled`)

Missing or invalid arity exits non-zero.

### Prompt-by-file rule (load-bearing)

**No adapter may interpolate prompt bytes into the emitted command string.**

The task file path travels as a path argument. Adapters must not embed
`"$(cat …)"` (or equivalent) of the task file into the command.

Status of today's hq-pro inline renders (pre-adapter):

| Provider | Prompt interpolation today | Notes |
|----------|----------------------------|--------|
| codex | **violates** | `src/agents/inbox-watcher-cli.ts` uses `"$(cat …)"` on the task file |
| grok | **violates** | `src/agents/grok-runtime.ts` uses `"$(cat …)"` on the task file |
| claude | **conforms** | `src/agents/claude-runtime.ts` passes a taskfile env / path, not prompt bytes |

Follow-on adapter implementations (US-501+) must satisfy this rule so dispatch
never re-introduces silent prompt concatenation.

## Delivery

- `core/` is locked in `core/core.yaml` `rules.locked`; there is no `exclude`
  entry for `core/scripts/lib/provider-adapters/`, so `hq rescue --hq-root`
  installs the adapter directory.
- `adapterContractVersion` in `core/core.yaml` must match
  `HQ_ADAPTER_CONTRACT_VERSION`.
- Delivery and contract tests run without real `codex`, `grok`, or `claude`
  binaries on `PATH` (stub fixtures only).

## Related

- Loader + version stamp: `core/scripts/lib/provider-adapter.sh`,
  `core/scripts/lib/provider-adapter-version.sh`
- On-box reader: `core/scripts/hq-adapter-contract-version.sh`
- Tests: `core/scripts/tests/provider-adapter-contract.test.sh`,
  `core/scripts/tests/provider-adapter-delivery.test.sh`
- Session-runtime adapters (`session_provider_dispatch`,
  `provider-adapter-{claude,codex,grok}.sh`) are a separate
  `hq-agent-session` surface and are not this contract.
