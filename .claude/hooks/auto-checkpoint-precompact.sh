#!/bin/bash
# PreCompact hook: fires right before autocompact runs (at the threshold set
# by CLAUDE_AUTOCOMPACT_PCT_OVERRIDE, default 60%). Autocompact cannot be
# blocked, so this hook emits a mandatory checkpoint directive for the next
# assistant turn. The companion Stop hook should normally have fired earlier.
#
# Companion hook context-warning-50.sh fires earlier (once per session at
# ~50%) to give runway before this banner ever appears.

cat <<'EOF'
╔══════════════════════════════════════════════════════════════╗
║  AUTO-CHECKPOINT REQUIRED — precompact backup                ║
╠══════════════════════════════════════════════════════════════╣
║  Autocompact is about to condense older turns.               ║
║                                                              ║
║  On the next assistant turn, run /checkpoint before any      ║
║  other work. Do not ask the user first.                      ║
║                                                              ║
║  Keep it focused: preserve recoverable state, then continue. ║
╚══════════════════════════════════════════════════════════════╝
EOF
