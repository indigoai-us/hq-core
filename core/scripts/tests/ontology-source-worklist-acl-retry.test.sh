#!/usr/bin/env bash
# A transient ACL command or jq parse failure must not permanently skip a source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORKLIST="$ROOT/core/scripts/ontology-source-worklist.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$TMP/bin" "$TMP/root/companies/indigo/sources"
cat > "$TMP/bin/hq" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
count=0
[ ! -f "$HQ_TEST_LOG" ] || count="$(cat "$HQ_TEST_LOG")"
count=$((count + 1))
printf '%s' "$count" > "$HQ_TEST_LOG"
if [ "$count" -eq 1 ]; then
  case "$HQ_TEST_FAILURE" in
    acl) printf '{"direct":[{"granteeType":"email","granteeId":"reader@example.test","permission":"read"}]}\n'; exit 7 ;;
    jq) printf 'not-json\n'; exit 0 ;;
  esac
fi
printf '{"direct":[{"granteeType":"email","granteeId":"reader@example.test","permission":"read"}]}\n'
STUB
chmod +x "$TMP/bin/hq"

for failure in acl jq; do
  channel="retry-$failure"
  directory="$TMP/root/companies/indigo/sources/$channel"
  mkdir -p "$directory"
  printf 'channel: %s\nkind: meeting\narrives: drop\naudience_rule: attendees\nprocessor: ontology/process-source\nrun: local\nschedule: on-close\n' "$channel" > "$directory/source.yaml"
  printf '%s\n' '---' 'id: retry-1' '---' 'Synthetic source' > "$directory/source.md"
  log="$TMP/$failure.attempts"
  output="$(HQ_ROOT="$TMP/root" HQ_BIN="$TMP/bin/hq" HQ_TEST_FAILURE="$failure" HQ_TEST_LOG="$log" bash "$WORKLIST" --company indigo --channel "$channel")"
  case "$output" in
    *'"audience":["reader@example.test"]'*) ;;
    *) fail "$failure failure was not retried to a resolved audience: $output" ;;
  esac
  [ "$(cat "$log")" = 2 ] || fail "$failure failure should make exactly two ACL attempts"
  [ ! -e "$directory/.skipped" ] || fail "$failure failure must not persist a no-audience skip"
done

echo "PASS: ACL command and jq parse failures retry before no-audience is persisted"
