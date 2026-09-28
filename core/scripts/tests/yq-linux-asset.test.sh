#!/usr/bin/env bash
set -euo pipefail

helper="${YQ_LINUX_ASSET_HELPER:-core/scripts/ci/yq-linux-asset.sh}"
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_asset() {
  local machine="$1" expected="$2" actual
  actual="$(bash "$helper" "$machine")" || fail "$machine mapping exited nonzero"
  [[ "$actual" == "$expected" ]] || fail "$machine expected $expected, found $actual"
}

assert_asset x86_64 yq_linux_amd64
assert_asset amd64 yq_linux_amd64
assert_asset aarch64 yq_linux_arm64
assert_asset arm64 yq_linux_arm64
if bash "$helper" riscv64 >/dev/null 2>&1; then
  fail 'unsupported architecture unexpectedly selected an asset'
fi

echo 'PASS: yq Linux assets match x86_64 and ARM64 architectures'
