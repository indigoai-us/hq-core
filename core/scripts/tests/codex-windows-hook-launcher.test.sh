#!/usr/bin/env bash
# codex-windows-hook-launcher.test.sh - regression test for feedback_d0c2f082.
#
# On Windows, Codex runs a hook's `command` through `cmd.exe /C` (codex-rs
# hooks/src/engine/command_runner.rs). HQ's hook commands are POSIX shell that
# end in `exec /bin/bash`, so every HQ hook failed on Windows and no safety
# rails ran. Codex reads a per-hook `commandWindows` override on Windows. This
# test pins that every shipped command hook carries one, that it routes to the
# cmd launcher, and that the launcher resolves Git Bash instead of /bin/bash or
# the WSL bash in System32. It also pins the fail-closed contract: a missing
# launcher or a missing bash denies PreToolUse with exit 2 and never exits 0
# silently for other events. The Windows-only runtime half of this contract is
# codex-windows-hook-launcher-runtime.test.mjs (windows-latest CI job).
#
# Explicitly wired into .github/workflows/pr-checks.yml (tests are not
# auto-discovered).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CFG="$ROOT/.codex/config.toml"
LAUNCHER="$ROOT/.codex/hooks/hq-codex-hook.cmd"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   [$1]"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL [$1]: $2"; }

# tomllib is in the standard library from Python 3.11.
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
  echo "FAIL [python]: this test needs python3 3.11 or newer for tomllib; found $(python3 --version 2>&1 || echo 'no python3')"
  exit 1
fi

echo "== 1. Every command hook has a Windows command that uses the launcher =="
REPORT="$(python3 - "$CFG" <<'PY'
import re, sys, tomllib
with open(sys.argv[1], "rb") as fh:
    cfg = tomllib.load(fh)
total = 0
for event, groups in (cfg.get("hooks") or {}).items():
    for gi, group in enumerate(groups):
        for hi, hook in enumerate(group.get("hooks", [])):
            if hook.get("type") != "command":
                continue
            total += 1
            where = f"{event}[{gi}].hooks[{hi}]"
            win = hook.get("commandWindows")
            if not win:
                print(f"MISSING {where}")
                continue
            if "/bin/bash" in win:
                print(f"BINBASH {where}")
            if "hq-codex-hook.cmd" not in win:
                print(f"NOLAUNCHER {where}")
            # Same search order as the POSIX command: HQ_ROOT, git top level,
            # then the current folder (`cd` output). The for /f command uses
            # usebackq backticks because a TOML literal string cannot hold "'".
            if '"%HQ_ROOT%"' not in win or "git rev-parse --show-toplevel" not in win or "^& cd`)" not in win:
                print(f"NOSEARCH {where}")
            # Codex parses hook stdout. cmd.exe echoes each command while echo
            # is on, and an unset %HQ_ROOT% stays literal on the command line.
            # The inline command and its for /f child must start with @echo off,
            # and the do-body must be @-prefixed so neither a prompt nor a
            # literal %VAR% reaches stdout. The `if defined` must be in its own
            # parenthesized command: a false `if` on a cmd line swallows the
            # rest of that `&` chain, so git and `cd` never ran when HQ_ROOT
            # was unset and the launcher was reported missing.
            if not win.startswith("@echo off"):
                print(f"ECHO {where}")
            if "(`@echo off ^& ^(if defined HQ_ROOT echo \"%HQ_ROOT%\"^)" not in win:
                print(f"CHILDECHO {where}")
            if "do @if not defined HQ_HOOK_RAN" not in win:
                print(f"DOECHO {where}")
            # A bare %CD% outside quotes breaks on a folder name with ")".
            if "%CD%" in win:
                print(f"BARECD {where}")
            # The event name reaches the launcher as an argument; the launcher
            # must not read stdin, which belongs to bash byte for byte.
            if f'hq-codex-hook.cmd" {event} ' not in win:
                print(f"NOEVENTARG {where}")
            # Exit codes come back through explicit codes, not a bare exit /b.
            if re.search(r"exit /b(?! [0-9])", win):
                print(f"BAREEXIT {where}")
            if "(exit /b 2)" not in win:
                print(f"NODENYCODE {where}")
            want = "2" if event == "PreToolUse" else "1"
            if not win.endswith(f"1>&2 & exit /b {want})"):
                print(f"NOTFAILCLOSED {where} want-missing-launcher-exit={want}")
