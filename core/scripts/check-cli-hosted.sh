#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROOT="$DEFAULT_ROOT"
MANIFEST=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || { echo "--root requires a path" >&2; exit 64; }
      ROOT="$2"
      shift 2
      ;;
    --manifest)
      [ "$#" -ge 2 ] || { echo "--manifest requires a path" >&2; exit 64; }
      MANIFEST="$2"
      shift 2
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      exit 64
      ;;
  esac
done

case "$ROOT" in
  /*) ;;
  *) ROOT="$PWD/$ROOT" ;;
esac
if [ -z "$MANIFEST" ]; then
  MANIFEST="$ROOT/core/scripts/cli-hosted.yaml"
else
  case "$MANIFEST" in
    /*) ;;
    *) MANIFEST="$PWD/$MANIFEST" ;;
  esac
fi

if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf '%s: root is not a git worktree\n' "$ROOT" >&2
  exit 1
fi
if [ ! -r "$MANIFEST" ]; then
  printf '%s: manifest is missing or unreadable\n' "$MANIFEST" >&2
  exit 1
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hq-cli-hosted-guard.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
ROWS="$TEMP_DIR/rows.tsv"
if ! awk -f "$SCRIPT_DIR/lib/cli-hosted-manifest.awk" "$MANIFEST" > "$ROWS"; then
  exit 1
fi

failures=0
fail() {
  printf '%s: %s\n' "$1" "$2" >&2
  failures=$((failures + 1))
}

source_lines() {
  local path="$1" language=shell
  case "$path" in
    *.js|*.mjs) language=javascript ;;
  esac
  awk -v language="$language" -f "$SCRIPT_DIR/lib/cli-hosted-executable-lines.awk" "$ROOT/$path"
}

hybrid_has_command() {
  local path="$1" command="$2"
  source_lines "$path" | awk -v expected="$command" '
    function has_expected(line, rest, after_core, prefix, length_expected, following) {
      rest = line
      while (match(rest, /hq[[:space:]]+core/)) {
        prefix = substr(rest, 1, RSTART - 1)
        if (prefix == "" || substr(prefix, length(prefix), 1) !~ /[[:alnum:]_-]/) {
          after_core = substr(rest, RSTART + RLENGTH)
          sub(/^[[:space:]]+/, "", after_core)
          if (after_core ~ /^--hq-root=/) {
            sub(/^--hq-root=[^[:space:];|&]+[[:space:]]*/, "", after_core)
          } else if (after_core ~ /^--hq-root[[:space:]]+/) {
            sub(/^--hq-root[[:space:]]+/, "", after_core)
            if (after_core ~ /^"[^"]*"/) sub(/^"[^"]*"[[:space:]]*/, "", after_core)
            else if (after_core ~ /^\047[^\047]*\047/) sub(/^\047[^\047]*\047[[:space:]]*/, "", after_core)
            else sub(/^[^[:space:];|&]+[[:space:]]*/, "", after_core)
          }
          length_expected = length(expected)
          following = substr(after_core, length_expected + 1, 1)
          if (substr(after_core, 1, length_expected) == expected &&
              (following == "" || following ~ /[[:space:];|&)]/)) return 1
        }
        rest = substr(rest, RSTART + 1)
      }
      return 0
    }
    has_expected($0) { found = 1 }
    END { exit !found }
  '
}

is_explicitly_allowed_cli_source() {
  case "$1" in
    # The generator embeds hq core in printf templates for generated forwarders.
    core/scripts/generate-forwarders.sh) return 0 ;;
    # The checker has hq core in diagnostics and documents future catalog checks.
    core/scripts/check-cli-hosted.sh) return 0 ;;
    # The CI installer probes for the hidden core group before running tests.
    core/scripts/ci/install-pinned-hq-cli.sh) return 0 ;;
    # Handoff scripts make operational CLI calls that are not scaffold entrypoints.
    core/scripts/handoff-finalize.sh|core/scripts/handoff-post.sh) return 0 ;;
    *) return 1 ;;
  esac
}

