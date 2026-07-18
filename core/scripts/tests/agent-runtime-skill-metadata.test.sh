#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
VALIDATOR="$ROOT/core/scripts/validate-agent-runtime-contracts.mjs"
CONVERT_CODEX="$ROOT/core/scripts/convert-codex.sh"
PARSER_ENV_VAR="HQ_AGENT_RUNTIME_PARSER_ROOT"
PARSER_ROOT=""

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "  ok: $*"
}

assert_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -F "$needle" "$file" >/dev/null 2>&1; then
    echo "--- $file ---" >&2
    cat "$file" >&2 || true
    fail "missing expected text: $needle"
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  if grep -F "$needle" "$file" >/dev/null 2>&1; then
    echo "--- $file ---" >&2
    cat "$file" >&2 || true
    fail "unexpected text present: $needle"
  fi
}

mktemp_dir() {
  local base="${TMPDIR:-/tmp}"
  mktemp -d "${base%/}/agent-runtime-skill-metadata.XXXXXX"
}

write_hq_root() {
  local dir="$1"
  mkdir -p "$dir/.claude/skills" "$dir/core"
  cat > "$dir/core/core.yaml" <<'EOF'
hqVersion: test
EOF
}

write_skill() {
  local root="$1"
  local slug="$2"
  local frontmatter="$3"
  mkdir -p "$root/.claude/skills/$slug"
  cat > "$root/.claude/skills/$slug/SKILL.md" <<EOF
---
$frontmatter
---

# $slug
EOF
}

write_package_skill() {
  local pkg_root="$1"
  local slug="$2"
  local frontmatter="$3"
  mkdir -p "$pkg_root/skills/$slug"
  cat > "$pkg_root/skills/$slug/SKILL.md" <<EOF
---
$frontmatter
---

# $slug
EOF
}

run_validator() {
  HQ_AGENT_RUNTIME_PARSER_ROOT="${PARSER_ROOT}" node "$VALIDATOR" "$@"
}

run_convert() {
  HQ_AGENT_RUNTIME_PARSER_ROOT="${PARSER_ROOT}" bash "$CONVERT_CODEX" "$@"
}

[ -f "$VALIDATOR" ] || fail "validator not found: $VALIDATOR"
[ -f "$CONVERT_CODEX" ] || fail "convert-codex not found: $CONVERT_CODEX"

SUITE_DIR="$(mktemp_dir)"
trap 'rm -rf "$SUITE_DIR"' EXIT

echo "[1] validator fails deterministically until parser root is installed explicitly"
NO_PARSER_ROOT="$SUITE_DIR/no-parser"
write_hq_root "$NO_PARSER_ROOT"
write_skill "$NO_PARSER_ROOT" "missing-parser" $'name: missing-parser\ndescription: "Missing parser should fail deterministically."\nallowed-tools: Bash'
if HQ_AGENT_RUNTIME_PARSER_ROOT= node "$VALIDATOR" --root "$NO_PARSER_ROOT" >"$SUITE_DIR/no-parser.out" 2>"$SUITE_DIR/no-parser.err"; then
  fail "validator should fail when no parser root is configured"
fi
assert_contains "$SUITE_DIR/no-parser.err" 'js-yaml@4.1.0'
assert_contains "$SUITE_DIR/no-parser.err" "install-parser --install-dir"
assert_contains "$SUITE_DIR/no-parser.err" "$PARSER_ENV_VAR"
pass "missing parser reports explicit install contract"

if [ -n "${HQ_AGENT_RUNTIME_PARSER_ROOT:-}" ]; then
  PARSER_ROOT="${HQ_AGENT_RUNTIME_PARSER_ROOT}"
else
  PARSER_ROOT="$SUITE_DIR/parser-root"
  node "$VALIDATOR" install-parser --install-dir "$PARSER_ROOT" >"$SUITE_DIR/install-parser.out" 2>"$SUITE_DIR/install-parser.err" || fail "parser bootstrap failed"
  assert_contains "$SUITE_DIR/install-parser.out" 'Installed js-yaml@4.1.0'
  assert_contains "$SUITE_DIR/install-parser.out" "$PARSER_ENV_VAR"
fi

