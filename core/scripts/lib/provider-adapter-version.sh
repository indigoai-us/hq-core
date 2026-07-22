#!/usr/bin/env bash
# hq-core: public
# provider-adapter-version.sh — single source of HQ_ADAPTER_CONTRACT_VERSION.
#
# Source this file (do not redefine the version elsewhere). The on-box reader
# core/scripts/hq-adapter-contract-version.sh sources the same file so boxes
# and dispatchers share one string.

# Contract version (dotted). Bump when the adapter function signatures, the
# capability key set/enums, or the build_invocation prompt-by-file rule change.
export HQ_ADAPTER_CONTRACT_VERSION="1.0.0"
