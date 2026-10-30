#!/usr/bin/env bash
# hq-core: public
# Regression: raw `HOME=$(mktemp -d)` test runs left ~45 GB of temp homes
# behind each with its own Rust toolchain and pnpm store.
#
# Covers:
#   1. block-raw-temp-home.sh blocks the raw temp HOME forms, allows the
#      wrapper and unrelated mktemp use, honours the escape hatch. Without
#      perl, the bash fallback blocks the one-step and two-step forms (also
#      across a continuation) and skips heredoc bodies and comment lines.
#   2. The hook fails open and silent on bad input.
#   3. All three hook-gate profiles run it.
#   4. master-hook dispatches it for a trigger and skips it (prefilter) for a
#      command without `mktemp`, so ordinary Bash calls pay no added latency.
#      Through master-hook it blocks the forms the PR 1420 review found
#      (env -i, cd && mktemp inside the substitution, read from mktemp output,
#      cd into a temp dir then $PWD, mktemp piped into xargs) and passes the
#      controls (a literal HOME, HOME=$HOME, the wrapper, CARGO_HOME).
#   5. core/scripts/with-temp-home.sh creates, runs, always removes, and
#      passes the exit code through.
set -uo pipefail
export HQ_HOOK_DEDUPE=0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
HOOK="$ROOT/.claude/hooks/block-raw-temp-home.sh"
GATE="$ROOT/.claude/hooks/hook-gate.sh"
MASTER="$ROOT/.claude/hooks/master-hook.sh"
REGISTRY="$ROOT/.claude/hooks/hook-registry.json"
WRAP="$ROOT/core/scripts/with-temp-home.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable" >&2; exit 0; }

SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/block-raw-temp-home.XXXXXX")" && pwd -P)"
trap 'rm -rf -- "$SANDBOX"' EXIT

# Built from parts so this file's own text never reads as the raw form.
H='HOME'
SUB='$(mktemp'
BT='`mktemp'

payload() { jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }

expect() { # <want-rc> <desc> <payload> [env...]
  local want="$1" desc="$2" body="$3" rc=0
  shift 3
  printf '%s' "$body" | env -u HQ_ALLOW_RAW_TEMP_HOME "$@" bash "$HOOK" >"$SANDBOX/out" 2>"$SANDBOX/err" || rc=$?
  if [ "$rc" -eq "$want" ]; then ok "$desc"; else bad "$desc (want $want got $rc; err=$(tr '\n' ' ' <"$SANDBOX/err"))"; fi
}

