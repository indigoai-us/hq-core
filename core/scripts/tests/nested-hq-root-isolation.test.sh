#!/usr/bin/env bash
# hq-core: public
# A nested HQ install (a second HQ, or a test fixture under another HQ's
# tree) is its own root. resolve-hq-root.sh returns the nearest root to the
# cwd even when HQ_ROOT or ~/.hq/root name the outer install; master-hook
# rebinds an inherited outer HQ_ROOT to its own root for child hooks, drops
# the inherited company scope, keeps session state under its own workspace,
# and warns at SessionStart about what Claude Code still reads from above.
#
# Runs under the bash that runs it ("$BASH"), so run it once with
# /bin/bash (3.2 on macOS) and once with bash 5.

# shellcheck disable=SC2016 # Single-quoted scripts run in a child bash.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SH="${BASH:-bash}"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq required"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

# Outer install: an HQ root that is a git repository with .claude/ and a
# charter CLAUDE.md, like a real install.
OUTER="$TMP/outer"
mkdir -p "$OUTER/core" "$OUTER/.claude" "$OUTER/.git" "$OUTER/workspace/sessions" "$TMP/home/.hq" "$TMP/elsewhere"
printf 'version: 0.0.0\n' > "$OUTER/core/core.yaml"
printf '# outer charter\n' > "$OUTER/.claude/CLAUDE.md"
printf '{}\n' > "$OUTER/.claude/settings.local.json"
printf '%s\n' "$OUTER" > "$TMP/home/.hq/root"
# CLAUDE.md files above the outer root (like the user's global
# ~/.claude/CLAUDE.md) are outside HQ and never named by the nested report.
mkdir -p "$TMP/.claude"
printf '# above hq\n' > "$TMP/CLAUDE.md"
printf '# global memory\n' > "$TMP/.claude/CLAUDE.md"

# Nested install with the real dispatcher, resolver and libraries.
NESTED="$OUTER/workspace/nested-hq"
mkdir -p "$NESTED/.claude/hooks" "$NESTED/core/scripts/lib" "$NESTED/workspace/sessions" \
  "$NESTED/personal/hooks/SessionStart" "$NESTED/deep/dir"
printf 'version: 0.0.0\n' > "$NESTED/core/core.yaml"
cp "$ROOT/.claude/hooks/master-hook.sh" "$ROOT/.claude/hooks/hook-timeout-probe.sh" \
  "$ROOT/.claude/hooks/bash-arith-subst-guard-lib.sh" "$NESTED/.claude/hooks/"
cp "$ROOT/core/scripts/resolve-hq-root.sh" "$ROOT/core/scripts/hq-session.sh" \
  "$ROOT/core/scripts/hook-lib.sh" "$NESTED/core/scripts/"
cp -R "$ROOT/core/scripts/lib/." "$NESTED/core/scripts/lib/"
# Probe child hook: records the root and company scope a child hook sees.
cat > "$NESTED/personal/hooks/SessionStart/10-probe.sh" <<PROBE
#!/usr/bin/env bash
cat >/dev/null
printf 'HQ_ROOT=%s\nHQ_ACTIVE_COMPANY=%s\nHQ_COMPANY_SLUG=%s\n' "\${HQ_ROOT:-}" "\${HQ_ACTIVE_COMPANY:-}" "\${HQ_COMPANY_SLUG:-}" > "$TMP/probe.out"
exit 0
PROBE
chmod +x "$NESTED/personal/hooks/SessionStart/10-probe.sh"

RESOLVER="$NESTED/core/scripts/resolve-hq-root.sh"
resolve() { # <cwd> [env assignments...]
  local cwd="$1"; shift
  (cd "$cwd" && env -u HQ_ROOT HOME="$TMP/home" "$@" "$SH" "$RESOLVER")
}

# 1. Resolver: the nearest root wins over an outer HQ_ROOT and the pointer.
[ "$(resolve "$NESTED" HQ_ROOT="$OUTER")" = "$NESTED" ] || fail "HQ_ROOT=outer from nested cwd did not resolve the nested root"
[ "$(resolve "$NESTED/deep/dir" HQ_ROOT="$OUTER")" = "$NESTED" ] || fail "deep nested cwd did not resolve the nested root"
[ "$(resolve "$NESTED")" = "$NESTED" ] || fail "the home .hq/root pointer beat the nested cwd walk-up"
pass "nested cwd resolves the nested root over HQ_ROOT and ~/.hq/root"

# 2. Resolver: outside the nested install nothing changes.
[ "$(resolve "$OUTER/workspace" HQ_ROOT="$OUTER")" = "$OUTER" ] || fail "outer cwd lost HQ_ROOT=outer"
[ "$(resolve "$TMP/elsewhere" HQ_ROOT="$OUTER")" = "$OUTER" ] || fail "foreign cwd lost HQ_ROOT"
[ "$(resolve "$TMP/elsewhere")" = "$OUTER" ] || fail "foreign cwd lost the pointer fallback"
[ "$(resolve "$OUTER" HQ_ROOT="$NESTED")" = "$NESTED" ] || fail "explicit HQ_ROOT naming the nested root was not honoured"
[ "$(resolve "$OUTER" HQ_ROOT="$TMP/elsewhere")" = "$TMP/elsewhere" ] || fail "explicit unrelated HQ_ROOT was not honoured"
pass "outer, foreign and explicit HQ_ROOT resolution is unchanged"

