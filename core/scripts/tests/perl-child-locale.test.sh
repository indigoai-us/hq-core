#!/usr/bin/env bash
# Regression test: perl timeout/exec wrappers must hand the CALLER's locale to
# the child they start, and must keep bounding the child when the shared lib is
# absent.
#
# Shipped perl calls run under LC_ALL=C so Apple's Perl 5.34 does not panic on
# LC_ALL/LANG=C.utf8 (see perl-locale-guard.test.sh). A wrapper such as
# `LC_ALL=C perl -e 'alarm shift; exec @ARGV'` then passes LC_ALL=C to the
# command it execs: a hook run through it counts string length in bytes, splits
# a multibyte character in substrings, and sorts differently. The wrappers must
# restore the caller's LC_ALL inside perl before the exec
# (core/scripts/lib/perl-child-locale.sh).
#
# Mode "lib" (lib present): the child prints its LC_ALL state. The caller runs
# with LANG=C.utf8 and LC_ALL unset, C.utf8, en_US.UTF-8, and set-but-empty. The
# child must see exactly what the caller had, and perl must not panic (a panic
# is exit 9 with no child output).
#
# Mode "nolib" (fixture tree without perl-child-locale.sh, as in a partial
# copy): every wrapper must still run the child (no silent skip, no exit 127)
# under plain `LC_ALL=C perl`.
#
# Both modes: a child that sleeps 30s must be stopped by a 1s wrapper deadline.
#
# Wrappers that are functions inside larger scripts are extracted into a
# fixture tree that mirrors the repo layout, so their lib lookup is exercised.
# The extraction also works on older trees, which is how this test is shown to
# fail before the fix.
#
# Usage: bash core/scripts/tests/perl-child-locale.test.sh   (cwd inside the repo)

set -u

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not in a git repo" >&2; exit 2; }
cd "$ROOT" || exit 2

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }

command -v perl >/dev/null 2>&1 || { echo "perl required"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 2; }

case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) echo "skip: perl alarm wrappers are not used on Git Bash"; exit 0 ;;
esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/perlchildloc.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
LIB_SRC="$ROOT/core/scripts/lib/perl-child-locale.sh"
mkdir -p "$TMP/bin" "$TMP/fakebin-report" "$TMP/fakebin-sleep"

