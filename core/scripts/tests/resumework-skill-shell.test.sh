#!/usr/bin/env bash
# Execute the documented lock snippet, with all HQ helpers replaced by fakes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home"

awk '
  /^### 1\. Check and record the resume lock/ { section = 1; next }
  section && /^```bash$/ { code = 1; next }
  code && /^```$/ { exit }
  code { print }
' "$ROOT/.claude/skills/resumework/SKILL.md" > "$TMP/snippet.sh"
[[ -s "$TMP/snippet.sh" ]] || { echo 'FAIL: missing documented snippet'; exit 1; }

cat > "$TMP/run.sh" <<'FIXTURE'
bash() {
  case "$1" in
    core/scripts/hq-session.sh) printf '%s\n' fixture-session ;;
    core/scripts/resume-thread-lock.sh)
      printf '%s\n' "$2" >> "$CALLS"
      case "$2" in
        inspect) printf '{"status":"%s"}\n' "$LOCK_STATE" ;;
        acquire) return "$ACQUIRE_EXIT" ;;
        *) return 98 ;;
      esac
      ;;
    core/scripts/handoff-open-steps.sh) printf '%s\n' list >> "$CALLS" ;;
    *) return 99 ;;
  esac
}
FIXTURE
cat "$TMP/snippet.sh" >> "$TMP/run.sh"

shells=(/bin/bash)
command -v zsh >/dev/null && shells+=("$(command -v zsh)")
if [[ "$(uname -s)" == Darwin ]] && ! command -v zsh >/dev/null; then
  echo 'FAIL: macOS regression requires actual zsh' >&2
  exit 1
fi

for shell in "${shells[@]}"; do
  for scenario in unlocked locked stale raced failure unknown; do
    lock_state="$scenario" acquire_exit=0 expected_exit=0 expected_calls=inspect
    case "$scenario" in
      unlocked) expected_calls=$'inspect\nacquire\nlist' ;;
      raced) lock_state=unlocked; acquire_exit=3; expected_calls=$'inspect\nacquire\ninspect' ;;
      unknown) expected_exit=1 ;;
      failure) lock_state=unlocked; acquire_exit=7; expected_exit=7; expected_calls=$'inspect\nacquire' ;;
    esac
    calls="$TMP/calls"; : > "$calls"
    set +e
    env -i HOME="$TMP/home" TMPDIR="$TMP/" PATH="$PATH" \
      CALLS="$calls" LOCK_STATE="$lock_state" ACQUIRE_EXIT="$acquire_exit" \
      "$shell" "$TMP/run.sh" > "$TMP/output" 2>&1
    actual_exit=$?
    set -e
    if [[ "$actual_exit" -ne "$expected_exit" ]]; then
      echo "FAIL: $shell $scenario exit=$actual_exit expected=$expected_exit" >&2
      cat "$TMP/output" >&2
      exit 1
    fi
    [[ "$(cat "$calls")" == "$expected_calls" ]] || {
      echo "FAIL: $shell $scenario helper sequence" >&2; exit 1;
    }
    case "$scenario" in
      locked|stale) grep -Fq "\"status\":\"$scenario\"" "$TMP/output" ;;
      raced) grep -Fq '"status":"unlocked"' "$TMP/output" ;;
    esac
    echo "PASS: $shell $scenario"
  done
done
echo 'PASS: documented resumework snippet is shell-safe'
