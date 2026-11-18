#!/usr/bin/env bash
# hq-core: public
# A bare skill name such as code-review or init loads when another company's
# skill shares it only as the part after the colon of a mirror folder or as
# a source folder name. A frontmatter name or a folder in a company
# .claude/skills folder still refuses the bare name.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

failures=0
checks=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

skill_md() { # <folder> <frontmatter name>
  mkdir -p "$1"
  printf -- '---\nname: %s\ndescription: fixture\n---\nfixture body\n' "$2" > "$1/SKILL.md"
}
link_mirror() { # <mirror folder> <source folder, relative to the HQ root>
  mkdir -p "$1"
  ln -s "../../../$2/SKILL.md" "$1/SKILL.md"
}

install_fixture() { # [bound company]
  local bound="${1:-}" hook_source="${SCOPE_HOOK_SOURCE:-$ROOT/.claude/hooks/mandatory-scope-authorizer.sh}"
  rm -rf "$TMP/.claude" "$TMP/core" "$TMP/companies" "$TMP/workspace" "$TMP/personal" "$TMP/claude-config"
  mkdir -p "$TMP/.claude/hooks" "$TMP/.claude/skills" "$TMP/core/scripts/lib" \
    "$TMP/workspace/sessions/sess-1" "$TMP/workspace/reports" "$TMP/personal" "$TMP/claude-config/skills" \
    "$TMP/companies/otherco/skills" "$TMP/companies/ownco/skills"
  cp "$hook_source" "$TMP/.claude/hooks/mandatory-scope-authorizer.sh"
  cp "$ROOT/.claude/hooks/bash-arith-subst-guard-lib.sh" "$TMP/.claude/hooks/"
  cp "$ROOT/core/scripts/lib/session-authz.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/lib/session-scope-capability.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/lib/session-id.sh" "$TMP/core/scripts/lib/"
  cp "$ROOT/core/scripts/hook-lib.sh" "$TMP/core/scripts/"
  printf 'companies:\n  otherco:\n    name: otherco\n  ownco:\n    name: ownco\n' > "$TMP/companies/manifest.yaml"
  printf 'a\n' > "$TMP/workspace/reports/a"
  printf 'b\n' > "$TMP/workspace/reports/b"
  # otherco has skills named like Claude Code built-ins. Their frontmatter
  # names carry the company prefix, so only the folder name's part after the
  # colon matches the bare built-in name.
  skill_md "$TMP/companies/otherco/skills/code-review" otherco-code-review
  link_mirror "$TMP/.claude/skills/otherco:code-review" companies/otherco/skills/code-review
  # A copied user-level mirror.
  skill_md "$TMP/claude-config/skills/hq-otherco:simplify" otherco-simplify
  # A source folder with no mirror.
  skill_md "$TMP/companies/otherco/skills/loop" otherco-loop
  # A mirror whose frontmatter name is the bare name: Claude Code loads it
  # under that name too.
  skill_md "$TMP/companies/otherco/skills/review-x" security-review
  link_mirror "$TMP/.claude/skills/otherco:review-x" companies/otherco/skills/review-x
  # A nested skills folder inside the company: Claude Code loads it under
  # the bare folder name when work touches that folder.
  skill_md "$TMP/companies/otherco/.claude/skills/init" otherco-init
  if [ -n "$bound" ]; then
    printf 'company_slug: %s\n' "$bound" > "$TMP/workspace/sessions/sess-1/meta.yaml"
  fi
}

run_case() { # <label> <tool> <skill name or command> <expected exit> [cwd]
  local label="$1" tool="$2" arg="$3" expected="$4" cwd="${5:-$TMP}"
  local tool_input payload rc=0 stderr_file
  checks=$((checks + 1))
  stderr_file="$TMP/stderr-$checks"
  case "$tool" in
    Skill) tool_input="$(jq -cn --arg v "$arg" '{skill:$v}')" ;;
    Bash) tool_input="$(jq -cn --arg v "$arg" '{command:$v}')" ;;
    *) fail "$label has unsupported tool $tool"; return ;;
  esac
  payload="$(jq -cn --arg tool "$tool" --arg cwd "$cwd" --argjson input "$tool_input" \
    '{tool_name:$tool,session_id:"sess-1",cwd:$cwd,tool_input:$input}')"
  printf '%s' "$payload" | CLAUDE_CONFIG_DIR="$TMP/claude-config" CLAUDE_PROJECT_DIR="$TMP" \
    bash "$TMP/.claude/hooks/mandatory-scope-authorizer.sh" 2>"$stderr_file" || rc=$?
  printf '%-70s exit=%s\n' "$label" "$rc"
  if [ "$rc" -ne "$expected" ]; then
    fail "$label expected exit $expected, got $rc: $(head -c 300 "$stderr_file" | tr '\n' ' ')"
  elif [ "$expected" -eq 2 ] && [ -z "${ANY_REFUSAL:-}" ] && ! grep -q 'Cross-company scope violation' "$stderr_file"; then
    fail "$label was denied without the cross-company message: $(head -c 300 "$stderr_file" | tr '\n' ' ')"
  fi
}

for bound in ownco ''; do
  install_fixture "$bound"
  echo "[bound: ${bound:-none}]"
  run_case 'bare name matching only a mirror folder suffix loads' Skill 'code-review' 0
  run_case 'bare name matching only a user-level mirror suffix loads' Skill 'simplify' 0
  run_case 'bare name matching only an unmirrored source folder loads' Skill 'loop' 0
  run_case 'the company-addressed name is refused' Skill 'otherco:code-review' 2
  run_case 'the hq- company-addressed name is refused' Skill 'hq-otherco:simplify' 2
  run_case 'the frontmatter alias of the mirror is refused' Skill 'otherco-code-review' 2
  run_case 'a bare name a company frontmatter carries is refused' Skill 'security-review' 2
  run_case 'a nested company skills folder name is refused' Skill 'init' 2
done

echo "Checks: $checks; failures: $failures"
[ "$failures" -eq 0 ]
