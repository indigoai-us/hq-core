#!/usr/bin/env bash
# hq-core: public
# The injector has an inline awk parser for the hot path. This table keeps its
# grammar verdicts aligned with eval-trigger.sh --check, which is canonical.
set -euo pipefail

HQ_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
EVAL="$HQ_SRC/core/scripts/eval-trigger.sh"
INJECT="$HQ_SRC/.claude/hooks/inject-policy-on-trigger.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v jq >/dev/null || fail "jq required"
for file in "$EVAL" "$INJECT" "$HQ_SRC/core/scripts/hook-lib.sh"; do
  [ -f "$file" ] || fail "missing required file: $file"
done

TMPROOT="$(mktemp -d)"
ROOT="$TMPROOT/hq"
trap 'rm -rf "$TMPROOT"' EXIT

mkdir -p "$ROOT/core/policies" "$ROOT/core/scripts" "$ROOT/.claude/hooks" \
  "$ROOT/workspace/orchestrator/policy-trigger-state"
cp "$HQ_SRC/core/scripts/hook-lib.sh" "$ROOT/core/scripts/hook-lib.sh"
cp "$EVAL" "$ROOT/core/scripts/eval-trigger.sh"
cp "$INJECT" "$ROOT/.claude/hooks/inject-policy-on-trigger.sh"
cat >"$ROOT/core/scripts/derive-trigger-facts.sh" <<'EOF'
#!/usr/bin/env bash
printf 'git push commit nested deep all words\n'
EOF
chmod +x "$ROOT/core/scripts/eval-trigger.sh" "$ROOT/core/scripts/derive-trigger-facts.sh"

write_policy() {
  local slug="$1" expression="$2" marker="$3"
  cat >"$ROOT/core/policies/$slug.md" <<EOF
---
id: $slug
scope: test
when: $expression
on: [UserPromptSubmit]
enforcement: soft
---

## Rule

$marker
EOF
}

run_injector() {
  local session="$1"
  jq -cn --arg sid "$session" --arg cwd "$ROOT" \
    '{session_id:$sid,hook_event_name:"UserPromptSubmit",tool_name:"Bash",cwd:$cwd,prompt:"parser parity"}' \
    | env -i PATH="$PATH" HOME="${HOME:-/tmp}" HQ_ROOT="$ROOT" CLAUDE_PROJECT_DIR="$ROOT" \
      bash "$ROOT/.claude/hooks/inject-policy-on-trigger.sh" 2>&1
}

check_row() {
  local label="$1" expression="$2" expected="$3" slug marker canonical injector output
  slug="parity-${label//[^a-z0-9]/-}"
  marker="PARSER_PARITY_${label^^}_MARKER"
  write_policy "$slug" "$expression" "$marker"
  canonical="$(printf '%s\t%s\n' "$label" "$expression" | bash "$EVAL" --check | awk -F '\t' '{print $2}')"
  output="$(run_injector "$slug")"
  if grep -Fq "$marker" <<<"$output"; then
    injector=ok
  else
    injector=malformed
  fi
  printf 'row=%-17s canonical=%-9s injector=%-9s expression=%s\n' \
    "$label" "$canonical" "$injector" "${expression:-<empty>}"
  [ "$canonical" = "$expected" ] || fail "$label: canonical expected $expected, got $canonical"
  [ "$injector" = "$canonical" ] \
    || fail "$label: hot-path injector disagrees with canonical parser (canonical=$canonical injector=$injector)"
}

echo "injector parser parity table"
check_row valid 'git && push' ok
check_row unclosed-paren 'git && (push || commit' malformed
check_row trailing-garbage 'git && push extra' malformed
check_row empty '' malformed
check_row quoted-phrase 'git && "push"' malformed
check_row bare-multiword 'git push' malformed
check_row deeply-nested '(git && (push || (commit && ! absent)))' ok

echo "PASS: inject-policy-parser-parity"
