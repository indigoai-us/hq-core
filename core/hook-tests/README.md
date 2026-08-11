# Hook fixtures (`core/hook-tests/`)

This directory holds **hook fixtures**: declarative files that pin what an HQ
hook is expected to do. `hq doctor` discovers them here at runtime and uses them
to report per-hook test coverage (and, under `hq doctor --deep-test`, to
actually execute the hook and check its behaviour).

The split is deliberate: **all executable logic lives in the `hq` CLI, but the
per-hook expectation _data_ lives here in the HQ tree.** A hook and its test then
ship in the same hq-core commit, and adding or changing a test needs **no CLI
release** — drop a YAML file here and the next `hq doctor` run picks it up.

> The engine that reads these files is in `hq-cli`
> (`src/lib/doctor/fixtures/`). This document is the authoritative reference for
> the file format; it is versioned alongside the fixtures so maintainers can add
> cases without reading CLI source.

## Where a fixture lives

```
core/hook-tests/<hook-id>.yaml
```

One file per hook id. The **hook id** is the identity the doctor uses for a hook:
the id passed to `hook-gate.sh` in the hook's `.claude/settings.json`
registration (the common case), or the hook script's basename without `.sh`.
For example `block-core-writes.sh` → hook id `block-core-writes` →
`core/hook-tests/block-core-writes.yaml`.

A `*.yaml` file here is treated as a fixture only if it carries a
`schemaVersion` (or a `cases`/`hookId` key). Other YAML config that lives in this
directory — notably `allowed-divergence.yaml` — is **not** a fixture and is
ignored by fixture discovery.

## Schema

```yaml
# hook id this fixture guards. Optional — defaults to the filename stem.
hookId: block-core-writes

# REQUIRED. The fixture schema version. Currently the only supported value is 1.
# A fixture declaring a version the CLI does not recognise is reported UNKNOWN
# for that hook (never PASS), so a fixture written for a future schema fails
# safe instead of silently passing on a stale expectation.
schemaVersion: 1

# The named cases. May be empty. Each case name must be unique within the file.
cases:
  - name: blocks-core-edit           # REQUIRED, unique within this fixture
    event: PreToolUse                # REQUIRED lifecycle event, e.g. PreToolUse
    tool: Edit                       # REQUIRED tool name, e.g. Edit, Bash, Read
    input:                           # REQUIRED tool input payload (any shape)
      file_path: core/foo.sh
    expect: block                    # REQUIRED expected outcome (see below)

  - name: allows-repo-edit
    event: PreToolUse
    tool: Edit
    input:
      file_path: repos/public/example/README.md
    expect: allow
```

### `expect` — the expected outcome

Exactly one of three forms:

| Form                     | Meaning                                                    |
| ------------------------ | --------------------------------------------------------- |
| `block`                  | The hook is expected to **block** the action.             |
| `allow`                  | The hook is expected to **allow** the action.             |
| `{ stderr: "<pattern>" }`| The hook's **stderr** is expected to match `<pattern>`.   |

`stderr` patterns are treated as regular expressions, falling back to a literal
substring match when the pattern is not valid regex.

### `expectedFailure` — pinning a known, unfixed defect

A case may carry an `expectedFailure` marker with a **required** `reason`:

```yaml
  - name: manifest-read-is-allowed
    event: PreToolUse
    tool: Read
    input:
      file_path: companies/manifest.yaml
    expect: allow
    expectedFailure:
      reason: >
        mandatory-scope-authorizer strips the extension and treats "manifest"
        as a company slug, so this read is wrongly blocked. Tracked, unfixed.
```

Behaviour of an `expectedFailure` case under `--deep-test`:

| Case result           | Reported as    | Why                                              |
| --------------------- | -------------- | ------------------------------------------------ |
| still fails           | `KNOWN-DEFECT` | the pinned defect is still present (not a `FAIL`)|
| unexpectedly passes   | `WARN`         | the marker is **stale** — remove it              |

`KNOWN-DEFECT` is always printed and counted separately, but never fails the
command. This keeps a defect mechanically visible until it is fixed, without
shipping a doctor that reports red on a healthy install.

## What the doctor reports

- **UNTESTED** — a registered hook with no fixture. Every such hook is named,
  and the run summary prints a coverage line of the form `tested/total`. This is
  the forcing function that keeps coverage growing: a mostly-unfixtured doctor
  must never read as a clean bill of health.
- **UNKNOWN** — a fixture whose `schemaVersion` the CLI does not recognise. The
  message names both the declared and the supported versions. Never `PASS`.
- **WARN (orphan)** — a fixture whose hook id is not registered anywhere, e.g. a
  leftover from a deleted hook.
- **WARN (malformed)** — a fixture that is not valid YAML or does not match this
  schema. It is skipped and named; its hook still counts as UNTESTED.

Default `hq doctor` discovers and validates fixtures and reports coverage; it
does **not** execute hooks. `hq doctor --deep-test` executes the cases through
the real `hook-gate.sh` path and reports `PASS`/`FAIL`/`KNOWN-DEFECT` per case.

## Adding a fixture

1. Create `core/hook-tests/<hook-id>.yaml` using the schema above.
2. Give it at least one `expect: block` case and one `expect: allow` case, so
   neither an always-block nor an always-allow hook can pass.
3. Run `hq doctor` — the hook should drop off the UNTESTED list and the coverage
   ratio should tick up.
4. Run `hq doctor --deep-test` to confirm the hook actually behaves as declared.

Because fixtures are discovered from the HQ tree at runtime, no CLI release is
needed — the new file is live on the next run.
