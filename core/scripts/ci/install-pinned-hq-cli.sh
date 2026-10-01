#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ROOT="$DEFAULT_ROOT"
RESOLVE_ONLY=0
REQUESTED_VERSION=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || { echo "--root requires a path" >&2; exit 64; }
      ROOT="$2"
      shift 2
      ;;
    --resolve-only)
      RESOLVE_ONLY=1
      shift
      ;;
    --version)
      [ "$#" -ge 2 ] || { echo "--version requires a version or latest" >&2; exit 64; }
      REQUESTED_VERSION="$2"
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

CORE_YAML="$ROOT/core/core.yaml"
MANIFEST="$ROOT/core/scripts/cli-hosted.yaml"
MANIFEST_PARSER="$ROOT/core/scripts/lib/cli-hosted-manifest.awk"
for required in "$CORE_YAML" "$MANIFEST" "$MANIFEST_PARSER"; do
  if [ ! -r "$required" ]; then
    printf '%s: required CLI floor input is missing or unreadable\n' "$required" >&2
    exit 1
  fi
done

FLOOR_EXPRESSION="$(awk -F '[:\"]' '
  $1 == "requiresHqCli" {
    value = $3
    gsub(/[[:space:]]/, "", value)
    count++
  }
  END {
    if (count != 1 || value !~ /^>=[0-9]+\.[0-9]+\.[0-9]+$/) exit 1
    sub(/^>=/, "", value)
    print value
  }
' "$CORE_YAML")" || {
  printf '%s: requiresHqCli must contain one quoted >=x.y.z floor\n' "$CORE_YAML" >&2
  exit 1
}

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hq-pinned-cli.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
ROWS="$TEMP_DIR/rows.tsv"
if ! awk -f "$MANIFEST_PARSER" "$MANIFEST" > "$ROWS"; then
  exit 1
fi

HIGHEST_ROW_MIN="$(awk -F '\t' '
  function version_gt(left, right,    a, b, i, left_count, right_count) {
    left_count = split(left, a, ".")
    right_count = split(right, b, ".")
    for (i = 1; i <= 3; i++) {
      if ((a[i] + 0) > (b[i] + 0)) return 1
      if ((a[i] + 0) < (b[i] + 0)) return 0
    }
    return 0
  }
  $7 == "forwarded" {
    if (highest == "" || version_gt($6, highest)) highest = $6
  }
  END {
    if (highest == "") exit 1
    print highest
  }
' "$ROWS")" || {
  printf '%s: no forwarded CLI-hosted rows have a minimum version\n' "$MANIFEST" >&2
  exit 1
}

SELECTED_VERSION="$(awk -v floor="$FLOOR_EXPRESSION" -v row_min="$HIGHEST_ROW_MIN" '
  function version_gt(left, right,    a, b, i) {
    split(left, a, ".")
    split(right, b, ".")
    for (i = 1; i <= 3; i++) {
      if ((a[i] + 0) > (b[i] + 0)) return 1
      if ((a[i] + 0) < (b[i] + 0)) return 0
    }
    return 0
  }
  BEGIN { print version_gt(row_min, floor) ? row_min : floor }
')"

if [ -n "$REQUESTED_VERSION" ]; then
  if [ "$REQUESTED_VERSION" != "latest" ] \
    && [[ ! "$REQUESTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][A-Za-z0-9.-]+)?$ ]]; then
    printf 'invalid hq-cli version: %s\n' "$REQUESTED_VERSION" >&2
    exit 64
  fi
  SELECTED_VERSION="$REQUESTED_VERSION"
fi

if [ "$RESOLVE_ONLY" -eq 1 ]; then
  printf '%s\n' "$SELECTED_VERSION"
  exit 0
fi

printf 'hq-cli pin: requiresHqCli >=%s; highest forwarded/hybrid min_cli %s; installing %s\n' \
  "$FLOOR_EXPRESSION" "$HIGHEST_ROW_MIN" "$SELECTED_VERSION"

# CI runs the pinned floor build on purpose. When the server-side minimum
# rises above it, the version gate installs the latest CLI and exits before
# running the command, so every later probe gets no output. Turn the gate off
# here and, through GITHUB_ENV, for the steps that follow.
export HQ_NO_UPDATE_CHECK=1
if [ -n "${GITHUB_ENV:-}" ]; then
  printf 'HQ_NO_UPDATE_CHECK=1\n' >> "$GITHUB_ENV"
fi

# The package's postinstall may reconcile a local daemon; CI only needs the CLI binary.
npm install -g "@indigoai-us/hq-cli@$SELECTED_VERSION" --ignore-scripts

NPM_PREFIX="$(npm prefix -g)"
GITHUB_NPM_PREFIX="$NPM_PREFIX"
case "$NPM_PREFIX" in
  [A-Za-z]:\\*|[A-Za-z]:/*)
    if command -v cygpath >/dev/null 2>&1; then
      NPM_PREFIX="$(cygpath -u "$NPM_PREFIX")"
    else
      printf 'cannot convert the npm global prefix to a Bash path: %s\n' "$NPM_PREFIX" >&2
      exit 1
    fi
    ;;
esac

if [ -f "$NPM_PREFIX/bin/hq" ] || [ -f "$NPM_PREFIX/bin/hq.cmd" ]; then
  HQ_BIN_DIR="$NPM_PREFIX/bin"
elif [ -f "$NPM_PREFIX/hq" ] || [ -f "$NPM_PREFIX/hq.cmd" ]; then
  # npm places global command shims directly in prefix on Windows.
  HQ_BIN_DIR="$NPM_PREFIX"
else
  printf '%s: npm installed hq-cli without an hq executable in the global bin directory\n' "$NPM_PREFIX" >&2
  exit 1
fi
export PATH="$HQ_BIN_DIR:$PATH"
if [ -n "${GITHUB_PATH:-}" ]; then
  if [ "$HQ_BIN_DIR" = "$NPM_PREFIX" ]; then
    GITHUB_BIN_DIR="$GITHUB_NPM_PREFIX"
  elif [ "$GITHUB_NPM_PREFIX" != "$NPM_PREFIX" ]; then
    GITHUB_BIN_DIR="$(cygpath -w "$HQ_BIN_DIR")"
  else
    GITHUB_BIN_DIR="$HQ_BIN_DIR"
  fi
  printf '%s\n' "$GITHUB_BIN_DIR" >> "$GITHUB_PATH"
fi

ACTUAL_VERSION="$(hq --version)"
if [[ ! "$ACTUAL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][A-Za-z0-9.-]+)?$ ]]; then
  printf 'expected a valid hq --version, got %s\n' "$ACTUAL_VERSION" >&2
  exit 1
fi
if [ "$SELECTED_VERSION" != "latest" ] && [ "$ACTUAL_VERSION" != "$SELECTED_VERSION" ]; then
  printf 'expected hq --version %s, got %s\n' "$SELECTED_VERSION" "$ACTUAL_VERSION" >&2
  exit 1
fi
if ! hq core --help >/dev/null 2>&1; then
  printf 'hq-cli %s is missing the hq core command group\n' "$ACTUAL_VERSION" >&2
  exit 1
fi
printf 'installed @indigoai-us/hq-cli@%s; hq --version: %s\n' "$SELECTED_VERSION" "$ACTUAL_VERSION"
