#!/usr/bin/env bash
# Regression: the knowledge-repo loops in /checkpoint and /cleanup must expand
# empty globs safely when their actual snippets are invoked from zsh NOMATCH.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v zsh >/dev/null || fail "zsh must be installed for this regression test"

extract_knowledge_loop() {
  local skill=$1

  awk '
    /^ *```bash$/ { in_code=1; next }
    in_code && /^ *```$/ {
      if (code ~ /for symlink in core\/knowledge\/public\/\*/) {
        printf "%s", code
        exit
      }
      in_code=0
      code=""
      next
    }
    in_code {
      sub(/^   /, "")
      code=code $0 ORS
    }
  ' "$skill"
}

make_fixture() {
  local fixture=$1
  local layout=$2
  local repo="$fixture/repository"

  mkdir -p "$fixture/core/knowledge/public" "$fixture/companies"
  case "$layout" in
    dotkeep)
      mkdir -p "$fixture/core/knowledge/private" "$fixture/personal/knowledge"
      touch "$fixture/core/knowledge/private/.gitkeep"
      ;;
    absent)
      ;;
    *)
      fail "unknown fixture layout: $layout"
      ;;
  esac

  git init -q "$repo"
  git -C "$repo" config user.email [EMAIL]
  git -C "$repo" config user.name test
  printf 'tracked\n' > "$repo/state.txt"
  git -C "$repo" add state.txt
  git -C "$repo" commit -qm initial
  printf 'dirty\n' >> "$repo/state.txt"
  ln -s "$repo" "$fixture/core/knowledge/public/dirty-repo"
}

run_snippet() {
  local shell=$1
  local snippet=$2
  local fixture=$3

  if [[ "$shell" == zsh ]]; then
    (cd "$fixture" && zsh -f -c "$snippet")
  else
    (cd "$fixture" && bash -c "$snippet")
  fi
}

assert_discovery() {
  local skill=$1
  local output=$2
  local repo=$3

  if [[ "$skill" == checkpoint ]]; then
    grep -Fq 'core/knowledge/public/dirty-repo:' <<<"$output" ||
      fail "$skill did not discover the dirty symlinked repository"
  else
    grep -Fq "DIRTY: core/knowledge/public/dirty-repo → $repo" <<<"$output" ||
      fail "$skill did not report the dirty symlinked repository"
  fi
}

passed=0
for skill in checkpoint cleanup; do
  snippet="$(extract_knowledge_loop "$ROOT/.claude/skills/$skill/SKILL.md")"
  [[ -n "$snippet" ]] || fail "$skill knowledge-repo snippet not found"

  for layout in dotkeep absent; do
    fixture="$TMP/$skill-$layout"
    make_fixture "$fixture" "$layout"

    for shell in bash zsh; do
      if ! output="$(run_snippet "$shell" "$snippet" "$fixture" 2>&1)"; then
        fail "$skill snippet failed under $shell with $layout knowledge directories: $output"
      fi
      assert_discovery "$skill" "$output" "$fixture/repository"
      ((passed += 1))
    done
  done
done

echo "knowledge-repo-glob-shells: $passed passed, 0 failed"