check_cli_command_catalog_parity() {
  local version catalog_file catalog_error npm_root changelog
  if ! command -v hq >/dev/null 2>&1; then
    fail "core/scripts/cli-hosted.yaml" "pinned hq-cli is not on PATH"
    return
  fi
  if ! version="$(hq --version 2>/dev/null)" || [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][A-Za-z0-9.-]+)?$ ]]; then
    fail "core/scripts/cli-hosted.yaml" "could not read a valid hq-cli version"
    return
  fi

  catalog_file="$TEMP_DIR/commands.json"
  catalog_error="$TEMP_DIR/commands.err"
  if hq core commands --json > "$catalog_file" 2> "$catalog_error"; then
    if ! node "$SCRIPT_DIR/ci/check-cli-hosted-catalog.mjs" \
      --root "$ROOT" --rows "$ROWS" --scanner "$SCRIPT_DIR/lib/cli-hosted-executable-lines.awk" \
      --catalog "$catalog_file"; then
      failures=$((failures + 1))
    fi
    return
  fi

  if [ "${HQ_CLI_REQUIRED_IN_CI:-0}" = "1" ]; then
    fail "core/scripts/cli-hosted.yaml" "hq-cli $version: hq core commands --json is unavailable; catalog parity is required in CI"
    return
  fi
  if ! command -v npm >/dev/null 2>&1 || ! npm_root="$(npm root -g 2>/dev/null)"; then
    fail "core/scripts/cli-hosted.yaml" "hq core commands --json failed and the installed CLI changelog could not be located"
    return
  fi
  changelog="$npm_root/@indigoai-us/hq-cli/CHANGELOG.md"
  if [ ! -r "$changelog" ]; then
    fail "core/scripts/cli-hosted.yaml" "hq core commands --json failed and the installed CLI CHANGELOG.md is unreadable"
    return
  fi
  if grep -F -q 'hq core commands --json' "$changelog"; then
    fail "core/scripts/cli-hosted.yaml" "hq-cli $version: published CHANGELOG.md contains hq core commands --json but the command is unavailable"
    return
  fi
  printf 'catalog parity deferred: published hq-cli %s predates hq core commands --json\n' "$version"
}

GENERATED_ROOT="$TEMP_DIR/generated"
if ! bash "$SCRIPT_DIR/generate-forwarders.sh" --manifest "$MANIFEST" --output-root "$GENERATED_ROOT"; then
  fail "core/scripts/cli-hosted.yaml" "forwarder generation failed"
else
  while IFS="$(printf '\t')" read -r path command kind _root _interpreter _min_cli state; do
    if [ "$kind" = "generated" ] && [ "$state" = "forwarded" ]; then
      if [ ! -f "$ROOT/$path" ] || ! cmp -s "$GENERATED_ROOT/$path" "$ROOT/$path"; then
        fail "$path" "generated forwarder differs from manifest"
      fi
      index_mode="$(git -C "$ROOT" ls-files -s -- "$path" | awk 'NR == 1 { print $1 }')"
      if [ "$index_mode" != "100755" ]; then
        fail "$path" "generated forwarder index mode is ${index_mode:-missing}, expected 100755"
      fi
    fi

    if [ "$state" = "retired" ] || [ "$state" = "deleted" ]; then
      if [ -e "$ROOT/$path" ] || [ -L "$ROOT/$path" ]; then
        fail "$path" "$state path exists in tree"
      fi
      references="$(git -C "$ROOT" grep -l -F -e "$path" -- . ':(exclude)core/scripts/cli-hosted.yaml' 2>/dev/null || true)"
      if [ -n "$references" ]; then
        while IFS= read -r reference; do
          [ -n "$reference" ] && fail "$path" "tracked file $reference references $state path"
        done <<EOF
$references
EOF
      fi
    fi

    if [ "$kind" = "hybrid" ] && [ "$state" = "forwarded" ]; then
      if [ ! -f "$ROOT/$path" ] || ! hybrid_has_command "$path" "$command"; then
        fail "$path" "hybrid row has no executable hq core $command invocation"
      fi
    fi
  done < "$ROWS"
fi

tracked_scripts="$(git -C "$ROOT" ls-files -- core/scripts .claude/hooks)"
SOURCE_LINES="$TEMP_DIR/source-lines.txt"
while IFS= read -r file; do
  [ -n "$file" ] || continue
  case "$file" in
    core/scripts/tests/*|.claude/hooks/tests/*) continue ;;
    *.sh|*.mjs|*.js) ;;
    *) continue ;;
  esac
  [ -f "$ROOT/$file" ] || continue
  if ! source_lines "$file" > "$SOURCE_LINES"; then
    fail "$file" "executable-line scan failed"
    continue
  fi
  if grep -E -q '(^|[^[:alnum:]_-])hq[[:space:]]+core([^[:alnum:]_-]|$)' "$SOURCE_LINES"; then
    registered="$(awk -F '\t' -v wanted="$file" '$1 == wanted { found = 1 } END { exit !found }' "$ROWS" && echo yes || true)"
    if [ "$registered" != "yes" ] && ! is_explicitly_allowed_cli_source "$file"; then
      fail "$file" "unmanifested executable hq core call lacks a manifest row or explicit allow-list entry"
    fi
  fi
done <<EOF
$tracked_scripts
EOF

check_cli_command_catalog_parity

if [ "$failures" -gt 0 ]; then
  exit 1
fi
printf 'cli-hosted manifest and backmerge checks passed\n'