# PATH without coreutils timeout/gtimeout so every wrapper takes its perl branch.
BASH_BIN="$(command -v bash)"
for c in perl bash jq cat chmod mkdir mktemp basename dirname uname tr sed awk \
         sort cut head grep env sleep date hostname id ps rm mv cp ln printf \
         touch wc tee xargs which sh ls file find stat readlink printenv; do
  p="$(command -v "$c" 2>/dev/null)" || continue
  case "$p" in /*) ;; *) continue ;; esac
  [ -e "$TMP/bin/$c" ] || ln -s "$p" "$TMP/bin/$c" 2>/dev/null || true
done
PERL_PATH="$TMP/bin"

# The child: print its LC_ALL state and whether the carrier variables leaked.
cat >"$TMP/report.sh" <<'SH'
#!/usr/bin/env bash
if [ "${LC_ALL+set}" = set ]; then printf 'LC_ALL=[%s]' "$LC_ALL"; else printf 'LC_ALL=unset'; fi
if [ -n "${HQ_PERL_LC_ALL+x}${HQ_PERL_LC_ALL_SET+x}" ]; then printf ' carriers=LEAKED'; fi
printf '\n'
SH
printf '#!/usr/bin/env bash\nexec sleep 30\n' >"$TMP/sleeper.sh"
cp "$TMP/report.sh" "$TMP/fakebin-report/find"
cp "$TMP/sleeper.sh" "$TMP/fakebin-sleep/find"
chmod +x "$TMP/report.sh" "$TMP/sleeper.sh" "$TMP/fakebin-report/find" "$TMP/fakebin-sleep/find"
REPORT="$TMP/report.sh"
SLEEPER="$TMP/sleeper.sh"

# extract_fn <file> <function-name> <dest>: copy one top-level function.
extract_fn() {
  awk -v name="$2" '
    $0 ~ "^"name"\\(\\)[[:space:]]*\\{" { on = 1 }
    on { print }
    on && /^}/ { exit }
  ' "$1" >"$3"
  [ -s "$3" ]
}

# run_case <driver-file> <locale-case>: run the driver with the case's LC_ALL;
# sets OUT (stdout) and RC.
run_case() {
  local driver="$1" lc="$2"
  RC=0
  case "$lc" in
    unset) OUT="$(env -i PATH="$PERL_PATH" HOME="$TMP" LANG=C.utf8 "$BASH_BIN" "$driver" 2>"$TMP/last.err")" || RC=$? ;;
    empty) OUT="$(env -i PATH="$PERL_PATH" HOME="$TMP" LANG=C.utf8 LC_ALL= "$BASH_BIN" "$driver" 2>"$TMP/last.err")" || RC=$? ;;
    *)     OUT="$(env -i PATH="$PERL_PATH" HOME="$TMP" LANG=C.utf8 LC_ALL="$lc" "$BASH_BIN" "$driver" 2>"$TMP/last.err")" || RC=$? ;;
  esac
}

expect_for() { # <locale-case> -> the report line a faithful wrapper yields
  case "$1" in unset) printf 'LC_ALL=unset' ;; empty) printf 'LC_ALL=[]' ;; *) printf 'LC_ALL=[%s]' "$1" ;; esac
}

CASES="unset C.utf8 en_US.UTF-8 empty"
MODE=lib
FX=""

# add_wrapper <name> <template> [ok-cmd] [bound-cmd]
#   template: driver body lines; @SECS@ is the wrapper deadline, @CMD@ the child,
#   @CMDDIR@ the child's directory. Writes an "ok" driver (5s, reports locale)
#   and a "bound" driver (1s, child sleeps 30s), then checks both for $MODE.
add_wrapper() {
  local name="$1" template="$2" okcmd="${3:-$REPORT}" boundcmd="${4:-$SLEEPER}"
  local base ok bound lc want start elapsed
  base="$(printf '%s' "$MODE-$name" | tr -c 'A-Za-z0-9\n' '_')"
  ok="$TMP/driver-$base-ok.sh"
  bound="$TMP/driver-$base-bound.sh"
  mk_driver "$template" 5 "$okcmd" "$ok"
  mk_driver "$template" 1 "$boundcmd" "$bound"

  if [ "$MODE" = lib ]; then
    for lc in $CASES; do
      run_case "$ok" "$lc"
      want="$(expect_for "$lc")"
      if [ "$RC" -ne 0 ]; then
        fail "$name [$MODE, LC_ALL=$lc]: wrapper failed rc=$RC" "$(head -3 "$TMP/last.err" 2>/dev/null | cut -c1-200)"
      elif [ "$OUT" = "$want" ]; then
        pass "$name [$MODE]: child sees LC_ALL $lc"
      else
        fail "$name [$MODE, LC_ALL=$lc]: child saw '$OUT', expected '$want'"
      fi
    done
  else
    # No lib: the child still runs (plain LC_ALL=C perl), the wrapper does not skip or return 127.
    run_case "$ok" C.utf8
    if [ "$RC" -eq 0 ] && [ "$OUT" = "LC_ALL=[C]" ]; then
      pass "$name [$MODE]: child still runs without the lib"
    else
      fail "$name [$MODE]: child did not run without the lib (rc=$RC out='$OUT')" "$(head -3 "$TMP/last.err" 2>/dev/null | cut -c1-200)"
    fi
  fi

  start="$(date +%s)"
  run_case "$bound" C.utf8
  elapsed=$(( $(date +%s) - start ))
  if [ "$elapsed" -lt 12 ]; then
    pass "$name [$MODE]: a 30s child is stopped by the 1s deadline (${elapsed}s)"
  else
    fail "$name [$MODE]: the 1s deadline did not stop a 30s child (${elapsed}s)"
  fi
}

mk_driver() { # <template> <secs> <cmd> <dest>
  local body="$1" secs="$2" cmd="$3" dest="$4"
  body="${body//@SECS@/$secs}"
  body="${body//@CMDDIR@/${cmd%/*}}"
  body="${body//@CMD@/$cmd}"
  printf '#!/usr/bin/env bash\n%s\n' "$body" >"$dest"
}

# extracted <label> <src> <function> <fixture-dest> <template>
extracted() {
  local label="$1" src="$2" fn="$3" dest="$4" template="$5"
  mkdir -p "$(dirname "$FX/$dest")"
  if ! extract_fn "$ROOT/$src" "$fn" "$FX/$dest"; then
    fail "$label: could not extract $fn from $src"
    return
  fi
  add_wrapper "$label" ". '$FX/$dest'
$template"
}

exercise() { # <mode>
  MODE="$1"
  FX="$TMP/fx-$MODE"
  local LIBDIR="$FX/core/scripts/lib" d f
  mkdir -p "$FX/.claude/hooks" "$FX/core/scripts" "$LIBDIR" "$FX/workspace/threads"
  [ "$MODE" = lib ] && [ -f "$LIB_SRC" ] && cp "$LIB_SRC" "$LIBDIR/"

  if [ "$MODE" = lib ]; then
    if [ -f "$LIBDIR/perl-child-locale.sh" ]; then
      pass "core/scripts/lib/perl-child-locale.sh exists"
      add_wrapper "hq_perl_spawn" ". '$LIBDIR/perl-child-locale.sh'
hq_perl_spawn 'alarm shift; exec {\$ARGV[0]} @ARGV' @SECS@ @CMD@"
      add_wrapper "hq_perl_spawn_argv (run-project)" ". '$LIBDIR/perl-child-locale.sh'
hq_perl_spawn_argv 'alarm shift; exec {\$ARGV[0]} @ARGV'
\"\${HQ_PERL_SPAWN_ARGV[@]}\" @SECS@ @CMD@"
    else
      fail "core/scripts/lib/perl-child-locale.sh is missing"
    fi
  fi

  extracted "check-hq-update.sh bounded_gh_command" \
    .claude/hooks/check-hq-update.sh bounded_gh_command .claude/hooks/check-hq-update.fn.sh \
    "bounded_gh_command @SECS@ @CMD@"
  extracted "usable-integrations.sh run_with_deadline" \
    core/scripts/usable-integrations.sh run_with_deadline core/scripts/usable-integrations.fn.sh \
    "run_with_deadline @SECS@ @CMD@"
  extracted "conduct-lanes-link-deliver.sh run_bounded" \
    .claude/hooks/conduct-lanes-link-deliver.sh run_bounded .claude/hooks/conduct-lanes-link-deliver.fn.sh \
    "run_bounded @SECS@ @CMD@"
  extracted "conduct-lanes-session-start.sh run_bounded" \
    .claude/hooks/conduct-lanes-session-start.sh run_bounded .claude/hooks/conduct-lanes-session-start.fn.sh \
    "run_bounded @SECS@ @CMD@"
  extracted "lanes-senior-monitor-stop-gate.sh run_hq_with_timeout" \
    .claude/hooks/lanes-senior-monitor-stop-gate.sh run_hq_with_timeout .claude/hooks/lanes-senior-monitor-stop-gate.fn.sh \
    "run_hq_with_timeout @SECS@ '$TMP/deadline-marker' @CMD@"
  extracted "anywhere-vm-test.sh run_bounded" \
    core/scripts/anywhere-vm-test.sh run_bounded core/scripts/anywhere-vm-test.fn.sh \
    "run_bounded @SECS@ @CMD@"

  # hook-timeout-probe.sh: GNU timeout check first, then perl. Extract both.
  : >"$FX/.claude/hooks/hook-timeout-probe.fn.sh"
  for f in hook_timeout_has_gnu_timeout hook_timeout_run_bounded; do
    extract_fn "$ROOT/.claude/hooks/hook-timeout-probe.sh" "$f" "$TMP/fn.part" \
      && cat "$TMP/fn.part" >>"$FX/.claude/hooks/hook-timeout-probe.fn.sh"
  done
  add_wrapper "hook-timeout-probe.sh hook_timeout_run_bounded" \
    ". '$FX/.claude/hooks/hook-timeout-probe.fn.sh'
hook_timeout_run_bounded @SECS@ @CMD@"

  # hqd-hook-flag-cache-lib.sh hq_flag_reader_run (sourced as shipped; inline copy).
  # It never uses the lib, so the lib-absent mode adds nothing for it.
  if [ "$MODE" = lib ]; then
    add_wrapper "hqd-hook-flag-cache-lib.sh hq_flag_reader_run" \
      ". '$ROOT/core/scripts/hqd-hook-flag-cache-lib.sh'
HQ_FLAG_READER_TIMEOUT_MS=\$(( @SECS@ * 1000 )) hq_flag_reader_run @CMD@"
  fi

  # checkpoint-recent-auto.sh: a fake find in front of PATH reports (or sleeps).
  cp "$ROOT/core/scripts/checkpoint-recent-auto.sh" "$FX/core/scripts/checkpoint-recent-auto.sh"
  add_wrapper "checkpoint-recent-auto.sh" \
    "PATH='@CMDDIR@':\"\$PATH\"
HQ_CHECKPOINT_FIND_TIMEOUT=@SECS@ bash '$FX/core/scripts/checkpoint-recent-auto.sh' '$FX' 5" \
    "$TMP/fakebin-report/find" "$TMP/fakebin-sleep/find"

  # bench-runtime.sh bench_runtime_dispatch (claude runtime): the entrypoint is a
  # fake master-hook that reports its locale on stdout (or sleeps).
  mkdir -p "$FX/core/scripts/lib" "$TMP/benchroot-report-$MODE/.claude/hooks" "$TMP/benchroot-sleep-$MODE/.claude/hooks"
  cp "$ROOT/core/scripts/lib/bench-runtime.sh" "$FX/core/scripts/lib/bench-runtime.sh"
  cp "$REPORT" "$TMP/benchroot-report-$MODE/.claude/hooks/master-hook.sh"
  cp "$SLEEPER" "$TMP/benchroot-sleep-$MODE/.claude/hooks/master-hook.sh"
  add_wrapper "bench-runtime.sh bench_runtime_dispatch" \
    ". '$FX/core/scripts/lib/bench-runtime.sh'
bench_runtime_dispatch claude '@CMD@' PreToolUse '{}' '$TMP/bench.out' '$TMP/bench.err' '$TMP' @SECS@ || true
cat '$TMP/bench.out'" \
    "$TMP/benchroot-report-$MODE" "$TMP/benchroot-sleep-$MODE"

  # master-hook.sh perl fallback, end to end. The registry hook is the child.
  local MR="$TMP/mhroot-$MODE"
  mkdir -p "$MR/.claude/hooks" "$MR/core/scripts/lib"
  for f in master-hook.sh hook-gate.sh hook-timeout-probe.sh; do
    cp "$ROOT/.claude/hooks/$f" "$MR/.claude/hooks/$f"
  done
  cp "$ROOT/core/scripts/lib/hook-adapter-core.sh" "$MR/core/scripts/lib/"
  [ "$MODE" = lib ] && [ -f "$LIB_SRC" ] && cp "$LIB_SRC" "$MR/core/scripts/lib/"
  cat >"$MR/.claude/hooks/locale-probe.sh" <<SH
#!/usr/bin/env bash
cat >/dev/null
if [ "\${LC_ALL+set}" = set ]; then printf 'LC_ALL=[%s]' "\$LC_ALL" >"$TMP/mh.out"; else printf 'LC_ALL=unset' >"$TMP/mh.out"; fi
exit 0
SH
  printf '#!/usr/bin/env bash\ncat >/dev/null\nexec sleep 30\n' >"$MR/.claude/hooks/sleeper-hook.sh"
  chmod +x "$MR/.claude/hooks/"*.sh
  jq -nc --arg p "$MR/core/X.txt" --arg cwd "$MR" \
    '{hook_event_name:"PreToolUse",session_id:"perl-child-locale",cwd:$cwd,tool_name:"Write",tool_input:{file_path:$p,content:"p"}}' \
    >"$TMP/mh.payload"
  add_wrapper "master-hook.sh perl child timeout (every registry hook)" \
    "rm -f '$TMP/mh.out'
jq -n '{hooks:{PreToolUse:[{matcher:\"Write\",hooks:[{id:\"probe\",script:\".claude/hooks/@CMD@\",timeout:@SECS@,gated:false}]}]}}' >'$MR/.claude/hooks/hook-registry.json'
HQ_HOOK_TIMEOUT_SENTRY=0 CLAUDE_PROJECT_DIR='$MR' '$BASH_BIN' '$MR/.claude/hooks/master-hook.sh' PreToolUse <'$TMP/mh.payload' >/dev/null 2>&1
cat '$TMP/mh.out' 2>/dev/null || echo 'probe-did-not-run'" \
    locale-probe.sh sleeper-hook.sh

  # 40-skill-command-script.sh, end to end. The hook runs from a copy under the
  # fixture root, so its script-relative lib lookup is the one under test.
  local SR="$TMP/skillroot-$MODE" b SKILL_BASH=""
  mkdir -p "$SR/core/scripts/lib" "$SR/core/hooks/UserPromptSubmit" "$SR/core/skills/loc" "$SR/core/skills/slow" \
    "$SR/.codex/hooks" "$SR/workspace/sessions" "$SR/personal/skills" "$SR/companies" "$SR/.claude/skills"
  cp "$ROOT/core/scripts/hook-lib.sh" "$SR/core/scripts/hook-lib.sh"
  cp "$ROOT/core/scripts/lib/session-scope-capability.sh" "$SR/core/scripts/lib/"
  [ "$MODE" = lib ] && [ -f "$LIB_SRC" ] && cp "$LIB_SRC" "$SR/core/scripts/lib/"
  cp "$ROOT/core/hooks/UserPromptSubmit/40-skill-command-script.sh" "$SR/core/hooks/UserPromptSubmit/"
  printf '%s\n' 'process.stdout.write("true")' >"$SR/.codex/hooks/codex-explicit-path-flag.cjs"
  printf '%s\n' 'if [ "${LC_ALL+set}" = set ]; then echo "LC_ALL=[$LC_ALL]"; else echo "LC_ALL=unset"; fi' >"$SR/core/skills/loc/command.sh"
  printf '%s\n' 'exec sleep 30' >"$SR/core/skills/slow/command.sh"
  chmod +x "$SR/core/skills/loc/command.sh" "$SR/core/skills/slow/command.sh"
  jq -nc '{hook_event_name:"UserPromptSubmit",session_id:"s-loc",prompt:"/loc"}' >"$TMP/skill-loc.payload"
  jq -nc '{hook_event_name:"UserPromptSubmit",session_id:"s-loc",prompt:"/slow"}' >"$TMP/skill-slow.payload"
  # The hook trips `set -u` on an empty array under bash 3.2 (macOS /bin/bash),
  # independent of this fix, so run it with a bash >= 4 when one is installed.
  for b in "$BASH_BIN" /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$b" ] || continue
    if "$b" -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]' 2>/dev/null; then SKILL_BASH="$b"; break; fi
  done
  if [ -n "$SKILL_BASH" ]; then
    add_wrapper "40-skill-command-script.sh perl bound" \
      "HQ_ROOT='$SR' HQ_SKILL_COMMAND_TIMEOUT=@SECS@ '$SKILL_BASH' '$SR/core/hooks/UserPromptSubmit/40-skill-command-script.sh' <'@CMD@' | jq -r '.systemMessage // \"no-systemMessage\"' | grep -o 'LC_ALL=[^ ]*' | head -1" \
      "$TMP/skill-loc.payload" "$TMP/skill-slow.payload"
  else
    echo "skip 40-skill-command-script.sh: needs bash >= 4 (the hook fails under bash 3.2 before this change too)"
  fi
}

exercise lib
exercise nolib

# -- Static checks -----------------------------------------------------------
# run-project.sh builds its timeout wrapper as an array run through env, so a
# shell function cannot be used; it must go through hq_perl_spawn_argv.
if grep -q 'hq_perl_spawn_argv' .claude/scripts/run-project.sh \
  && ! grep -n 'LC_ALL=C perl' .claude/scripts/run-project.sh >/dev/null; then
  pass "run-project.sh timeout wrapper uses hq_perl_spawn_argv"
else
  fail "run-project.sh timeout wrapper still pins LC_ALL=C for the child"
fi

# run-project.sh falls back to a plain env/perl array when the lib is missing.
if grep -q 'hq_perl_spawn_argv() { HQ_PERL_SPAWN_ARGV=(env LC_ALL=C' .claude/scripts/run-project.sh; then
  pass "run-project.sh defines a fallback hq_perl_spawn_argv when the lib is missing"
else
  fail "run-project.sh has no fallback for a missing lib"
fi

# bench-hooks.sh runs the hook under a perl alarm inside a loop.
if grep -q 'hq_perl_spawn' core/scripts/bench-hooks.sh \
  && ! grep -n -E 'LC_ALL=C perl -e .alarm' core/scripts/bench-hooks.sh >/dev/null; then
  pass "bench-hooks.sh per-hook timeout uses hq_perl_spawn"
else
  fail "bench-hooks.sh per-hook timeout still pins LC_ALL=C for the child"
fi

# Every file that calls hq_perl_spawn must source the lib with a fallback
# definition, never skip or return when the source fails.
bad=""
for f in $(git grep -l -E 'hq_perl_spawn( |$)' -- '*.sh' ':(exclude,glob)**/tests/**' ':(exclude,glob)**/*.test.sh' ':(exclude)core/scripts/lib/perl-child-locale.sh'); do
  grep -q -E '\|\| +hq_perl_spawn\(\) \{' "$f" || bad="$bad $f"
