#!/bin/bash
# Regression tests for .claude/hooks/block-foreground-timeout-over-harness-ceiling.sh.
#
# The hook is now a THIN SHIM over `hq core timeout-guard` (the decision logic
# and the identity gate live in the CLI, tested there). This suite locks
# the SHIM contract: block iff the guard exits 2, fail OPEN otherwise (guard
# allows, old CLI without the subcommand, or no hq on PATH at all). Run:
#   bash core/scripts/tests/block-foreground-timeout.test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/block-foreground-timeout-over-harness-ceiling.sh"
BASH_ABS="$(command -v bash)"

pass=0; fail=0
run() {  # run <expect> <desc> <PATH-with-fake-hq-or-empty>
  local expect="$1" desc="$2" path="$3" code
  # Invoke bash by absolute path so a restricted PATH hides only `hq`, not bash.
  printf '{"tool_input":{"command":"timeout 2400s ./x"}}' \
    | PATH="$path" "$BASH_ABS" "$HOOK" >/dev/null 2>&1; code=$?
  if [ "$code" -eq "$expect" ]; then
    pass=$((pass+1)); printf 'ok   [%s] %s\n' "$code" "$desc"
  else
    fail=$((fail+1)); printf 'FAIL [exp %s got %s] %s\n' "$expect" "$code" "$desc"
  fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Fake `hq` that exits 2 (guard blocks).
mkdir -p "$TMP/block"
cat > "$TMP/block/hq" <<'SH'
#!/bin/bash
cat >/dev/null
[ "$1 $2" = "core timeout-guard" ] && exit 2
exit 0
SH
# Fake `hq` that exits 0 (guard allows).
mkdir -p "$TMP/allow"
cat > "$TMP/allow/hq" <<'SH'
#!/bin/bash
cat >/dev/null
exit 0
SH
# Fake `hq` that exits 1 (old CLI: unknown subcommand).
mkdir -p "$TMP/old"
cat > "$TMP/old/hq" <<'SH'
#!/bin/bash
cat >/dev/null
echo "error: unknown command 'timeout-guard'" >&2
exit 1
SH
chmod +x "$TMP"/*/hq

run 2 "guard exit 2 -> shim blocks"                 "$TMP/block:/usr/bin:/bin"
run 0 "guard exit 0 -> shim allows"                 "$TMP/allow:/usr/bin:/bin"
run 0 "old CLI (exit 1, no subcommand) -> fail open" "$TMP/old:/usr/bin:/bin"
run 0 "no hq on PATH -> fail open"                  "/nonexistent-dir-xyz"

echo "----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
