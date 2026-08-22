#!/bin/sh
set -eu

# Cowork is launched by a macOS GUI process, so it does not inherit the shell
# profile entry that HQ Desktop installs for its managed toolchain. Resolve the
# managed Node runtime explicitly before falling back to the inherited PATH and
# common system locations. Every candidate stays quoted because both the HQ
# Desktop toolchain and the installed plugin path can contain spaces.
case "$0" in
  */*) SCRIPT_DIR=${0%/*} ;;
  *) SCRIPT_DIR=. ;;
esac

TOOLCHAIN=${HQ_TOOLCHAIN_DIR:-"$HOME/Library/Application Support/Indigo HQ/toolchain"}
NODE=""

case ${NODE_BIN:-} in
  /*)
    if [ -x "$NODE_BIN" ]; then
      NODE=$NODE_BIN
    fi
    ;;
esac

if [ -z "$NODE" ] && [ -x "$TOOLCHAIN/node/bin/node" ]; then
  NODE="$TOOLCHAIN/node/bin/node"
fi

if [ -z "$NODE" ]; then
  NODE=$(command -v node 2>/dev/null || true)
fi

if [ -z "$NODE" ]; then
  for candidate in \
    "$HOME/.local/bin/node" \
    "$HOME/bin/node" \
    /opt/homebrew/bin/node \
    /usr/local/bin/node \
    /usr/bin/node
  do
    if [ -x "$candidate" ]; then
      NODE=$candidate
      break
    fi
  done
fi

if [ -z "$NODE" ]; then
  echo "hq-pack-cowork: node was not found in HQ Desktop's managed toolchain, PATH, or common install locations" >&2
  exit 127
fi

exec "$NODE" "$SCRIPT_DIR/index.mjs" "$@"
