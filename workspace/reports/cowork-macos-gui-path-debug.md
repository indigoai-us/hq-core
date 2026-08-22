# DEBUG REPORT — Cowork cannot resolve HQ Desktop's managed commands

**Date:** 2026-08-22
**Company:** none (hq-core repository work)
**Scope lock:** `core/packages/hq-pack-cowork` and `core/scripts/tests/cowork-plugin-mcp-json.test.sh`
**Investigation depth:** 1 hypothesis tested

## Root Cause

**Status:** CONFIRMED

Cowork's macOS GUI environment does not inherit the interactive-shell PATH entry for HQ Desktop's managed toolchain. The plugin manifest launches a bare `node`, so the MCP server never starts in that environment; if launched by an override, the server's `hq`/`qmd` resolver still omits the managed `npm-global/bin` directory.

## Evidence

| Evidence | Supports | Refutes |
|---|---|---|
| `.mcp.json` declares `"command": "node"` | Hypothesis 1 | — |
| `resolveBin()` checks inherited PATH, common home dirs, Homebrew, and system dirs but not `~/Library/Application Support/Indigo HQ/toolchain` | Hypothesis 1 | — |
| `core/scripts/compose-settings-path.sh` documents and tests the managed node and npm-global directories used by HQ Desktop | Hypothesis 1 | — |

## Pattern Classification

**Primary:** CONFIG MISMATCH

## Recommended Fix

**Minimal change:** launch the bundled server through a system shell wrapper that resolves `node` from the managed toolchain, and teach the server resolver to find `hq` and `qmd` in the same toolchain.
**Files to touch:** plugin manifest, bundled server, one launcher script, and the existing packaged-plugin regression test.
**Risk of fix:** LOW — existing absolute overrides and fallback locations remain ahead of or alongside the new managed candidates.
**Regression test:** build and unpack the plugin, launch it with a stripped PATH and a managed toolchain under a home path containing spaces, then call `hq_whoami` and `hq_search` over MCP.
