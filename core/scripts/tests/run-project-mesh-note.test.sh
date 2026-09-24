#!/usr/bin/env bash
# Regression: core/scripts/run-project.sh must enqueue its work-mesh start and
# finish notes with options the hq CLI accepts. hq-cli 5.157+ rejects
# `--session` ("error: unknown option"); the option is `--session-id`. The
# wrapper swallows mesh failures, so the stub records every rejection.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

FIX="$TMP/hq"
mkdir -p "$FIX/core/scripts" "$FIX/.claude/scripts" "$FIX/bin" \
  "$FIX/companies/acme/projects/widget"
cp "$ROOT/core/scripts/run-project.sh" "$FIX/core/scripts/run-project.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/.claude/scripts/run-project.sh"
printf '{"name":"widget","userStories":[{"id":"US-1","passes":true}]}\n' \
  > "$FIX/companies/acme/projects/widget/prd.json"

# Option list mirrors `hq mesh session note --help` (hq-cli 5.171).
cat > "$FIX/bin/hq" <<'HQ'
#!/usr/bin/env bash
echo "$*" >> "$MESH_LOG"
if [ "${1:-} ${2:-} ${3:-}" = "mesh session note" ]; then
  shift 3
  for a in "$@"; do
    case "$a" in
      --enqueue|--session-id|--harness|--adapter-version|--runtime-version|--seq|--event-id|--at|--task-id|--status|--reason|--summary|--cwd|--hq-root|--company-slug|--project|--task|--touched-path|--repo-path|--tool-writes|--json) ;;
      --*) echo "REJECTED unknown option '$a'" >> "$MESH_LOG"; exit 1 ;;
    esac
  done
fi
exit 0
HQ
chmod +x "$FIX/bin/hq"

export MESH_LOG="$TMP/mesh.log"
: > "$MESH_LOG"
PATH="$FIX/bin:$PATH" HQ_SESSION_ID=sess_test bash "$FIX/core/scripts/run-project.sh" widget >/dev/null 2>&1 \
  || fail "wrapper exited non-zero"

! grep -q REJECTED "$MESH_LOG" || fail "mesh note used an option the CLI rejects: $(cat "$MESH_LOG")"
[ "$(grep -c 'mesh session note' "$MESH_LOG")" -eq 2 ] || fail "expected start + finish notes: $(cat "$MESH_LOG")"
[ "$(grep -c -- '--session-id sess_test' "$MESH_LOG")" -eq 2 ] || fail "notes must pass --session-id"
[ "$(grep -c -- '--company-slug acme --project widget' "$MESH_LOG")" -eq 2 ] || fail "notes must attribute company + project"
grep -q 'run-project completed for widget' "$MESH_LOG" || fail "finish note must report completion"

echo "run-project-mesh-note: ok"
