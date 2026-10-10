#!/usr/bin/env bash
# The hq lanes pipeline driver and conductor run without Python on PATH.
set -u
unset HQ_SPAWN_COMPANY HQ_PARENT_SESSION_ID PC_WORKERS_ROOT PC_HQ PC_ENVELOPE PC_NOW PC_MAX_STORIES
export HQ_SESSION_ID="test-pipeline-no-python-$$"
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
DRIVER="$SCRIPTS/pipeline-driver.sh"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pipeline-nopy.XXXXXX")" && pwd -P)"
DPID=""
cleanup() { [ -n "$DPID" ] && kill "$DPID" 2>/dev/null; [ -n "${KEEP:-}" ] || rm -rf "$T"; }
trap cleanup EXIT
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=$((fail+1)); fi; }
fail=0

BIN="$T/bin"; mkdir -p "$BIN" "$T/hq/core/scripts" "$T/workers/backend-dev" "$T/case/state"
for tool in sh bash dash jq node git env cat date mkdir rm mv cp ls ps grep sed tr cut head tail wc sort awk dirname basename mktemp sleep touch chmod find uname tee ln readlink stat; do
  path="$(command -v "$tool" 2>/dev/null)"
  case "$path" in /*) ln -s "$path" "$BIN/$tool" ;; esac
done
cat > "$T/hq/core/scripts/hq-session.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in current) printf 'test-session\n' ;; *company_slug*) printf 'indigo\n' ;; esac
EOF
chmod +x "$T/hq/core/scripts/hq-session.sh"
printf 'worker:\n  id: backend-dev\nverification:\n  approval_required: false\n' > "$T/workers/backend-dev/worker.yaml"
cat > "$BIN/hq" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FAKE_HQ_LOG"
case "$1 $2" in
  'lanes create')
    has_brief=false; for arg in "$@"; do [ "$arg" = --brief-file ] && has_brief=true; done
    if [ "$has_brief" != true ]; then printf "error: required option '--brief-file <path>' not specified\n" >&2; exit 1; fi
    printf '{"ok":true,"lane_id":"lane-backend-dev"}\n' ;;
  'lanes enqueue')
    has_envelope=false; for arg in "$@"; do [ "$arg" = --envelope ] && has_envelope=true; done
    if [ "$has_envelope" != true ]; then printf "error: required option '--envelope <file>' not specified\n" >&2; exit 1; fi
    printf '{\n  "ok": true\n}\n' ;;
  'lanes list')
    if [ -f "$FAKE_HQ_LOG.stopped" ]; then printf '[{"lane_id":"lane-backend-dev","loop":{"state":"stopped","queue_depth":0,"pid":null}}]\n'
    else printf '[{"lane_id":"lane-backend-dev","loop":{"state":"waiting","queue_depth":1,"pid":1}}]\n'; fi ;;
  'lanes stop') : > "$FAKE_HQ_LOG.stopped"; printf '{"ok":true}\n' ;;
  'lanes interrupt'|'lanes questions') printf '{"ok":true,"withdrawn":[],"already_picked_up":[]}\n' ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$BIN/hq"
cat > "$T/case/prd.json" <<'EOF'
{"name":"nopy","userStories":[{"id":"S1","title":"t","passes":false,"dependsOn":[],"worker_preference":["backend-dev"],"acceptanceCriteria":["a"]}]}
EOF
export HQ_ROOT="$T/hq" PC_HQ_ROOT="$T/hq" PC_WORKERS_ROOT="$T/workers" PC_HQ="$BIN/hq" FAKE_HQ_LOG="$T/hq.log" PATH="$BIN"
mkdir -p "$HQ_ROOT/workspace/sessions" "$HQ_ROOT/workspace/worktrees/nopy/wt"
PATH="$BIN" sh "$DRIVER" --prd "$T/case/prd.json" --state "$T/case/state" --worktree "$HQ_ROOT/workspace/worktrees/nopy/wt" --interval 0.2 >"$T/out" 2>"$T/err" &
DPID=$!
i=0; while [ $i -lt 200 ] && ! grep -q '^lanes enqueue ' "$T/hq.log" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
check "stripped PATH excludes python3" '! PATH="$BIN" command -v python3 >/dev/null 2>&1'
check "driver routes through fake hq lanes without python3" 'grep -q "^lanes create --loop" "$T/hq.log" && grep -q "^lanes enqueue lane-backend-dev" "$T/hq.log"'
check "driver log and stderr do not request python3" '! grep -qs python3 "$T/err" "$T/case/state/driver/driver.log"'
kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; DPID=""
echo "pipeline-no-python: $((3-fail)) passed, $fail failed"
[ "$fail" = 0 ]
