#!/bin/sh
set -eu

case "$0" in
  */*) SCRIPT_DIR=${0%/*} ;;
  *) SCRIPT_DIR=. ;;
esac
PLUGIN_ROOT=${SCRIPT_DIR%/*}

prepend_dir() {
  [ -d "$1" ] || return 0
  case ":${PATH:-}:" in *":$1:"*) return 0 ;; esac
  PATH="$1${PATH:+:$PATH}"
}

if [ -n "${HQ_TOOLCHAIN_DIR:-}" ]; then
  prepend_dir "$HQ_TOOLCHAIN_DIR/node/bin"
  prepend_dir "$HQ_TOOLCHAIN_DIR/npm-global/bin"
  prepend_dir "$HQ_TOOLCHAIN_DIR/git/bin"
else
  for toolchain in \
    "$HOME/Library/Application Support/Indigo HQ/toolchain" \
    "$HOME/AppData/Roaming/Indigo HQ/toolchain" \
    "$HOME/AppData/Local/Indigo HQ/toolchain"
  do
    prepend_dir "$toolchain/node/bin"
    prepend_dir "$toolchain/npm-global/bin"
    prepend_dir "$toolchain/git/bin"
  done
fi
export PATH

mode=${1:-}
[ $# -gt 0 ] && shift
case "$mode" in
  hook)
    exec /bin/sh "$PLUGIN_ROOT/scripts/hq/hqd-hook-shim.sh" "$@"
    ;;
  mcp)
    hq_bin=$(command -v hq 2>/dev/null || true)
    [ -n "$hq_bin" ] || {
      echo "HQ plugin: hq CLI not found in managed toolchain or PATH" >&2
      exit 127
    }
    exec "$hq_bin" mcp "$@"
    ;;
  *)
    echo "usage: hq-claude-plugin-launch.sh {hook <event> [args...]|mcp serve}" >&2
    exit 2
    ;;
esac
