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
cp "$ROOT/core/scripts/lib/forwarder.sh" "$HQROOT/core/scripts/lib/forwarder.sh"
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

# Same-day changes the top-level directory mtime does not show (#1821 review).
# Each run below happens the same calendar day as the last successful one.
mkdir -p "$HQROOT/core/policies/sub/deep" "$HQROOT/personal/workers/w1/policies"
printf -- '---\nid: s1\nenforcement: hard\n---\n\n## Rule\nx\n' > "$HQROOT/core/policies/sub/deep/s1.md"
run
base="$(calls)"
run
[ "$(calls)" = "$base" ] || fail "unchanged nested tree should skip, got $(calls) after $base"

sleep 1
printf 'edited\n' >> "$HQROOT/core/policies/p1.md"   # in place: directory mtime unchanged
run
[ "$(calls)" = "$((base + 1))" ] || fail "an in-place edit of a top-level policy should re-run the same day, got $(calls)"

sleep 1
printf 'edited\n' >> "$HQROOT/core/policies/sub/deep/s1.md"
run
[ "$(calls)" = "$((base + 2))" ] || fail "an in-place edit in a subfolder should re-run the same day, got $(calls)"

sleep 1
printf -- '---\nid: s2\nenforcement: hard\n---\n\n## Rule\ny\n' > "$HQROOT/core/policies/sub/deep/s2.md"
run
[ "$(calls)" = "$((base + 3))" ] || fail "a new file in a subfolder should re-run the same day, got $(calls)"

sleep 1
rm "$HQROOT/core/policies/sub/deep/s2.md"
run
[ "$(calls)" = "$((base + 4))" ] || fail "a file deleted from a subfolder should re-run the same day, got $(calls)"

sleep 1
printf -- '---\nid: w1\nenforcement: hard\n---\n\n## Rule\nz\n' > "$HQROOT/personal/workers/w1/policies/w1.md"
run
[ "$(calls)" = "$((base + 5))" ] || fail "a new worker policy should re-run the same day, got $(calls)"

run
[ "$(calls)" = "$((base + 5))" ] || fail "the tree is unchanged again and should skip, got $(calls)"

sleep 1
before_hq="$(calls)"
touch "$BIN/hq"   # a newer hq ships newer migration rules
run
[ "$(calls)" = "$((before_hq + 1))" ] || fail "a newer hq binary should re-run, got $(calls)"

# US-016 c4: /update-hq runs the forwarder directly, so the native command's
# own success stamp (<state>/<sha256 of scope>/last-success) is the only fresh
# one. The hook must accept it with no hq start and no write, for this root's
# exact scope only. The expected path is computed here independently from the
# hq-cli formula: sha256("<realpath root>\0" + "<dir>\0"...), dirs = core,
# personal, personal/workers/*/policies (sorted), then the company's policies
# and workers/*/policies when CLAUDE_PROJECT_DIR is under companies/<co>.
sha256_hex() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-64; else shasum -a 256 | cut -c1-64; fi; }
U="$TMP/updated"
mkdir -p "$U/core/policies" "$U/personal/policies" "$U/personal/workers/.dot/policies" \
  "$U/personal/workers/b/policies" "$U/personal/workers/a/policies" "$U/personal/workers/nopol" \
  "$U/companies/acme/policies" "$U/companies/acme/workers/w2/policies" "$U/workspace" "$U/core/scripts/lib"