echo "[2] live shipped corpus validates"
run_validator >"$SUITE_DIR/live.out" 2>"$SUITE_DIR/live.err" || fail "live validator failed"
assert_contains "$SUITE_DIR/live.out" "Validated "
assert_contains "$SUITE_DIR/live.out" ".claude"
assert_contains "$SUITE_DIR/live.out" "core"
pass "live corpus passes"

echo "[3] malformed colon-space plain scalar reports parser location + remediation"
BAD_ROOT="$SUITE_DIR/bad-frontmatter"
write_hq_root "$BAD_ROOT"
write_skill "$BAD_ROOT" "bad-skill" $'name: bad-skill\ndescription: broken: value\nallowed-tools: Bash'
if run_validator --root "$BAD_ROOT" >"$SUITE_DIR/bad.out" 2>"$SUITE_DIR/bad.err"; then
  fail "malformed plain scalar should fail validation"
fi
assert_contains "$SUITE_DIR/bad.err" "/.claude/skills/bad-skill/SKILL.md"
assert_contains "$SUITE_DIR/bad.err" "field: description"
assert_contains "$SUITE_DIR/bad.err" "parser: line 3, column "
assert_contains "$SUITE_DIR/bad.err" 'plain scalars cannot contain ": " without quotes'
assert_contains "$SUITE_DIR/bad.err" "quote the value or use a block scalar"
pass "malformed plain scalar is diagnosed"

echo "[4] non-empty name and description fields are required"
EMPTY_NAME_ROOT="$SUITE_DIR/empty-name"
write_hq_root "$EMPTY_NAME_ROOT"
write_skill "$EMPTY_NAME_ROOT" "empty-name" $'name: ""\ndescription: Valid description.\nallowed-tools: Bash'
if run_validator --root "$EMPTY_NAME_ROOT" >"$SUITE_DIR/empty-name.out" 2>"$SUITE_DIR/empty-name.err"; then
  fail "empty skill name should fail validation"
fi
assert_contains "$SUITE_DIR/empty-name.err" "field: name"
assert_contains "$SUITE_DIR/empty-name.err" "name must be a non-empty string"

EMPTY_DESCRIPTION_ROOT="$SUITE_DIR/empty-description"
write_hq_root "$EMPTY_DESCRIPTION_ROOT"
write_skill "$EMPTY_DESCRIPTION_ROOT" "empty-description" $'name: empty-description\ndescription: ""\nallowed-tools: Bash'
if run_validator --root "$EMPTY_DESCRIPTION_ROOT" >"$SUITE_DIR/empty-description.out" 2>"$SUITE_DIR/empty-description.err"; then
  fail "empty description should fail validation"
fi
assert_contains "$SUITE_DIR/empty-description.err" "field: description"
assert_contains "$SUITE_DIR/empty-description.err" "description must be a non-empty string"
pass "required metadata fields must be non-empty"

echo "[5] parser-backed YAML typing rejects invalid allowed-tools and preserves tagged descriptions"
ALLOWED_TOOLS_ROOT="$SUITE_DIR/allowed-tools"
write_hq_root "$ALLOWED_TOOLS_ROOT"
write_skill "$ALLOWED_TOOLS_ROOT" "numeric-scalar" $'name: numeric-scalar\ndescription: "Numeric scalar allowed-tools should fail."\nallowed-tools: 7'
if run_validator --root "$ALLOWED_TOOLS_ROOT" >"$SUITE_DIR/allowed-tools-scalar.out" 2>"$SUITE_DIR/allowed-tools-scalar.err"; then
  fail "numeric scalar allowed-tools should fail validation"
fi
assert_contains "$SUITE_DIR/allowed-tools-scalar.err" "field: allowed-tools"
assert_contains "$SUITE_DIR/allowed-tools-scalar.err" "allowed-tools must be a string or a YAML list"

ALLOWED_TOOLS_LIST_ROOT="$SUITE_DIR/allowed-tools-list"
write_hq_root "$ALLOWED_TOOLS_LIST_ROOT"
write_skill "$ALLOWED_TOOLS_LIST_ROOT" "numeric-list" $'name: numeric-list\ndescription: "Numeric list item should fail."\nallowed-tools: [Read, 7]'
if run_validator --root "$ALLOWED_TOOLS_LIST_ROOT" >"$SUITE_DIR/allowed-tools-list.out" 2>"$SUITE_DIR/allowed-tools-list.err"; then
  fail "numeric allowed-tools list item should fail validation"
