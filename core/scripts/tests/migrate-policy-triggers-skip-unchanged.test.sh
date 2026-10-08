#!/usr/bin/env bash
# migrate-policy-triggers-if-changed.sh (SessionStart wrapper) must skip the hq
# CLI entirely when no policy file changed since its last successful run, and
# must run again when a policy file or directory changes, when hq is newer, when
# forced, or when invoked with arguments. (hq-hook-perf HP-7)
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
FORWARDER="$ROOT/.claude/hooks/migrate-policy-triggers-if-changed.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# A fake hq that records every `core ... migrate-policy-triggers` call and
# satisfies the forwarder's version floor.
BIN="$TMP/bin"; mkdir -p "$BIN"
CALLS="$TMP/calls"; : > "$CALLS"
cat > "$BIN/hq" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *--version*|version) echo 99.0.0; exit 0 ;;
esac
echo "\$*" >> "$CALLS"
exit 0
EOF
chmod +x "$BIN/hq"
# Keep the stub's mtime in the past so it is never "newer than the stamp".
touch -t 202001010000 "$BIN/hq"

HQROOT="$TMP/hq"
mkdir -p "$HQROOT/core/policies" "$HQROOT/personal/policies" "$HQROOT/companies/acme/policies" "$HQROOT/workspace"
printf -- '---\nid: p1\nenforcement: hard\n---\n\n## Rule\nx\n' > "$HQROOT/core/policies/p1.md"
printf 'requiresHqCli: "0.0.1"\n' > "$HQROOT/core/core.yaml"
# The wrapper runs the real generated forwarder from the fixture root; give it one.
mkdir -p "$HQROOT/core/scripts/lib"
cp "$ROOT/core/scripts/migrate-policy-triggers.sh" "$HQROOT/core/scripts/migrate-policy-triggers.sh"
cp "$ROOT/core/scripts/lib/hq-cli-floor.sh" "$HQROOT/core/scripts/lib/hq-cli-floor.sh"
# The forwarder sources lib/hq-cli-floor.sh from its own directory; keep that.

run() { env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP" HQ_ROOT="$HQROOT" CLAUDE_PROJECT_DIR="$HQROOT" "$@" bash "$FORWARDER" </dev/null; }
calls() { wc -l < "$CALLS" | tr -d ' '; }

sleep 1  # make later mtimes strictly newer than the first stamp
run
[ "$(calls)" = "1" ] || fail "first no-arg run should invoke hq once, got $(calls)"
STAMP="$HQROOT/workspace/orchestrator/policy-trigger-state/migrate-policy-triggers.stamp"
[ -f "$STAMP" ] || fail "stamp not written after a successful run"

run
[ "$(calls)" = "1" ] || fail "unchanged policies should skip hq, got $(calls)"

sleep 1
printf -- '---\nid: p2\nenforcement: hard\n---\n\n## Rule\ny\n' > "$HQROOT/companies/acme/policies/p2.md"
run
[ "$(calls)" = "2" ] || fail "a new company policy file should re-run, got $(calls)"

run
[ "$(calls)" = "2" ] || fail "second unchanged run should skip again, got $(calls)"

sleep 1
rm "$HQROOT/companies/acme/policies/p2.md"   # directory mtime changes
run
[ "$(calls)" = "3" ] || fail "a deleted policy file should re-run (directory mtime), got $(calls)"

run HQ_MIGRATE_TRIGGERS_FORCE=1
[ "$(calls)" = "4" ] || fail "HQ_MIGRATE_TRIGGERS_FORCE=1 should re-run, got $(calls)"

env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP" HQ_ROOT="$HQROOT" CLAUDE_PROJECT_DIR="$HQROOT" bash "$HQROOT/core/scripts/migrate-policy-triggers.sh" --dry-run "$HQROOT/core/policies" </dev/null
[ "$(calls)" = "5" ] || fail "an argument form must always run, got $(calls)"
grep -q -- '--dry-run' "$CALLS" || fail "arguments were not forwarded"

sleep 1
touch "$BIN/hq"   # a newer hq ships newer migration rules
run
[ "$(calls)" = "6" ] || fail "a newer hq binary should re-run, got $(calls)"

# A failing run must not record a stamp.
rm -f "$STAMP"
cat > "$BIN/hq" <<EOF
#!/usr/bin/env bash
case "\$*" in *--version*|version) echo 99.0.0; exit 0 ;; esac
echo "\$*" >> "$CALLS"; exit 3
EOF
chmod +x "$BIN/hq"
set +e; run; rc=$?; set -e
[ "$rc" -eq 3 ] || fail "exit code of hq must propagate, got $rc"
[ ! -f "$STAMP" ] || fail "a failing run must not write the stamp"

echo "PASS: migrate-policy-triggers skips hq when policies are unchanged and re-runs on change, force, args, newer hq"