echo "[1] hook decisions"
expect 2 "blocks ${H}=${SUB} -d) inline" "$(payload "${H}=${SUB} -d) pnpm exec vitest run")"
expect 2 "blocks export ${H}=\"${SUB} ...)\"" "$(payload "export ${H}=\"${SUB} -d /tmp/x.XXXX)\"; bash t.sh")"
expect 2 "blocks backtick form" "$(payload "${H}=${BT} -d\` cargo test")"
expect 2 "blocks after && in a chain" "$(payload "cd repo && ${H}=${SUB} -d) cargo test")"
grep -q 'core/scripts/with-temp-home.sh' "$SANDBOX/err" && ok "block message names the wrapper" \
  || bad "block message names the wrapper"
expect 0 "allows the wrapper" "$(payload "bash core/scripts/with-temp-home.sh -- pnpm exec vitest run")"
expect 0 "allows plain mktemp" "$(payload 'T=$(mktemp -d); ls $T')"
expect 0 "ignores other variable names" "$(payload "MY${H}=${SUB} -d)")"
expect 0 "inline escape hatch" "$(payload "HQ_ALLOW_RAW_TEMP_HOME=1 ${H}=${SUB} -d) cargo test")"
expect 0 "env escape hatch" "$(payload "${H}=${SUB} -d) cargo test")" HQ_ALLOW_RAW_TEMP_HOME=1

echo "[1b] two-step form"
expect 2 "blocks T=${SUB} -d); ${H}=\$T" "$(payload "T=${SUB} -d); ${H}=\$T cargo test")"
expect 2 "blocks ${H}=\"\$T\" across a newline" "$(payload "T=\"${SUB} -d)\"
${H}=\"\$T\" pnpm test")"
expect 2 "blocks export ${H}=\${T}/sub" "$(payload "export T=${SUB} -d) && export ${H}=\${T}/sub && cargo test")"
expect 2 "blocks a copy of a tainted variable" "$(payload "A=${SUB} -d); B=\$A; ${H}=\$B cargo test")"
expect 0 "allows ${H}=\$T when T is not from mktemp" "$(payload "T=/tmp/fixed; X=${SUB} -d); ${H}=\$T ls")"
expect 2 "blocks inside bash -c" "$(payload "bash -c '${H}=${SUB} -d) cargo test'")"
expect 2 "blocks inside a command substitution" "$(payload "out=\$(${H}=${SUB} -d) cargo test)")"
expect 2 "blocks after if/then" "$(payload "if true; then ${H}=${SUB} -d) cargo test; fi")"
expect 2 "blocks an assignment before mktemp" "$(payload "${H}=\$(TMPDIR=/x mktemp -d) cargo test")"
expect 2 "blocks quoted assignments before mktemp" "$(payload "${H}=\"\$(TMPDIR='/a b' LC_ALL=C mktemp -d)\" cargo test")"
expect 2 "blocks env before mktemp" "$(payload "${H}=\$(env TMPDIR=/x mktemp -d) cargo test")"
expect 2 "blocks an assignment before mktemp in the two-step form" "$(payload "T=\$(TMPDIR=/x mktemp -d); ${H}=\$T cargo test")"
expect 0 "allows an assignment before mktemp for another variable" "$(payload "D=\$(TMPDIR=/x mktemp -d); ls \$D")"

echo "[1c] text that only quotes the pattern"
expect 0 "allows a commit message" "$(payload "git commit -m \"fix: avoid ${H}=${SUB} -d)\"")"
expect 0 "allows a grep pattern" "$(payload "grep -n '${H}=${SUB}' file.sh")"
expect 0 "allows an echo argument" "$(payload "echo \"${H}=${SUB} -d)\"")"
expect 0 "allows a heredoc body" "$(payload "cat <<'EOF' >notes.md
${H}=${SUB} -d) cargo test
EOF")"
expect 0 "allows a comment" "$(payload "ls ${SUB} -d) # ${H}=${SUB} -d)")"

echo "[1d] escape hatch only as a real prefix"
expect 2 "hatch in an echo argument does not count" "$(payload "echo HQ_ALLOW_RAW_TEMP_HOME=1 && ${H}=${SUB} -d) x")"
expect 2 "hatch in a comment does not count" "$(payload "${H}=${SUB} -d) x # HQ_ALLOW_RAW_TEMP_HOME=1")"
expect 2 "hatch on another command does not count" "$(payload "HQ_ALLOW_RAW_TEMP_HOME=1 true; ${H}=${SUB} -d) x")"
expect 0 "hatch exported earlier counts" "$(payload "export HQ_ALLOW_RAW_TEMP_HOME=1; ${H}=${SUB} -d) x")"
expect 0 "hatch after the HOME prefix counts" "$(payload "${H}=${SUB} -d) HQ_ALLOW_RAW_TEMP_HOME=1 cargo test")"

echo "[1e] backslash line continuations"
# Bash removes backslash-newline before it splits words, so the next line's
# assignment is still a prefix assignment of the same command.
expect 2 "blocks ${H} on a continued line between prefix assignments" "$(payload "RUST_LOG=debug \\
${H}=${SUB} -d) \\
cargo test")"
expect 2 "blocks an indented continued ${H} prefix" "$(payload "CI=1 \\
  ${H}=${SUB} -d) pnpm test")"
expect 2 "blocks env then a continued ${H}" "$(payload "env \\
  ${H}=${SUB} -d) cargo test")"
expect 2 "blocks export then a continued ${H}" "$(payload "export \\
 ${H}=${SUB} -d)")"
expect 2 "blocks the two-step form across a continuation" "$(payload "T=${SUB} -d) \\
  && ${H}=\$T cargo test")"
expect 0 "allows a continued echo argument" "$(payload "echo \\
  \"${H}=${SUB} -d)\"")"
expect 0 "allows a continued command with no ${H}" "$(payload "D=${SUB} -d) \\
  ls \$D")"

echo "[1f] wrappers with option values"
expect 2 "blocks timeout <duration> env ${H}" "$(payload "timeout 600 env ${H}=${SUB} -d) cargo test")"
expect 2 "blocks timeout -s KILL <duration> env ${H}" "$(payload "timeout -s KILL 10m env ${H}=${SUB} -d) cargo test")"
expect 2 "blocks env -u NAME ${H}" "$(payload "env -u XDG_CONFIG_HOME ${H}=${SUB} -d) cargo test")"
expect 2 "blocks env -C dir ${H}" "$(payload "env -C /x ${H}=${SUB} -d) cargo test")"
expect 2 "blocks sudo -u user ${H}" "$(payload "sudo -u bob ${H}=${SUB} -d) cargo test")"
expect 2 "blocks nice env ${H}" "$(payload "nice env ${H}=${SUB} -d) cargo test")"
expect 2 "blocks nice -n 5 env ${H}" "$(payload "nice -n 5 env ${H}=${SUB} -d) cargo test")"
expect 0 "allows timeout with an echo argument" "$(payload "timeout 600 echo \"${H}=${SUB} -d)\"")"
expect 0 "allows env -u ${H} with plain mktemp" "$(payload "env -u ${H} ls ${SUB} -d)")"

echo "[1g] without perl the plain pattern still blocks"
NOPERL="$SANDBOX/noperl-bin"
mkdir -p "$NOPERL"
for tool in bash cat grep dirname jq env; do
  src="$(command -v "$tool")" && ln -sf "$src" "$NOPERL/$tool"
done
rc=0
payload "${H}=${SUB} -d) cargo test" | PATH="$NOPERL" "$NOPERL/bash" "$HOOK" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && ok "fallback blocks the one-step form" || bad "fallback blocks the one-step form (got $rc)"
rc=0
payload "${H}=\$(TMPDIR=/x mktemp -d) cargo test" | PATH="$NOPERL" "$NOPERL/bash" "$HOOK" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && ok "fallback blocks an assignment before mktemp" || bad "fallback blocks an assignment before mktemp (got $rc)"
# noperl <want-rc> <desc> <command>. Runs under the PATH bash and /bin/bash,
# which is 3.2 on macOS.
noperl() {
  local b rc
  for b in "$NOPERL/bash" /bin/bash; do
    [ -x "$b" ] || continue
    rc=0
    payload "$3" | env -u HQ_ALLOW_RAW_TEMP_HOME PATH="$NOPERL" "$b" "$HOOK" >/dev/null 2>&1 || rc=$?
    [ "$rc" = "$1" ] && ok "fallback ($b): $2" || bad "fallback ($b): $2 (want $1 got $rc)"
  done
}
noperl 2 "env -i before mktemp" "${H}=\$(env -i mktemp -d) cargo test"
noperl 2 "backtick after export" "export ${H}=${BT} -d\`"
noperl 2 "two-step form" "T=${SUB} -d); ${H}=\$T cargo test"
noperl 2 "two-step form across a continuation" "T=${SUB} -d) \\"$'\n'"  && ${H}=\"\$T\" cargo test"
noperl 2 "continuation inside the substitution" "${H}=${SUB} \\"$'\n'" -d) cargo test"
noperl 2 "two-step form on the next line, braced" "T=${SUB} -d)"$'\n'"${H}=\${T}/sub cmd"
noperl 2 "env with a quoted assignment" "env \"${H}=${SUB} -d)\" cargo test"
noperl 2 "append assignment" "${H}+=${SUB} -d) cargo test"
noperl 2 "quoted << is not a heredoc" "echo \"<<EOF\""$'\n'"${H}=${SUB} -d) cmd"
noperl 2 "<< after a comment is not a heredoc" "echo x # <<EOF"$'\n'"${H}=${SUB} -d) cmd"
noperl 0 "CARGO_${H} from mktemp" "CARGO_${H}=${SUB} -d) cargo build"
noperl 0 "a literal ${H}" "D=${SUB} -d); ${H}=/tmp/literal ls \$D"
noperl 0 "${H}=\$${H}" "T=${SUB} -d); ${H}=\$${H} ls \$T"
noperl 0 "a longer name that starts with the temp name" "T=${SUB} -d); ${H}=\$TX ls"
noperl 0 "heredoc body" "cat <<'EOF' > notes.md"$'\n'"${H}=${SUB} -d) cargo test"$'\n'"EOF"$'\n'"mktemp -d"
noperl 0 "tab-stripped heredoc body" "cat <<-EOF"$'\n\t'"${H}=${SUB} -d)"$'\n\t'"EOF"$'\n'"mktemp -d"
noperl 0 "comment line" "# ${H}=${SUB} -d)"$'\n'"mktemp -d"
noperl 0 "grep pattern in single quotes" "grep -n '${H}=${SUB}' file"
noperl 0 "here-string is not a heredoc" "cat <<<\"x\"; mktemp -d"

echo "[2] fails open and silent on bad input"
for bodyname in empty garbage no-command array; do
  case "$bodyname" in
    empty) body='' ;;
    garbage) body='{not json' ;;
    no-command) body='{"tool_name":"Bash","tool_input":{}}' ;;
    array) body='[1,2,3]' ;;
  esac
  rc=0
  printf '%s' "$body" | bash "$HOOK" >"$SANDBOX/out" 2>"$SANDBOX/err" || rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$SANDBOX/out" ] && [ ! -s "$SANDBOX/err" ]; then
    ok "bad input '$bodyname' passes silently"
  else
    bad "bad input '$bodyname' (rc=$rc out=$(cat "$SANDBOX/out") err=$(cat "$SANDBOX/err"))"
  fi
done

echo "[3] every hook-gate profile runs the guard"
for p in minimal standard strict; do
  rc=0
  payload "${H}=${SUB} -d) cargo test" \
    | env -u HQ_ALLOW_RAW_TEMP_HOME HQ_HOOK_PROFILE="$p" CLAUDE_PROJECT_DIR="$ROOT" \
      bash "$GATE" block-raw-temp-home "$HOOK" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] && ok "profile $p blocks" || bad "profile $p want 2 got $rc"
done

echo "[4] master-hook dispatch and prefilter"
re="$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.id == "block-raw-temp-home") | .prefilter.re' "$REGISTRY")"
[ "$re" = "mktemp" ] && ok "registry prefilter is mktemp" || bad "registry prefilter is '$re'"
master_payload() { jq -nc --arg c "$1" --arg root "$ROOT" '{session_id:"raw-temp-home-test",hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$root,tool_input:{command:$c}}'; }
run_master() {
  ERR="$(printf '%s' "$1" | env -u HQ_ALLOW_RAW_TEMP_HOME CLAUDE_PROJECT_DIR="$ROOT" HQ_ALLOW_HQ_WORKTREE=1 \
    HQ_HOOK_TIMEOUT_SENTRY=0 HQ_HOOK_TRACE=1 bash "$MASTER" PreToolUse 2>&1 >/dev/null)"; RC=$?
}
run_master "$(master_payload "${H}=${SUB} -d) cargo test")"
[ "$RC" = 2 ] && grep -q 'raw temp HOME' <<<"$ERR" && ok "master-hook blocks a raw temp HOME" \
  || bad "master-hook did not block (rc=$RC)"
# master_case <want-rc> <desc> <command>: run one command through master-hook.
# A block must carry this hook's message. A pass must exit 0 and, when the
# command contains mktemp, show the hook ran (no prefilter skip).
master_case() {
  run_master "$(master_payload "$3")"
  if [ "$1" = 2 ]; then
    [ "$RC" = 2 ] && grep -q 'raw temp HOME' <<<"$ERR" && ok "master-hook blocks: $2" \
      || bad "master-hook blocks: $2 (rc=$RC err=$(tr '\n' ' ' <<<"$ERR" | cut -c1-300))"
  else
    [ "$RC" = 0 ] && ! grep -q 'raw temp HOME' <<<"$ERR" \
      && { ! grep -q mktemp <<<"$3" || ! grep -q 'skip block-raw-temp-home' <<<"$ERR"; } \
      && ok "master-hook allows: $2" \
      || bad "master-hook allows: $2 (rc=$RC err=$(tr '\n' ' ' <<<"$ERR" | cut -c1-300))"
  fi
}
# The four forms from the PR 1420 review, and variants of each.
master_case 2 "env -i before mktemp" "${H}=\$(env -i mktemp -d) cargo test"
master_case 2 "env -i before mktemp, quoted" "${H}=\"\$(env -i mktemp -d)\" cargo test"
master_case 2 "cd /tmp && mktemp inside the substitution" "${H}=\$(cd /tmp && mktemp -d) cargo test"
master_case 2 "read from a process substitution" "read T < <(mktemp -d); ${H}=\$T cargo test"
master_case 2 "read from a here-string" "read -r T <<< \"\$(mktemp -d)\"; ${H}=\$T cargo test"
master_case 2 "read from an attached here-string" "read T <<<\$(mktemp -d); ${H}=\"\$T\" cargo test"
master_case 2 "while read from a mktemp pipe" "mktemp -d | while read T; do ${H}=\$T cargo test; done"
master_case 2 "cd into a temp dir, then \$PWD" "cd \$(mktemp -d) && ${H}=\$PWD cargo test"
master_case 2 "cd into a temp dir, then \$(pwd)" "cd \"\$(mktemp -d)\" && ${H}=\$(pwd) cargo test"
master_case 2 "cd, then export on the next line" "cd \$(mktemp -d)"$'\n'"export ${H}=\$PWD"
master_case 2 "xargs -I{} into sh -c" "mktemp -d | xargs -I{} sh -c '${H}={} cmd'"
master_case 2 "xargs -I with a separate placeholder" "mktemp -d | xargs -I % sh -c '${H}=% cmd'"
master_case 2 "xargs into sh -c with \$0" "mktemp -d | xargs sh -c '${H}=\$0 cmd'"
master_case 2 "xargs into bash -c with \"\$1\"" "mktemp -d | xargs -n1 bash -c '${H}=\"\$1\" cmd' _"
master_case 2 "gmktemp into xargs env" "gmktemp -d | xargs -I{} env ${H}={} cmd"
master_case 2 "env with a quoted assignment" "env \"${H}=\$(mktemp -d)\" cargo test"
master_case 2 "echo of a temp variable" "T=\$(mktemp -d); X=\$(echo \$T); ${H}=\$X cmd"
master_case 2 "while loop fed by a process substitution" "while read T; do ${H}=\$T cmd; done < <(mktemp -d)"
master_case 2 "mktemp piped through tee into xargs" "mktemp -d | tee /dev/null | xargs -I{} sh -c '${H}={} cmd'"
master_case 2 "realpath of a temp variable" "T=${SUB} -d); ${H}=\$(realpath \$T) cmd"
master_case 2 "set -- from mktemp, then \$1" "set -- ${SUB} -d); ${H}=\$1 cmd"
master_case 2 "printf -v ${H}" "T=${SUB} -d); printf -v ${H} %s \"\$T\""
master_case 2 "for loop over mktemp" "for T in \$(mktemp -d); do ${H}=\$T cmd; done"
master_case 2 "mapfile -t from mktemp" "mapfile -t A < <(mktemp -d); ${H}=\${A[0]} cmd"
master_case 2 "read -t with a timeout" "read -t 5 T < <(mktemp -d); ${H}=\$T cmd"
master_case 2 "append assignment" "${H}=; ${H}+=\$(mktemp -d); cmd"
master_case 2 "one-step form" "${H}=${SUB} -d) cargo test"
master_case 2 "two-step form" "T=${SUB} -d); ${H}=\$T cargo test"
# Controls that must pass.
master_case 0 "a literal ${H}" "D=${SUB} -d); ${H}=/tmp/literal ls \$D"
master_case 0 "${H}=\$${H}" "T=${SUB} -d); ${H}=\$${H} ls \$T"
master_case 0 "the wrapper" "bash core/scripts/with-temp-home.sh -- bash -c 'mktemp -d'"
master_case 0 "CARGO_${H} from mktemp" "CARGO_${H}=${SUB} -d) cargo build"
master_case 0 "cd into a temp dir without ${H}" "cd ${SUB} -d) && ls"
master_case 0 "cd back out before \$PWD" "cd ${SUB} -d); cd /repo; ${H}=\$PWD cmd"
master_case 0 "read a temp path, no ${H}" "read T < <(mktemp -d); echo \$T"
master_case 0 "xargs without ${H}" "mktemp -d | xargs -I{} ls {}"
# On main the credential-read guard blocks `read T < <(...)` followed by a
# variable operand, so the whole master-hook chain exits 2 here. Assert this
# hook's own decision directly; the chain result belongs to that guard.
expect 0 "read from non-temp input" "$(payload "read T < <(echo hi); ${H}=\$T cmd")"
master_case 0 "xargs fed by echo" "echo hi | xargs -I{} sh -c '${H}={} cmd'"
master_case 0 "here-string of plain text" "cat <<<\"x\"; mktemp -d"
master_case 0 "set -e options, then \$1" "set -euo pipefail; T=${SUB} -d); ${H}=\$1 cmd"
master_case 0 "for loop over plain words" "for T in a b; do ${H}=\$T cmd; done; mktemp -d"
master_case 0 "printf -v of another name" "printf -v X %s ${SUB} -d)"
run_master "$(master_payload "echo bench")"
grep -q 'skip block-raw-temp-home (prefilter)' <<<"$ERR" && ok "benign command skips the guard (no spawn)" \
  || bad "benign command did not skip the guard"

echo "[5] with-temp-home.sh"
export TMPDIR="$SANDBOX"
seen="$(bash "$WRAP" -- bash -c 'printf %s "$HOME"')"
case "$seen" in "$SANDBOX"/hq-temp-home.*) ok "HOME is a fresh temp home" ;; *) bad "HOME is a fresh temp home ($seen)" ;; esac
[ -n "$seen" ] && [ ! -e "$seen" ] && ok "removed after success" || bad "removed after success"

made="$(bash "$WRAP" -- bash -c '[ -d "$HOME" ] && [ "$HQ_TEMP_HOME" = "$HOME" ] && echo yes')"
[ "$made" = yes ] && ok "temp home exists during the run and HQ_TEMP_HOME matches" || bad "temp home exists during run ($made)"

out="$(bash "$WRAP" -- bash -c 'printf %s "$HOME"; exit 7')"; rc=$?
[ "$rc" = 7 ] && ok "exit code passed through" || bad "exit code passed through (got $rc)"
[ -n "$out" ] && [ ! -e "$out" ] && ok "removed after failure" || bad "removed after failure"

p="$(bash "$WRAP" -- bash -c 'mkdir -p "$HOME/.rustup/toolchains" && echo x >"$HOME/big" && printf %s "$HOME"')"
[ ! -e "$p" ] && ok "contents removed" || bad "contents removed"

real="$HOME"
vals="$(env -u RUSTUP_HOME -u CARGO_HOME -u npm_config_cache bash "$WRAP" -- bash -c 'printf "%s|%s|%s" "$RUSTUP_HOME" "$CARGO_HOME" "$npm_config_cache"')"
[ "$vals" = "$real/.rustup|$real/.cargo|$real/.npm" ] && ok "toolchain caches stay in the real home" || bad "caches ($vals)"
v="$(RUSTUP_HOME=/x/rustup bash "$WRAP" -- bash -c 'printf %s "$RUSTUP_HOME"')"
[ "$v" = /x/rustup ] && ok "caller cache override kept" || bad "caller cache override kept ($v)"

k="$(bash "$WRAP" --keep -- bash -c 'printf %s "$HOME"' 2>/dev/null)"
[ -d "$k" ] && ok "--keep keeps the folder" || bad "--keep keeps the folder"
rm -rf -- "$k"

rc=0; bash "$WRAP" >/dev/null 2>&1 || rc=$?
[ "$rc" = 64 ] && ok "no command is a usage error" || bad "no command rc=$rc"

# Killed by a signal: still removed.
bash "$WRAP" -- bash -c 'printf %s "$HOME" >"'"$SANDBOX"'/sig-home"; kill -TERM $PPID; sleep 5' >/dev/null 2>&1
sh="$(cat "$SANDBOX/sig-home" 2>/dev/null)"
[ -n "$sh" ] && [ ! -e "$sh" ] && ok "removed after SIGTERM" || bad "removed after SIGTERM ($sh)"

# Signals sent to the wrapper reach the command at once.
# wait_for_home: poll until the wrapper's temp home and lock file exist.
wait_for_home() {
  local i=0 d
  while [ "$i" -lt 100 ]; do
    for d in "$SANDBOX"/hq-temp-home.*; do
      [ -f "$d/.hq-temp-home.lock" ] && { printf '%s' "$d"; return 0; }
    done
    sleep 0.05; i=$((i + 1))
  done
  return 1
}
# signal_case <signal> <want-rc> <desc> <command...>: start the wrapper with
# default signal handling, signal it, and check exit code, time and cleanup.
# With SIGNAL_CASE_READY set, it also waits for that file before signalling,
# so a command that records a pid has done so first.
signal_case() {
  local sig="$1" want="$2" desc="$3" home pid rc start end
  shift 3
  perl -e '$SIG{INT}="DEFAULT"; $SIG{TERM}="DEFAULT"; $SIG{HUP}="DEFAULT"; exec @ARGV' \
    bash "$WRAP" -- "$@" </dev/null >/dev/null 2>&1 &
  pid=$!
  home="$(wait_for_home)" || { bad "$desc (temp home never appeared)"; kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return; }
  lockpid="$(cat "$home/.hq-temp-home.lock" 2>/dev/null)"
  [ "$lockpid" = "$pid" ] && ok "$desc: lock file names the wrapper pid" || bad "$desc: lock pid '$lockpid' != $pid"
  if [ -n "${SIGNAL_CASE_READY:-}" ]; then
    local r=0
    while [ ! -s "$SIGNAL_CASE_READY" ] && [ "$r" -lt 100 ]; do sleep 0.05; r=$((r + 1)); done
  fi
  start=$(date +%s)
  kill -s "$sig" "$pid"
  rc=0; wait "$pid" || rc=$?
  end=$(date +%s)
  [ "$rc" = "$want" ] && ok "$desc: exit $want" || bad "$desc: exit $rc, want $want"
  [ $((end - start)) -le 3 ] && ok "$desc: stops within 3 s" || bad "$desc: took $((end - start)) s"
  [ ! -e "$home" ] && ok "$desc: temp home removed" || bad "$desc: temp home left at $home"
}
signal_case TERM 143 "SIGTERM forwarded" sleep 30
signal_case INT 130 "SIGINT forwarded" sleep 30
signal_case HUP 129 "SIGHUP forwarded" sleep 30
export HQ_TEMP_HOME_GRACE=1
signal_case TERM 143 "child ignoring TERM is killed after the grace" \
  bash -c 'trap "" TERM INT; while :; do sleep 0.2; done'
unset HQ_TEMP_HOME_GRACE

# A grandchild must not outlive the wrapper and recreate the temp home.
# The command backgrounds a subshell that writes into $HOME after 2 s, records
# its pid, then waits in the foreground; the wrapper is sent TERM at once.
rm -f "$SANDBOX/gc-pid"
SIGNAL_CASE_READY="$SANDBOX/gc-pid" signal_case TERM 143 "SIGTERM reaches grandchildren" \
  bash -c '(sleep 2; mkdir -p "$HOME/.cache") & printf %s $! >"'"$SANDBOX"'/gc-pid"; sleep 30'
gc="$(cat "$SANDBOX/gc-pid" 2>/dev/null)"
sleep 3
if [ -n "$gc" ] && ! kill -0 "$gc" 2>/dev/null; then ok "grandchild stopped with the wrapper"; else
  bad "grandchild '$gc' still running"; kill -KILL "$gc" 2>/dev/null; fi
left="$(find "$SANDBOX" -maxdepth 1 -name 'hq-temp-home.*' | wc -l | tr -d ' ')"
[ "$left" = 0 ] && ok "grandchild did not recreate the temp home" || bad "grandchild recreated $left temp home(s)"

# The same when the command exits 0 on its own and leaves a background job.
rm -f "$SANDBOX/gc-pid"
rc=0
HQ_TEMP_HOME_GRACE=1 bash "$WRAP" -- \
  bash -c '(sleep 2; mkdir -p "$HOME/.cache") & printf %s $! >"'"$SANDBOX"'/gc-pid"; exit 0' \
  </dev/null >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] && ok "normal exit with a background job: exit 0" || bad "normal exit with a background job: exit $rc"
gc="$(cat "$SANDBOX/gc-pid" 2>/dev/null)"
sleep 3
if [ -n "$gc" ] && ! kill -0 "$gc" 2>/dev/null; then ok "background job stopped after a normal exit"; else
  bad "background job '$gc' still running after a normal exit"; kill -KILL "$gc" 2>/dev/null; fi
left="$(find "$SANDBOX" -maxdepth 1 -name 'hq-temp-home.*' | wc -l | tr -d ' ')"
[ "$left" = 0 ] && ok "background job did not recreate the temp home" || bad "background job recreated $left temp home(s)"
find "$SANDBOX" -maxdepth 1 -name 'hq-temp-home.*' -exec rm -rf {} +

got="$(printf 'piped\n' | bash "$WRAP" -- cat)"
[ "$got" = piped ] && ok "stdin reaches the command" || bad "stdin reaches the command ($got)"

# The command rewriting HOME must not redirect the cleanup.
bash "$WRAP" -- bash -c 'export HOME=/; export HQ_TEMP_HOME=/' >/dev/null 2>&1
[ -d "$real" ] && ok "cleanup ignores a rewritten HOME" || bad "cleanup ignores a rewritten HOME"
left="$(find "$SANDBOX" -maxdepth 1 -name 'hq-temp-home.*' | wc -l | tr -d ' ')"
[ "$left" = 0 ] && ok "no temp homes left behind" || bad "$left temp homes left behind"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