done
if [ -z "$bad" ]; then
  pass "every hq_perl_spawn caller defines a fallback when the lib is missing"
else
  fail "hq_perl_spawn callers without a missing-lib fallback:$bad"
fi

# No array-command `env LC_ALL=C perl` (an extra exec that also leaks the locale).
leaks="$(git grep -n -E 'env LC_ALL=C perl' -- '*.sh' ':(exclude,glob)**/tests/**' ':(exclude,glob)**/*.test.sh' 2>/dev/null || true)"
if [ -z "$leaks" ]; then
  pass "no 'env LC_ALL=C perl' array command remains"
else
  fail "'env LC_ALL=C perl' remains" "$(printf '%s' "$leaks" | head -3)"
fi

# hqd-hook-flag-cache-lib.sh ships alone and carries its own copy of the restore
# code. It must stay identical to the shared snippet.
if [ -f "$LIB_SRC" ]; then
  snippet="$(env -i bash -c ". '$LIB_SRC'; printf '%s' \"\${HQ_PERL_RESTORE_LOCALE% }\"")"
  if [ -n "$snippet" ] && grep -qF -- "$snippet" core/scripts/hqd-hook-flag-cache-lib.sh; then
    pass "hqd-hook-flag-cache-lib.sh restore code matches the shared snippet"
  else
    fail "hqd-hook-flag-cache-lib.sh restore code differs from perl-child-locale.sh"
  fi
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