# 3. Nested report names the git-root settings and parent CLAUDE.md leaks.
report() { # <root> -> prints HQ_NESTED_REPORT, exit status of the helper
  "$SH" -c '. "$1" --lib; hq_root_nested_report "$2"; rc=$?; printf "%s" "$HQ_NESTED_REPORT"; exit $rc' _ "$RESOLVER" "$1"
}
out="$(report "$NESTED")" || fail "nested root not reported"
case "$out" in *"inside another HQ install ($OUTER)"*) ;; *) fail "report lacks the outer root: $out" ;; esac
case "$out" in *"$OUTER/.claude/settings.local.json"*) ;; *) fail "report lacks the git-root settings.local.json leak: $out" ;; esac
case "$out" in *"$OUTER/.claude/CLAUDE.md"*) ;; *) fail "report lacks the parent CLAUDE.md: $out" ;; esac
case "$out" in *"$TMP/CLAUDE.md"*|*"$TMP/.claude/CLAUDE.md"*) fail "report named a CLAUDE.md above the outer HQ root: $out" ;; esac
case "$out" in *".claude/skills"*) fail "report named a skills folder that does not exist: $out" ;; esac
rm "$OUTER/.claude/settings.local.json"
out="$(report "$NESTED")" || fail "nested root with parent CLAUDE.md not reported"
case "$out" in *settings.local.json*) fail "report named a settings.local.json that does not exist: $out" ;; esac
rm "$OUTER/.claude/CLAUDE.md"
if report "$NESTED" >/dev/null; then fail "nested install with no outer settings.local.json, skills or CLAUDE.md still warned"; fi
mkdir "$OUTER/.claude/skills"
out="$(report "$NESTED")" || fail "outer git-root skills not reported"
case "$out" in *"$OUTER/.claude/skills"*) ;; *) fail "report lacks the git-root skills leak: $out" ;; esac
rmdir "$OUTER/.claude/skills"
printf '{}\n' > "$OUTER/.claude/settings.local.json"
printf '# outer charter\n' > "$OUTER/.claude/CLAUDE.md"
mkdir "$NESTED/.git"
out="$(report "$NESTED")" || fail "nested git repo with parent CLAUDE.md not reported"
case "$out" in *settings.local.json*) fail "own git repo still reported the settings leak: $out" ;; esac
rm "$OUTER/.claude/CLAUDE.md"
if report "$NESTED" >/dev/null; then fail "isolated nested install (own git repo, no parent CLAUDE.md) still warned"; fi
if report "$OUTER" >/dev/null; then fail "top-level install reported as nested"; fi
rmdir "$NESTED/.git"
printf '# outer charter\n' > "$OUTER/.claude/CLAUDE.md"
pass "nested report names only the leaks that exist"

# 4. master-hook in the nested install, launched with the outer install's
# HQ_ROOT and company scope inherited.
run_master() { # <sid> [env assignments...]
  local sid="$1"; shift
  jq -cn --arg sid "$sid" --arg cwd "$NESTED" \
    '{session_id:$sid, cwd:$cwd, hook_event_name:"SessionStart", source:"startup"}' \
    | (cd "$NESTED" && env -u HQ_FLAGS_API_URL -u HQ_COMPANY_UID HOME="$TMP/home" \
        HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HQ_SESSION_NO_CLI=1 HQ_FLAG_HQ_ANYWHERE_RUNTIME=0 \
        CLAUDE_PROJECT_DIR="$NESTED" "$@" \
        "$SH" "$NESTED/.claude/hooks/master-hook.sh" SessionStart) >"$TMP/master.out" 2>"$TMP/master.err" \
    || fail "master-hook exited non-zero: $(head -5 "$TMP/master.err")"
}
rm -f "$TMP/probe.out"
run_master nested-sess-1 HQ_ROOT="$OUTER" HQ_ACTIVE_COMPANY=outerco HQ_COMPANY_SLUG=outerco
[ -f "$TMP/probe.out" ] || fail "probe child hook did not run: $(head -5 "$TMP/master.err")"
grep -qx "HQ_ROOT=$NESTED" "$TMP/probe.out" || fail "child hook saw the outer root: $(cat "$TMP/probe.out")"
grep -qx 'HQ_ACTIVE_COMPANY=' "$TMP/probe.out" || fail "child hook kept the outer company scope: $(cat "$TMP/probe.out")"
grep -qx 'HQ_COMPANY_SLUG=' "$TMP/probe.out" || fail "child hook kept the outer company slug: $(cat "$TMP/probe.out")"
pass "child hooks get the nested root and no inherited company scope"

