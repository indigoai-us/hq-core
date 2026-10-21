#!/usr/bin/env bash
# install-shellcheck.sh must apt-install only on GitHub-hosted runners. On a
# self-hosted runner it must use the pinned, checksum-verified download even
# when passwordless sudo works, and it must name a missing image tool.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SCRIPT="$ROOT/core/scripts/ci/install-shellcheck.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A PATH with only the tools the script needs, so a shellcheck installed on
# the machine running this test is never found.
make_path() {
  local dir="$1"
  shift
  mkdir -p "$dir"
  local tool real
  for tool in bash env sed awk mktemp rm mkdir install cat chmod "$@"; do
    real="$(command -v "$tool")" || fail "test needs $tool"
    ln -sf "$real" "$dir/$tool"
  done
  # Report a Linux ARM host whatever machine runs the test.
  cat > "$dir/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -s) echo Linux ;;
  -m) echo aarch64 ;;
  *) echo Linux ;;
esac
EOF
  # Passwordless sudo that logs and runs the command.
  cat > "$dir/sudo" <<EOF
#!/usr/bin/env bash
echo "sudo \$*" >> "$TMP/calls"
[ "\${1:-}" = -n ] && shift
[ "\${1:-}" = true ] && exit 0
"\$@"
EOF
  # apt-get "installs" a fake shellcheck next to itself.
  cat > "$dir/apt-get" <<EOF
#!/usr/bin/env bash
echo "apt-get \$*" >> "$TMP/calls"
if [ "\${1:-}" = install ]; then
  printf '#!/usr/bin/env bash\necho ShellCheck\necho "version: apt"\n' > "$dir/shellcheck"
  chmod +x "$dir/shellcheck"
fi
EOF
  # curl writes bytes that do not match the pinned checksum.
  cat > "$dir/curl" <<EOF
#!/usr/bin/env bash
echo "curl \$*" >> "$TMP/calls"
while [ \$# -gt 0 ]; do
  if [ "\$1" = -o ]; then printf 'not the release' > "\$2"; shift; fi
  shift
done
EOF
  chmod +x "$dir/uname" "$dir/sudo" "$dir/apt-get" "$dir/curl"
}

# 1. GitHub-hosted with passwordless sudo: apt path.
make_path "$TMP/hosted" sha256sum tar xz
: > "$TMP/calls"
out="$(RUNNER_ENVIRONMENT=github-hosted RUNNER_TEMP="$TMP/rt1" GITHUB_PATH= \
  PATH="$TMP/hosted" bash "$SCRIPT" 2>&1)" || fail "hosted apt install failed: $out"
grep -Fq 'apt-get install -y -qq shellcheck' "$TMP/calls" \
  || fail 'a GitHub-hosted runner with sudo must apt-install shellcheck'
grep -Fq 'version: apt' <<< "$out" || fail 'hosted run must report the apt shellcheck version'

# 2. Self-hosted with passwordless sudo: no sudo, pinned download verified.
make_path "$TMP/self" sha256sum tar xz
: > "$TMP/calls"
if out="$(RUNNER_ENVIRONMENT=self-hosted RUNNER_TEMP="$TMP/rt2" GITHUB_PATH= \
  PATH="$TMP/self" bash "$SCRIPT" 2>&1)"; then
  fail 'a download with a wrong checksum must fail the install'
fi
if grep -Fq 'sudo' "$TMP/calls"; then
  fail "a self-hosted runner must never use sudo or apt: $(cat "$TMP/calls")"
fi
grep -Fq 'curl -fsSL --retry 3 -o' "$TMP/calls" \
  || fail 'a self-hosted runner must download the pinned release'
grep -Fq 'releases/download/v0.10.0/shellcheck-v0.10.0.linux.aarch64.tar.xz' "$TMP/calls" \
  || fail 'the download must use the pinned version and the runner architecture'
grep -Fq 'checksum mismatch' <<< "$out" || fail "expected a checksum mismatch, got: $out"
[ ! -e "$TMP/rt2/bin/shellcheck" ] || fail 'an unverified binary must not be installed'

# 3. Unset runner environment (local run) behaves like self-hosted.
: > "$TMP/calls"
env -u RUNNER_ENVIRONMENT RUNNER_TEMP="$TMP/rt3" GITHUB_PATH= PATH="$TMP/self" \
  bash "$SCRIPT" >/dev/null 2>&1 || true
if grep -Fq 'sudo' "$TMP/calls"; then
  fail 'without RUNNER_ENVIRONMENT the installer must not use sudo'
fi

# 4. Missing xz on the runner image: clear error before any download.
make_path "$TMP/noxz" sha256sum tar
: > "$TMP/calls"
if out="$(RUNNER_ENVIRONMENT=self-hosted RUNNER_TEMP="$TMP/rt4" GITHUB_PATH= \
  PATH="$TMP/noxz" bash "$SCRIPT" 2>&1)"; then
  fail 'a runner without xz must fail the install'
fi
grep -Fq 'xz is required on the runner image' <<< "$out" \
  || fail "a missing xz must be named, got: $out"
if grep -Fq 'curl' "$TMP/calls"; then
  fail 'the tool check must run before the download'
fi

echo 'PASS: shellcheck installer uses apt only on GitHub-hosted runners and verifies the pinned download elsewhere'
