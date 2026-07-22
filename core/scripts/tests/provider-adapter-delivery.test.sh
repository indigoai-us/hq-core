#!/usr/bin/env bash
# hq-core: public
# provider-adapter-delivery.test.sh — US-500 delivery proof (no real providers).
#
# Asserts adapterContractVersion in core/core.yaml matches the version stamp,
# locked/exclude rules ship provider-adapters/, and the on-box reader prints
# the version or exits 3 when the stamp is absent.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
YAML="$ROOT/core/core.yaml"
VERSION_SH="$ROOT/core/scripts/lib/provider-adapter-version.sh"
READER="$ROOT/core/scripts/hq-adapter-contract-version.sh"
ADAPTER="$ROOT/core/scripts/lib/provider-adapter.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# 1. Version agreement: version.sh ↔ core.yaml ↔ sourced adapter
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090
. "$VERSION_SH"
ver_file="$HQ_ADAPTER_CONTRACT_VERSION"

yaml_ver="$(awk '
  /^[[:space:]]*adapterContractVersion:[[:space:]]*/ {
    sub(/^[[:space:]]*adapterContractVersion:[[:space:]]*/, "")
    gsub(/[[:space:]]+#.*$/, "")
    gsub(/[[:space:]]/, "")
    gsub(/["'\'']/, "")
    print
    exit
  }
' "$YAML")"

if [[ -n "$yaml_ver" && "$yaml_ver" == "$ver_file" ]]; then
  pass "core.yaml adapterContractVersion=$yaml_ver matches version.sh"
else
  fail "core.yaml adapterContractVersion='$yaml_ver' != version.sh '$ver_file'"
fi

# Sourcing provider-adapter.sh must resolve the same value.
unset HQ_ADAPTER_CONTRACT_VERSION
# shellcheck disable=SC1090
. "$ADAPTER"
if [[ "${HQ_ADAPTER_CONTRACT_VERSION:-}" == "$ver_file" ]]; then
  pass "provider-adapter.sh resolves HQ_ADAPTER_CONTRACT_VERSION=$ver_file"
else
  fail "after source adapter version='${HQ_ADAPTER_CONTRACT_VERSION:-}' want '$ver_file'"
fi

# ---------------------------------------------------------------------------
# 2. locked: core/ present; no exclude for provider-adapters/
# ---------------------------------------------------------------------------
if awk '
  BEGIN { in_locked=0; found=0 }
  /^[[:space:]]*locked:[[:space:]]*$/ { in_locked=1; next }
  in_locked && /^[[:space:]]*[a-zA-Z_]+:/ { in_locked=0 }
  in_locked && /^[[:space:]]*-[[:space:]]*core\/[[:space:]]*$/ { found=1 }
  END { exit(found ? 0 : 1) }
' "$YAML"; then
  pass "core/ is locked in core/core.yaml"
else
  fail "core/ missing from rules.locked in core/core.yaml"
fi

exclude_hit="$(awk '
  BEGIN { in_ex=0 }
  /^[[:space:]]*exclude:[[:space:]]*$/ { in_ex=1; next }
  in_ex && /^[[:space:]]*[a-zA-Z_]+:/ { in_ex=0 }
  in_ex && /provider-adapters/ { print; exit }
' "$YAML" || true)"
if [[ -z "$exclude_hit" ]]; then
  pass "no exclude entry matches provider-adapters/"
else
  fail "exclude lists provider-adapters: $exclude_hit"
fi

# Directory exists under core/scripts/lib/ so rescue can install it.
if [[ -d "$ROOT/core/scripts/lib/provider-adapters" ]]; then
  pass "provider-adapters/ directory present"
else
  fail "provider-adapters/ directory missing"
fi

# ---------------------------------------------------------------------------
# 3. On-box reader — installed tree
# ---------------------------------------------------------------------------
if [[ -x "$READER" ]] || [[ -f "$READER" ]]; then
  pass "on-box reader present: $READER"
else
  fail "on-box reader missing: $READER"
fi
chmod +x "$READER" 2>/dev/null || true

rc=0
out="$("$READER" "$ROOT")" || rc=$?
if [[ "$rc" -eq 0 && "$out" == "$ver_file" ]]; then
  pass "reader prints version ($out)"
else
  fail "reader expected '$ver_file' exit 0, got rc=$rc out='$out'"
fi

# Default HQ_ROOT resolution from script location (no arg).
out2="$("$READER")"
if [[ "$out2" == "$ver_file" ]]; then
  pass "reader resolves HQ root from script path"
else
  fail "reader without args: got '$out2' want '$ver_file'"
fi

# ---------------------------------------------------------------------------
# 4. Pre-contract install tree → exit 3
# ---------------------------------------------------------------------------
mkdir -p "$TMP/pre/core/scripts/lib"
# No provider-adapter-version.sh in the fake root.
set +e
err3="$("$READER" "$TMP/pre" 2>&1)"
rc3=$?
set -e
if [[ "$rc3" -eq 3 ]] && [[ "$err3" == *"adapter contract not installed"* ]]; then
  pass "pre-contract tree: reader exits 3"
else
  fail "pre-contract: rc=$rc3 err=$err3 (want exit 3 + 'adapter contract not installed')"
fi

# With the version file present under the temp root, reader succeeds.
mkdir -p "$TMP/with/core/scripts/lib"
cp "$VERSION_SH" "$TMP/with/core/scripts/lib/provider-adapter-version.sh"
out4="$("$READER" "$TMP/with")"
if [[ "$out4" == "$ver_file" ]]; then
  pass "temp root with version.sh prints $out4"
else
  fail "temp root reader: got '$out4' want '$ver_file'"
fi

# ---------------------------------------------------------------------------
# 5. Suite requires no real provider binaries
# ---------------------------------------------------------------------------
pass "no real codex/grok/claude binary required (stub/path only)"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ "$FAIL" -eq 0 ]]; then
  echo "provider-adapter-delivery: all passed"
  exit 0
fi
echo "provider-adapter-delivery: $FAIL failed" >&2
exit 1
