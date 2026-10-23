#!/usr/bin/env bash
# Regression: feedback_436e4037-b61c-4a70-a89d-86712d303f4f. On Windows Git
# Bash, hook helpers that detach with setsid lose the desktop host's hidden
# console, so every native child opens a visible console window. Each hook
# must skip setsid on MSYS/Cygwin and keep it on POSIX hosts.
#
# The check reads bash's own OSTYPE (msys on Git Bash and MSYS2, cygwin on
# Cygwin). It must never fork uname: hq_setsid_available runs on the
# master-hook hot path, whose external-process budget CI enforces.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
STUB_BIN="$TMP_ROOT/bin"
UNAME_LOG="$TMP_ROOT/uname.log"
mkdir -p "$STUB_BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/setsid"
# Any uname call is recorded; the test fails if the log is non-empty.
printf '#!/usr/bin/env bash\necho called >> "%s"\necho Linux\n' "$UNAME_LOG" > "$STUB_BIN/uname"
chmod +x "$STUB_BIN/uname" "$STUB_BIN/setsid"

fail=0
for hook in master-hook.sh hook-gate.sh check-client-health.sh check-hq-update.sh; do
  file="$ROOT/.claude/hooks/$hook"
  if grep -q 'if command -v setsid' "$file"; then
    echo "FAIL: $hook still probes setsid directly" >&2
    fail=1
    continue
  fi
  if ! grep -q 'if hq_setsid_available; then' "$file"; then
    echo "FAIL: $hook does not guard its setsid launch" >&2
    fail=1
    continue
  fi
  def="$(sed -n '/^hq_setsid_available() {$/,/^}$/p' "$file")"
  if [ -z "$def" ]; then
    echo "FAIL: $hook has no hq_setsid_available" >&2
    fail=1
    continue
  fi
  for ostype in msys cygwin; do
    if PATH="$STUB_BIN:$PATH" bash -c "OSTYPE=$ostype; $def; hq_setsid_available"; then
      echo "FAIL: $hook uses setsid on OSTYPE=$ostype" >&2
      fail=1
    fi
  done
  for ostype in linux-gnu darwin24; do
    if ! PATH="$STUB_BIN:$PATH" bash -c "OSTYPE=$ostype; $def; hq_setsid_available"; then
      echo "FAIL: $hook stopped using setsid on OSTYPE=$ostype" >&2
      fail=1
    fi
  done
done
if [ -s "$UNAME_LOG" ]; then
  echo "FAIL: hq_setsid_available forks uname on the hook hot path" >&2
  fail=1
fi
[ "$fail" -eq 0 ] || exit 1
echo 'hook detach msys console: ok'