[ -f "$NESTED/workspace/sessions/nested-sess-1/meta.yaml" ] || fail "session meta not under the nested workspace"
[ ! -e "$OUTER/workspace/sessions/nested-sess-1" ] || fail "session state written under the outer workspace"
pass "session state stays in the nested install"

ctx="$(jq -r '.hookSpecificOutput.additionalContext // ""' "$TMP/master.out")"
case "$ctx" in *"inside another HQ install ($OUTER)"*"settings.local.json"*) ;; *) fail "SessionStart lacks the nested-install warning: $(cat "$TMP/master.out")" ;; esac
pass "SessionStart warns about the nested install"

run_master nested-sess-2 HQ_ROOT="$OUTER" HQ_NESTED_ROOT_WARNING=0
if grep -q 'inside another HQ install' "$TMP/master.out"; then fail "HQ_NESTED_ROOT_WARNING=0 did not silence the warning"; fi
pass "HQ_NESTED_ROOT_WARNING=0 silences the warning"

# 5. An HQ_ROOT that is not an ancestor (explicit override) reaches children unchanged.
rm -f "$TMP/probe.out"
run_master nested-sess-3 HQ_ROOT="$TMP/elsewhere" HQ_ACTIVE_COMPANY=keepco HQ_NESTED_ROOT_WARNING=0
grep -qx "HQ_ROOT=$TMP/elsewhere" "$TMP/probe.out" || fail "unrelated HQ_ROOT was rewritten: $(cat "$TMP/probe.out")"
grep -qx 'HQ_ACTIVE_COMPANY=keepco' "$TMP/probe.out" || fail "unrelated HQ_ROOT dropped company scope: $(cat "$TMP/probe.out")"
pass "a non-ancestor HQ_ROOT is left alone"

# 6. An ancestor HQ_ROOT that is not an HQ root (no core/core.yaml) is left
# alone too: no rebind, and the company scope stays.
rm -f "$TMP/probe.out"
run_master nested-sess-4 HQ_ROOT="$TMP" HQ_ACTIVE_COMPANY=keepco HQ_NESTED_ROOT_WARNING=0
grep -qx "HQ_ROOT=$TMP" "$TMP/probe.out" || fail "non-HQ ancestor HQ_ROOT was rebound: $(cat "$TMP/probe.out")"
grep -qx 'HQ_ACTIVE_COMPANY=keepco' "$TMP/probe.out" || fail "non-HQ ancestor HQ_ROOT dropped company scope: $(cat "$TMP/probe.out")"
pass "a non-HQ ancestor HQ_ROOT is left alone"

# 7. hook-gate.sh fallback: when the gate's own core/scripts/hook-lib.sh is
# missing, it resolves the root anchored on its own install, so a root
# planted under the cwd cannot supply hook-lib.sh.
GATE_HQ="$TMP/gate-hq"
mkdir -p "$GATE_HQ/.claude/hooks" "$GATE_HQ/core/scripts" "$GATE_HQ/repos/evil/core/scripts"
printf 'version: 0.0.0\n' > "$GATE_HQ/core/core.yaml"
cp "$ROOT/.claude/hooks/hook-gate.sh" "$GATE_HQ/.claude/hooks/"
cp "$ROOT/core/scripts/resolve-hq-root.sh" "$GATE_HQ/core/scripts/"
printf '#!/bin/bash\ncat >/dev/null\nexit 0\n' > "$GATE_HQ/.claude/hooks/noop-guard.sh"
chmod +x "$GATE_HQ/.claude/hooks/hook-gate.sh" "$GATE_HQ/.claude/hooks/noop-guard.sh"
printf 'version: 0.0.0\n' > "$GATE_HQ/repos/evil/core/core.yaml"
printf 'touch "%s"\n' "$TMP/planted-hook-lib-ran" > "$GATE_HQ/repos/evil/core/scripts/hook-lib.sh"
for gate_env in "HQ_ROOT=$GATE_HQ" "HQ_GATE_TEST_UNUSED=1"; do
  rm -f "$TMP/planted-hook-lib-ran"
  printf '{}' | (cd "$GATE_HQ/repos/evil" && env -u HQ_ROOT -u CLAUDE_PROJECT_DIR -u HQ_FLAG_HQ_ANYWHERE_RUNTIME \
    HOME="$TMP/home" "$gate_env" "$SH" "$GATE_HQ/.claude/hooks/hook-gate.sh" noop-guard "$GATE_HQ/.claude/hooks/noop-guard.sh") \
    >/dev/null 2>"$TMP/gate.err" || fail "hook-gate fallback run failed ($gate_env): $(head -5 "$TMP/gate.err")"
  [ ! -e "$TMP/planted-hook-lib-ran" ] || fail "hook-gate fallback sourced a planted hook-lib.sh ($gate_env)"
done
pass "hook-gate fallback anchors on its own install, not a planted root"

echo "PASS: nested-hq-root-isolation ($("$SH" -c 'echo "$BASH_VERSION"'))"