fi
assert_contains "$SUITE_DIR/allowed-tools-list.err" "field: allowed-tools"
assert_contains "$SUITE_DIR/allowed-tools-list.err" "allowed-tools list items must be strings"

TAGGED_ROOT="$SUITE_DIR/tagged-description"
write_hq_root "$TAGGED_ROOT"
write_skill "$TAGGED_ROOT" "tagged-description" $'name: tagged-description\ndescription: !!str "Tagged description: keep colon text valid."\nallowed-tools: Bash'
run_validator emit-openai-yaml "$TAGGED_ROOT/.claude/skills/tagged-description/SKILL.md" >"$SUITE_DIR/tagged.out" 2>"$SUITE_DIR/tagged.err" || fail "tagged description should emit openai yaml"
assert_contains "$SUITE_DIR/tagged.out" "Tagged description: keep colon text valid."
assert_not_contains "$SUITE_DIR/tagged.out" "!!str"
pass "allowed-tools typing and tagged descriptions use a real YAML parser"

echo "[6] package contributes.skills inclusion ignores unshipped package skill directories"
PACKAGE_ROOT="$SUITE_DIR/package-inclusion"
write_hq_root "$PACKAGE_ROOT"
mkdir -p "$PACKAGE_ROOT/core/packages/hq-pack-example"
cat > "$PACKAGE_ROOT/core/packages/hq-pack-example/package.yaml" <<'EOF'
name: hq-pack-example
contributes:
  skills:
    - listed-skill
EOF
write_package_skill "$PACKAGE_ROOT/core/packages/hq-pack-example" "listed-skill" $'name: listed-skill\ndescription: Listed package skill.\nallowed-tools:\n  - Read\n  - Bash'
write_package_skill "$PACKAGE_ROOT/core/packages/hq-pack-example" "ignored-skill" $'name: ignored-skill\ndescription: ignored: malformed\nallowed-tools: Bash'
run_validator --root "$PACKAGE_ROOT" >"$SUITE_DIR/package.out" 2>"$SUITE_DIR/package.err" || fail "unlisted package skill should be ignored"
assert_contains "$SUITE_DIR/package.out" "hq-pack-example"
pass "package inclusion mirrors contributes.skills only"

echo "[7] missing declared package payload fails validation"
MISSING_PACKAGE_ROOT="$SUITE_DIR/missing-package-skill"
write_hq_root "$MISSING_PACKAGE_ROOT"
mkdir -p "$MISSING_PACKAGE_ROOT/core/packages/hq-pack-missing"
cat > "$MISSING_PACKAGE_ROOT/core/packages/hq-pack-missing/package.yaml" <<'EOF'
name: hq-pack-missing
contributes:
  skills:
    - declared-skill
EOF
if run_validator --root "$MISSING_PACKAGE_ROOT" >"$SUITE_DIR/missing-package.out" 2>"$SUITE_DIR/missing-package.err"; then
  fail "missing declared package skill should fail"
fi
assert_contains "$SUITE_DIR/missing-package.err" 'package declares contributed skill "declared-skill"'
assert_contains "$SUITE_DIR/missing-package.err" "field: contributes.skills"
pass "missing declared package skill is rejected"

echo "[8] duplicate skill names inside one shipped surface fail"
DUP_ROOT="$SUITE_DIR/duplicate-package"
write_hq_root "$DUP_ROOT"
mkdir -p "$DUP_ROOT/core/packages/hq-pack-dup"
cat > "$DUP_ROOT/core/packages/hq-pack-dup/package.yaml" <<'EOF'
name: hq-pack-dup
contributes:
  skills:
    - alpha
    - beta
