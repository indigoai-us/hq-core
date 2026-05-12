#!/bin/bash
# PreCompact hook: fires right before autocompact runs (at the threshold set
# by CLAUDE_AUTOCOMPACT_PCT_OVERRIDE, default 60%). Autocompact cannot be
# blocked, so this hook surfaces an advisory with three options — it does
# NOT force /checkpoint. The user decides.
#
# Companion hook context-warning-50.sh fires earlier (once per session at
# ~50%) to give runway before this banner ever appears.

cat <<'EOF'
╔══════════════════════════════════════════════════════════════╗
║  Context at 60% — autocompact about to run                   ║
╠══════════════════════════════════════════════════════════════╣
║  Compaction will condense older turns. Pick one:             ║
║                                                              ║
║   • Checkpoint now      — /checkpoint (save thread state)    ║
║   • Handoff now         — /handoff (full session wrap-up)    ║
║   • Continue            — accept compaction, keep working    ║
║                                                              ║
║  If mid-edit, save the file first either way.                ║
╚══════════════════════════════════════════════════════════════╝
EOF
