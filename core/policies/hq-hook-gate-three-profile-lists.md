---
id: hq-hook-gate-three-profile-lists
title: hook-gate.sh has three INDEPENDENT profile lists — a safety hook must be in all three
scope: global
trigger: adding or modifying a PreToolUse/PostToolUse hook routed through .claude/hooks/hook-gate.sh
enforcement: hard
public: true
version: 1
created: 2026-05-18
updated: 2026-05-18
source: user-correction
tags: [infrastructure, safety, knowledge]
---

## Rule

`.claude/hooks/hook-gate.sh` defines THREE separate allowlist functions — `is_in_minimal_profile`, `is_in_standard_profile`, `is_in_strict_profile`. They are **independent case lists, NOT supersets** of each other. The default runtime profile is `standard`. A hook id added only to the minimal list (or only one list) silently no-ops under the default profile: the gate reads stdin, discards it, and returns pass-through `exit 0` — the hook never runs and there is no error.

When adding a safety-critical hook:

1. Add the hook id to **all three** case lists in `hook-gate.sh` (minimal, standard, strict).
2. Wire it into the tracked `.claude/settings.json` (not `settings.local.json`).
3. Verify mechanically before trusting it — pipe a known-block input through the gate under every profile:
   ```bash
   for p in minimal standard strict; do
     echo "{\"tool_input\":{\"command\":\"<known-block-cmd>\"}}" \
       | HQ_HOOK_PROFILE=$p CLAUDE_PROJECT_DIR=$PWD \
         bash .claude/hooks/hook-gate.sh <id> .claude/hooks/<script>; echo "$p rc=$?"
   done
   ```
   Expect `rc=2` for all three.

## Rationale

2026-05-18: `block-hq-root-git-mutation.sh` was added only to `is_in_minimal_profile`. Direct invocation of the hook passed a 17-case test matrix, but routed through `hook-gate.sh` under the default `standard` profile it returned `exit 0` (allow) — the guard was effectively dead. Caught only because the work explicitly tested the gate path. A safety hook that no-ops under the default profile is worse than no hook: it creates false confidence.
