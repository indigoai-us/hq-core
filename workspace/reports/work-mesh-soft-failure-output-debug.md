# DEBUG REPORT — Work Mesh interactive failures can exit without output

**Date:** 2026-08-22
**Company:** none resolved
**Scope lock:** `core/scripts/work-mesh.mjs` and `core/scripts/tests/work-mesh-helper.test.sh`
**Investigation depth:** 3 hypotheses tested

## Root Cause

**Status:** CONFIRMED

The shared `failSoft()` output path prints human-readable diagnostics only when `HQ_WORK_MESH_DEBUG` is truthy, so ordinary interactive auth, company, network, and API failures exit without any explanation. The disabled branch duplicates skip handling and prints only in JSON mode, producing the same silent result without passing through `failSoft()`.

## Evidence

| Evidence | Supports | Refutes |
|---|---|---|
| `failSoft()` gates stderr behind `HQ_WORK_MESH_DEBUG` | Hypothesis 1 | — |
| The disabled branch returns after JSON-only output | Hypothesis 1 | — |
| Direct disabled and logged-out probes both produced zero output bytes | Hypothesis 1 | — |
| `work-mesh.sh` directly execs the Node helper without redirection | — | Hypothesis 2 |
| Argument parsing only sets `opts.silent` for an explicit `--silent` | — | Hypothesis 3 |

## Pattern Classification

**Primary:** CONFIG MISMATCH

## What Was Ruled Out

- **Hypothesis 2** (HOOK ORDERING): the shell wrapper does not discard stdout or stderr.
- **Hypothesis 3** (STATE CORRUPTION): interactive invocations do not acquire an implicit `silent` option.

## Recommended Fix

**Minimal change:** Make `failSoft()` emit one redacted stderr diagnostic for all non-silent interactive calls, and route the disabled branch through the same helper.
**Files to touch:** `core/scripts/work-mesh.mjs`, `core/scripts/tests/work-mesh-helper.test.sh`
**Risk of fix:** LOW — JSON behavior and strict-mode exit semantics remain unchanged; `--silent` continues to suppress human-readable output.
**Regression test:** Exercise successful, disabled, logged-out, unresolved-company, network, and API outcomes and assert that human-readable messages are distinct and do not expose bearer tokens.