EOF
write_package_skill "$DUP_ROOT/core/packages/hq-pack-dup" "alpha" $'name: shared-skill\ndescription: Alpha package skill.\nallowed-tools: Read'
write_package_skill "$DUP_ROOT/core/packages/hq-pack-dup" "beta" $'name: shared-skill\ndescription: Beta package skill.\nallowed-tools:\n  - Bash'
if run_validator --root "$DUP_ROOT" >"$SUITE_DIR/dup.out" 2>"$SUITE_DIR/dup.err"; then
  fail "duplicate shipped skill names should fail"
fi
assert_contains "$SUITE_DIR/dup.err" "duplicate skill name \"shared-skill\""
assert_contains "$SUITE_DIR/dup.err" "hq-pack-dup"
pass "duplicate names are rejected per shipped surface"

echo "[9] blocked convert-codex generation leaves no partial openai.yaml behind"
FAILED_GEN_ROOT="$SUITE_DIR/failed-generated-openai"
write_hq_root "$FAILED_GEN_ROOT"
write_skill "$FAILED_GEN_ROOT" "failed-skill" $'name: failed-skill\ndescription: "Missing parser should stop generation cleanly."\nallowed-tools: Bash'
HQ_AGENT_RUNTIME_PARSER_ROOT="$SUITE_DIR/does-not-exist" bash "$CONVERT_CODEX" --apply --root="$FAILED_GEN_ROOT" >"$SUITE_DIR/failed-convert.out" 2>"$SUITE_DIR/failed-convert.err" || fail "convert-codex should preserve blocked-item contract"
FAILED_OPENAI_YAML="$FAILED_GEN_ROOT/.claude/skills/failed-skill/agents/openai.yaml"
[ ! -e "$FAILED_OPENAI_YAML" ] || fail "failed generation should not leave openai.yaml behind"
FAILED_TMP_COUNT=0
for failed_tmp in "$FAILED_GEN_ROOT/.claude/skills/failed-skill/agents"/openai.yaml.tmp.*; do
  [ -e "$failed_tmp" ] || continue
  FAILED_TMP_COUNT=$((FAILED_TMP_COUNT + 1))
done
[ "$FAILED_TMP_COUNT" = "0" ] || fail "failed generation should clean up temporary files"
assert_contains "$SUITE_DIR/failed-convert.out" 'could not create .claude/skills/failed-skill/agents/openai.yaml'
assert_contains "$SUITE_DIR/failed-convert.out" 'Completed with blocked items. Existing paths were left untouched.'
assert_contains "$SUITE_DIR/failed-convert.err" 'js-yaml@4.1.0'
assert_contains "$SUITE_DIR/failed-convert.err" 'install-parser --install-dir'
pass "blocked convert generation is atomic and diagnostic"

echo "[10] convert-codex generates bounded valid openai.yaml for complex descriptions"
GEN_ROOT="$SUITE_DIR/generated-openai"
write_hq_root "$GEN_ROOT"
write_skill "$GEN_ROOT" "complex-skill" $'name: complex-skill\ndescription: "Use `hq integrations` to inspect host tools: preserve quoted strings, keep colon-bearing text valid, and make this first sentence long enough to prove the generated short description stays bounded without breaking YAML parsing for Codex."\nallowed-tools:\n  - Bash\n  - Read'
run_convert --apply --root="$GEN_ROOT" >"$SUITE_DIR/convert.out" 2>"$SUITE_DIR/convert.err" || fail "convert-codex generation failed"
OPENAI_YAML="$GEN_ROOT/.claude/skills/complex-skill/agents/openai.yaml"
[ -f "$OPENAI_YAML" ] || fail "missing generated openai.yaml"
run_validator --root "$GEN_ROOT" >"$SUITE_DIR/generated.out" 2>"$SUITE_DIR/generated.err" || fail "generated openai.yaml should validate"
assert_contains "$OPENAI_YAML" "short_description: >-"
SHORT_DESCRIPTION_LINE="$(awk '/short_description: >-/{getline; sub(/^    /, ""); print; exit}' "$OPENAI_YAML")"
[ -n "$SHORT_DESCRIPTION_LINE" ] || fail "generated short description should not be empty"
[ "${#SHORT_DESCRIPTION_LINE}" -le 140 ] || fail "generated short description should be bounded to 140 chars"
pass "convert-codex emits valid bounded openai metadata"

echo "PASS: agent-runtime-skill-metadata"
