#!/usr/bin/env bash
# Regression tests for the path-gated reindex hook (.claude/hooks/reindex.sh).
#
# reindex.sh must run `hq reindex` ONLY when a reindex-relevant file is created,
# edited, or deleted — a skill, a worker, or a personal-overlay entry
# (knowledge/policies/settings). It is wired to PostToolUse Write/Edit/MultiEdit
# (create+edit, gated on file_path) and PostToolUse Bash (delete/move, gated on a
# mutating command that names a relevant path). Every other event — an edit to
# an unrelated file, a read-only bash command, a Stop/SessionStart/UserPromptSubmit
# payload with no file path — must be a no-op.
#
# Strategy: shadow `hq` with a fake on PATH that touches a sentinel when invoked.
# Feed reindex.sh a hook payload on stdin; the sentinel's presence tells us
# whether the gate decided to run `hq reindex`. No real reindex ever runs.

set -euo pipefail

# Anchor to THIS file's location (core/scripts/tests/), not cwd — so the test
# always exercises the co-located hook regardless of where it is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HOOK="$ROOT/.claude/hooks/reindex.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[ -f "$HOOK" ] || fail "reindex.sh not found at $HOOK"

# Fake `hq` that records an invocation, shadowing the real CLI.
TMPBIN="$(mktemp -d)"
SENTINEL="$TMPBIN/ran"
cat > "$TMPBIN/hq" <<EOF
#!/usr/bin/env bash
# Only the reindex subcommand should ever be dispatched by the hook.
[ "\${1:-}" = "reindex" ] && : > "$SENTINEL"
exit 0
EOF
chmod +x "$TMPBIN/hq"
trap 'rm -rf "$TMPBIN"' EXIT

# run_gate <payload> -> echoes RAN | SKIP
# `hq` may be an exported shell function on dev machines, which would shadow a
# PATH-based fake. Run the hook under `env -i` with a curated PATH so no exported
# function leaks in and our fake `hq` (first on PATH) is the only one reachable.
run_gate() {
  rm -f "$SENTINEL"
  printf '%s' "$1" \
    | env -i PATH="$TMPBIN:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" bash "$HOOK" \
      >/dev/null 2>&1 || true
  [ -f "$SENTINEL" ] && echo RAN || echo SKIP
}

assert() { # <desc> <expected RAN|SKIP> <payload>
  local got; got="$(run_gate "$3")"
  [ "$got" = "$2" ] && pass "$1 → $got" || fail "$1: expected $2, got $got"
}

# JSON-escape helper for embedding absolute paths in payloads.
wj() { printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2"; }
bj() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }

echo "[1] create/edit of relevant files → RAN"
assert "Write core skill"        RAN "$(wj Write     "$ROOT/core/skills/demo/SKILL.md")"
assert "Write personal policy"   RAN "$(wj Write     "$ROOT/personal/policies/x.md")"
assert "Write personal knowledge" RAN "$(wj Write    "$ROOT/personal/knowledge/x/README.md")"
assert "Write personal settings" RAN "$(wj Write     "$ROOT/personal/settings/foo.yaml")"
assert "Write company worker"     RAN "$(wj Write    "$ROOT/companies/acme/workers/w/worker.yaml")"
assert "Write pack skill"         RAN "$(wj Write    "$ROOT/core/packages/hq-pack-x/skills/s/SKILL.md")"
assert "Write generated wrapper"  RAN "$(wj Write    "$ROOT/.claude/skills/core:demo/SKILL.md")"
assert "Edit core skill"          RAN "$(wj Edit     "$ROOT/core/skills/demo/SKILL.md")"
assert "MultiEdit personal skill" RAN "$(wj MultiEdit "$ROOT/personal/skills/mine/SKILL.md")"

echo "[2] create/edit of irrelevant files → SKIP"
assert "Write workspace note"   SKIP "$(wj Write "$ROOT/workspace/notes.md")"
assert "Write repo skills dir"  SKIP "$(wj Write "$ROOT/repos/public/app/skills/thing.md")"
assert "Write company knowledge (not overlay)" SKIP "$(wj Write "$ROOT/companies/acme/knowledge/x.md")"
assert "Write file outside REPO_ROOT" SKIP "$(wj Write "/tmp/other/core/skills/x/SKILL.md")"

echo "[3] Bash delete/move of relevant paths → RAN"
assert "rm -rf a skill"     RAN "$(bj "rm -rf $ROOT/core/skills/demo")"
assert "git mv skill"       RAN "$(bj "git -C $ROOT mv core/skills/a core/skills/b")"
assert "cp into personal/skills" RAN "$(bj "cp -r /tmp/x personal/skills/newskill")"
assert "rm a personal policy" RAN "$(bj "rm $ROOT/personal/policies/old.md")"

echo "[4] Bash that must NOT reindex → SKIP"
assert "read-only ls over skills" SKIP "$(bj "ls -la $ROOT/core/skills/")"
assert "cat a skill file"         SKIP "$(bj "cat $ROOT/core/skills/demo/SKILL.md")"
assert "mutation on irrelevant path" SKIP "$(bj "rm -rf $ROOT/workspace/tmp")"

echo "[5] no file path / non-tool events → SKIP"
assert "Stop payload"          SKIP '{"hook_event_name":"Stop"}'
assert "SessionStart payload"  SKIP '{"hook_event_name":"SessionStart"}'
assert "empty payload"         SKIP ''

echo "ALL PASS"
