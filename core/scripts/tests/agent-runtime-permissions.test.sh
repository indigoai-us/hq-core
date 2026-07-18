#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
VALIDATOR="$ROOT/core/scripts/validate-agent-runtime-contracts.mjs"
PARSER_ROOT="${HQ_AGENT_RUNTIME_PARSER_ROOT:-}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local needle="$2"
  grep -F "$needle" "$file" >/dev/null 2>&1 || {
    cat "$file" >&2 || true
    fail "missing expected text: $needle"
  }
}

write_root() {
  local root="$1"
  mkdir -p "$root/.claude/skills/example" "$root/core"
  printf 'hqVersion: test\n' > "$root/core/core.yaml"
}

write_skill() {
  local root="$1"
  local allowed_tools="$2"
  local command="$3"
  cat > "$root/.claude/skills/example/SKILL.md" <<EOF
---
name: example
description: Permission fixture.
allowed-tools: $allowed_tools
---

\`\`\`bash
$command
\`\`\`
EOF
}

run_validator() {
  HQ_AGENT_RUNTIME_PARSER_ROOT="$PARSER_ROOT" node "$VALIDATOR" validate-permissions "$@"
}

SUITE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-runtime-permissions.XXXXXX")"
trap 'rm -rf "$SUITE_DIR"' EXIT

if [ -z "$PARSER_ROOT" ]; then
  PARSER_ROOT="$SUITE_DIR/parser-root"
  node "$VALIDATOR" install-parser --install-dir "$PARSER_ROOT" >/dev/null
fi

echo "[1] live shipped commands have intentional narrow dispositions"
run_validator >"$SUITE_DIR/live.out" 2>"$SUITE_DIR/live.err" || fail "live permission validation failed"
assert_contains "$SUITE_DIR/live.out" "concrete shipped command permission contract(s)"

echo "[2] literal direct path and quoted arguments match the exact rule"
DIRECT_ROOT="$SUITE_DIR/direct"
write_root "$DIRECT_ROOT"
write_skill "$DIRECT_ROOT" '"Bash(core/scripts/example.sh:*)"' 'core/scripts/example.sh --title "quoted value"'
run_validator --root "$DIRECT_ROOT" >/dev/null || fail "direct script rule should match quoted arguments"

echo "[3] missing script rule reports skill, command, and narrow remediation"
MISSING_ROOT="$SUITE_DIR/missing"
write_root "$MISSING_ROOT"
write_skill "$MISSING_ROOT" 'Bash' 'core/scripts/new-script.sh --apply'
if run_validator --root "$MISSING_ROOT" >"$SUITE_DIR/missing.out" 2>"$SUITE_DIR/missing.err"; then
  fail "unlisted script should fail permission validation"
fi
assert_contains "$SUITE_DIR/missing.err" ".claude/skills/example/SKILL.md"
assert_contains "$SUITE_DIR/missing.err" "core/scripts/new-script.sh --apply"
assert_contains "$SUITE_DIR/missing.err" "missing rule: Bash(core/scripts/new-script.sh:*)"
assert_contains "$SUITE_DIR/missing.err" "Unrestricted Bash does not satisfy concrete command coverage"

echo "[4] bash and nohup wrappers require their literal command-prefix shapes"
BASH_ROOT="$SUITE_DIR/bash-wrapper"
write_root "$BASH_ROOT"
write_skill "$BASH_ROOT" '"Bash(bash core/scripts/example.sh:*)"' 'bash core/scripts/example.sh --check'
run_validator --root "$BASH_ROOT" >/dev/null || fail "bash-prefixed rule should match"

NOHUP_ROOT="$SUITE_DIR/nohup-wrapper"
write_root "$NOHUP_ROOT"
write_skill "$NOHUP_ROOT" '"Bash(nohup bash core/scripts/example.sh:*)"' 'nohup bash core/scripts/example.sh "quoted arg" > /tmp/example.log 2>&1 &'
run_validator --root "$NOHUP_ROOT" >/dev/null || fail "nohup-prefixed rule should match"

WRONG_ROOT="$SUITE_DIR/wrong-prefix"
write_root "$WRONG_ROOT"
write_skill "$WRONG_ROOT" '"Bash(core/scripts/example.sh:*)"' 'bash core/scripts/example.sh --check'
if run_validator --root "$WRONG_ROOT" >"$SUITE_DIR/wrong.out" 2>"$SUITE_DIR/wrong.err"; then
  fail "direct-path rule must not cover bash-prefixed invocation"
fi
assert_contains "$SUITE_DIR/wrong.err" "Bash(bash core/scripts/example.sh:*)"

echo "[5] documented approval-gated commands pass without widening Bash access"
APPROVAL_ROOT="$SUITE_DIR/approval"
write_root "$APPROVAL_ROOT"
mkdir -p "$APPROVAL_ROOT/.claude/skills/brainstorm"
cat > "$APPROVAL_ROOT/.claude/skills/brainstorm/SKILL.md" <<'EOF'
---
name: brainstorm
description: Approval-gated fixture.
allowed-tools: Read
---

```bash
.claude/skills/_shared/journal.sh open brainstorm "{project_dir}"
```
EOF
run_validator --root "$APPROVAL_ROOT" >/dev/null || fail "documented approval-gated command should pass"

echo "[6] embedded script invocations are inventoried instead of silently skipped"
EMBEDDED_ROOT="$SUITE_DIR/embedded"
write_root "$EMBEDDED_ROOT"
write_skill "$EMBEDDED_ROOT" 'Read' 'RESULT="$(core/scripts/embedded.sh --check)"'
if run_validator --root "$EMBEDDED_ROOT" >"$SUITE_DIR/embedded.out" 2>"$SUITE_DIR/embedded.err"; then
  fail "embedded script command should require a disposition"
fi
assert_contains "$SUITE_DIR/embedded.err" 'RESULT="$(core/scripts/embedded.sh'
assert_contains "$SUITE_DIR/embedded.err" 'suggested narrow allow entry: Bash(RESULT="$(core/scripts/embedded.sh:*)'

echo "PASS: agent-runtime-permissions"