printf -- '---\nid: u1\nenforcement: hard\nwhen: always\n---\nx\n' > "$U/core/policies/u1.md"
cp "$HQROOT/core/core.yaml" "$U/core/core.yaml"
cp "$HQROOT/core/scripts/migrate-policy-triggers.sh" "$U/core/scripts/"
cp "$HQROOT/core/scripts/lib/forwarder.sh" "$HQROOT/core/scripts/lib/hq-cli-floor.sh" "$U/core/scripts/lib/"
UR="$(cd -P "$U" && pwd)"
native_stamp_for() { # $1 = CLAUDE_PROJECT_DIR the hook sees
  local h
  h="$( {
    printf '%s\0' "$UR" "$UR/core/policies" "$UR/personal/policies" \
      "$UR/personal/workers/.dot/policies" "$UR/personal/workers/a/policies" "$UR/personal/workers/b/policies"
    case "$1" in */companies/acme*) printf '%s\0' "$UR/companies/acme/policies" "$UR/companies/acme/workers/w2/policies" ;; esac
  } | sha256_hex)"
  printf '%s/.local/state/hq-migrate-policy-triggers/%s/last-success\n' "$TMP" "$h"
}
U_STAMP="$U/workspace/orchestrator/policy-trigger-state/migrate-policy-triggers.stamp"
urun() { env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP" HQ_ROOT="$U" CLAUDE_PROJECT_DIR="${UPD:-$U}" "$@" bash "$FORWARDER" </dev/null; }
put_native() { mkdir -p "$(dirname "$1")"; printf '%s\n' "${2:-999999999}" > "$1"; }
sleep 1
NS="$(native_stamp_for "$U")"
put_native "$NS"
before="$(calls)"
urun
[ "$(calls)" = "$before" ] || fail "a current native last-success stamp must skip hq, got $(calls) after $before"
[ ! -e "$U_STAMP" ] && [ ! -e "$U_STAMP.new" ] || fail "the native-stamp skip must not write the hook's stamp"
[ -z "$(find "$U/workspace" -type f)" ] || fail "the native-stamp skip must write nothing under workspace/"

# A company session hashes a different scope: that stamp alone must not pass.
UPD="$U/companies/acme" urun
[ "$(calls)" = "$((before + 1))" ] || fail "a native stamp for another scope must not skip hq, got $(calls)"
rm -f "$U_STAMP"
NSC="$(native_stamp_for "$U/companies/acme")"
put_native "$NSC"
UPD="$U/companies/acme" urun
[ "$(calls)" = "$((before + 1))" ] || fail "the company scope's own native stamp must skip hq, got $(calls)"

# A root the migration never ran for still migrates (the stamp is per root).
mkdir -p "$TMP/other"; cp -R "$U/." "$TMP/other/"; rm -rf "$TMP/other/workspace"; mkdir -p "$TMP/other/workspace"
env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP" HQ_ROOT="$TMP/other" CLAUDE_PROJECT_DIR="$TMP/other" bash "$FORWARDER" </dev/null
[ "$(calls)" = "$((before + 2))" ] || fail "a root without its own native stamp must still migrate, got $(calls)"

# Malformed, unreadable or missing native stamps are never a pass.
exp=$((before + 2))
put_native "$NS" "not-a-time"
urun; exp=$((exp + 1))
[ "$(calls)" = "$exp" ] || fail "a malformed native stamp must not skip hq, got $(calls)"
rm -f "$U_STAMP"
if [ "$(id -u)" != 0 ]; then   # root can read a mode-000 file
  put_native "$NS"; chmod 000 "$NS"
  urun; exp=$((exp + 1))
  chmod 600 "$NS"
  [ "$(calls)" = "$exp" ] || fail "an unreadable native stamp must not skip hq, got $(calls)"
  rm -f "$U_STAMP"
fi
rm -f "$NS"
urun; exp=$((exp + 1))
[ "$(calls)" = "$exp" ] || fail "a missing native stamp must run hq, got $(calls)"
rm -f "$U_STAMP"

# The existing rules still apply to the native stamp: policy edits, a newer
# hq binary and the force switch.
sleep 1; put_native "$NS"; sleep 1
printf -- '---\nid: x\nenforcement: hard\n---\nx\n' > "$U/personal/workers/a/policies/x.md"
urun; exp=$((exp + 1))
[ "$(calls)" = "$exp" ] || fail "a policy newer than the native stamp must re-run, got $(calls)"
rm -f "$U_STAMP"
sleep 1; put_native "$NS"
urun
[ "$(calls)" = "$exp" ] || fail "a native stamp newer than the edit must skip again, got $(calls)"
sleep 1; touch "$BIN/hq"
urun; exp=$((exp + 1))
[ "$(calls)" = "$exp" ] || fail "an hq binary newer than the native stamp must re-run, got $(calls)"
rm -f "$U_STAMP"
sleep 1; put_native "$NS"
urun HQ_MIGRATE_TRIGGERS_FORCE=1; exp=$((exp + 1))
[ "$(calls)" = "$exp" ] || fail "HQ_MIGRATE_TRIGGERS_FORCE=1 must re-run despite a native stamp, got $(calls)"

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

echo "PASS: migrate-policy-triggers skips hq when policies are unchanged (own or native last-success stamp, exact scope) and re-runs on change, force, args, newer hq, bad stamps"
