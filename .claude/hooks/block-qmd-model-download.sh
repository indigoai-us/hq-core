#!/bin/bash
# block-qmd-model-download.sh — PreToolUse hook (Bash).
#
# Blocks foreground `qmd vsearch|query|embed|pull` when the local GGUF cache
# is empty. First use auto-downloads ~300MB–2GB from HuggingFace and has
# stalled a single Windows HQ prompt for hours (landersrx, core 15.0.136).
#
# Allows:
#   - qmd search / update / status / collection (no model pull)
#   - vsearch/query/embed/pull when ~/.cache/qmd/models already has a GGUF
#   - run_in_background: true (the sanctioned way to pull/embed)
#   - HQ_ALLOW_QMD_MODEL_DOWNLOAD=1
#
# Fails open when the payload cannot be read. Exit 2 blocks.
#
# Backs policy hq-no-in-turn-qmd-model-download.

set -uo pipefail

STDIN_JSON="$(cat 2>/dev/null || echo '{}')"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=core/scripts/hook-lib.sh
. "$ROOT/core/scripts/hook-lib.sh"
# shellcheck source=core/scripts/lib/portable.sh
. "$ROOT/core/scripts/lib/portable.sh"

if [ "${HQ_ALLOW_QMD_MODEL_DOWNLOAD:-0}" = "1" ]; then
  exit 0
fi

CMD="$(printf '%s' "$STDIN_JSON" | hq_json_get tool_input.command)"
[ -z "$CMD" ] && CMD="$(printf '%s' "$STDIN_JSON" | hq_json_get tool_input.cmd)"
[ -z "$CMD" ] && exit 0

BG="$(printf '%s' "$STDIN_JSON" | hq_json_get tool_input.run_in_background)"
case "$BG" in
  true|True|TRUE|1) exit 0 ;;
esac

portable_qmd_cmd_would_download_model "$CMD" || exit 0

if portable_qmd_embed_model_ready; then
  exit 0
fi

cat >&2 <<'EOF'
BLOCKED: this qmd command would download a local GGUF embedding model
(~300MB–2GB) in the current turn. On Windows that has stalled a single
HQ prompt for more than two hours.

Use BM25 in-turn (no model download):
  qmd search "<query>" --json -n 10

Build embeddings out of band:
  hq index background
  # or run `qmd pull` / `qmd embed` with run_in_background: true

Escape hatch: HQ_ALLOW_QMD_MODEL_DOWNLOAD=1
EOF
exit 2