print(f"TOTAL {total}")
PY
)"
TOTAL="$(printf '%s\n' "$REPORT" | sed -n 's/^TOTAL //p')"
BAD="$(printf '%s\n' "$REPORT" | grep -v '^TOTAL ' || true)"
if [ "${TOTAL:-0}" -gt 0 ] && [ -z "$BAD" ]; then
  ok "all $TOTAL command hooks define commandWindows via hq-codex-hook.cmd"
else
  fail "commandWindows coverage" "total=${TOTAL:-0} $(printf '%s' "$BAD" | tr '\n' ' ')"
fi

echo "== 2. Launcher exists and resolves Git Bash =="
if [ -f "$LAUNCHER" ]; then
  ok "launcher present"
  # Check executable lines only; `rem` comments may name what the launcher avoids.
  CODE="$(grep -viE '^[[:space:]]*(@?rem( |$)|::)' "$LAUNCHER")"
  if printf '%s\n' "$CODE" | grep -q '/bin/bash'; then
    fail "launcher /bin/bash" "launcher must not hardcode /bin/bash"
  else
    ok "launcher has no /bin/bash"
  fi
  for needle in 'Git\bin\bash.exe' 'where git.exe' 'HQ_BASH_EXE' 'hq-codex-hook-adapter.sh'; do
    if grep -qF "$needle" "$LAUNCHER"; then ok "launcher references $needle"; else fail "launcher $needle" "missing"; fi
  done
  # `where bash` can return C:\Windows\System32\bash.exe (WSL), which cannot
  # run a Windows-path HQ hook. Resolve via git.exe or known Git dirs instead.
  if printf '%s\n' "$CODE" | grep -qiE 'where(\.exe)? +bash'; then
    fail "launcher WSL bash" "launcher must not resolve bash via 'where bash'"
  else
    ok "launcher does not resolve bash via 'where bash'"
  fi
  # Fail closed: no silent exit 0. PreToolUse denies with 2 and the other
  # events exit 1, keyed on the event name passed as the first argument.
  if printf '%s\n' "$CODE" | grep -qiE 'exit /b 0'; then
    fail "launcher fail closed" "launcher must not exit 0 when it cannot run the adapter"
  else
    ok "launcher has no exit 0"
  fi
  for needle in '%~1' 'PreToolUse' 'set "HQ_HOOK_FAIL_RC=2"' 'exit /b %HQ_HOOK_FAIL_RC%' 'if not exist "%HQ_HOOK_ADAPTER%"'; do
    if printf '%s\n' "$CODE" | grep -qF "$needle"; then ok "launcher fail closed: $needle"; else fail "launcher fail closed" "missing $needle"; fi
  done
  # The launcher must not read stdin; bash gets it byte for byte.
  if printf '%s\n' "$CODE" | grep -qiE 'set +/p|(^|[^a-z])more([^a-z]|$)|findstr'; then
    fail "launcher stdin" "launcher must leave stdin for bash"
  else
    ok "launcher leaves stdin for bash"
  fi
  # HQ_BASH_EXE under %SystemRoot% (the WSL bash) is ignored with a warning.
  if printf '%s\n' "$CODE" | grep -qF '%%HQ_BASH_REL:%SystemRoot%\=%%'; then
    ok "launcher rejects HQ_BASH_EXE under SystemRoot"
  else
    fail "launcher SystemRoot" "HQ_BASH_EXE under %SystemRoot% is not rejected"
  fi
  if grep -qE '^[[:space:]]*:[A-Za-z]|goto ' "$LAUNCHER"; then
    fail "launcher labels" "LF-only .cmd must not use labels or goto"
  else
    ok "launcher uses no labels or goto"
  fi
else
  fail "launcher present" "$LAUNCHER missing"
fi

echo "== 3. POSIX commands still resolve the adapter with bash =="
if python3 - "$CFG" <<'PY'
import sys, tomllib
cfg = tomllib.load(open(sys.argv[1], "rb"))
bad = [e for e, gs in cfg["hooks"].items() for g in gs for h in g["hooks"]
       if h.get("type") == "command" and "hq-codex-hook-adapter.sh" not in h["command"]]
sys.exit(1 if bad else 0)
PY
then ok "POSIX command unchanged"; else fail "POSIX command" "adapter missing from command"; fi

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
