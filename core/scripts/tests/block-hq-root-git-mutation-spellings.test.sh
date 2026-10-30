#!/usr/bin/env bash
# hq-core: public
# block-hq-root-git-mutation-spellings.test.sh
#
# Adversarial spellings of an HQ-root git mutation. Each block case below was
# allowed by the guard on main (the strict flag is off here, as it is by
# default), and each allow case is a normal command the fix must keep allowing.
#
#   - GIT_DIR= / GIT_WORK_TREE= (prefix, env, export) and --git-dir /
#     --work-tree name the repository without -C or cd;
#   - eval, sh -c, bash -c, and zsh -c run a payload string;
#   - $VAR, ${VAR}, $(...), and backticks hide the command name;
#   - quote-split (g''it, "g"it, g\it) and path or .exe spellings of git;
#   - a relative -C resolved from the tool cwd.
#
# Runs under every Bash found: the PATH bash and /bin/bash (3.2 on macOS). Set
# GIT_GUARD_TEST_BASHES to override the list.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
HOOK="${HQ_ROOT_GIT_GUARD_HOOK_OVERRIDE:-$ROOT/.claude/hooks/block-hq-root-git-mutation.sh}"
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/git-guard-spellings.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

# Fake HQ root with a nested working repo, as in block-hq-root-git-mutation.test.sh.
HQ="$TMP/hq"
NESTED="$HQ/repos/private/app"
mkdir -p "$NESTED"
git -C "$HQ" init -q
git -C "$NESTED" init -q

BASHES=()
if [ -n "${GIT_GUARD_TEST_BASHES:-}" ]; then
  read -r -a BASHES <<<"$GIT_GUARD_TEST_BASHES"
else
  for candidate in "$(command -v bash)" /bin/bash; do
    [ -x "$candidate" ] || continue
    dup=0
    for seen in ${BASHES[@]+"${BASHES[@]}"}; do
      [ "$candidate" -ef "$seen" ] && dup=1
    done
    [ "$dup" -eq 1 ] || BASHES+=("$candidate")
  done
fi

PASS=0
FAIL=0
SH=""

# run <expected exit> <cwd> <command> <label>
# HQ_CLI_BIN points at a missing file, so the strict flag reads as off.
run() {
  local expect="$1" cwd="$2" cmd="$3" label="$4" payload rc=0
  # The command goes to jq on stdin, as a real hook payload does. Git Bash
  # rewrites an argument that starts with / (such as /usr/bin/git ...) into a
  # Windows path before a native program like jq sees it.
  payload=$(printf '%s' "$cmd" | jq -Rs --arg cwd "$cwd" '{cwd: $cwd, tool_input: {command: .}}')
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$HQ" HQ_ALLOW_HQ_ROOT_GIT= \
    HQ_CLI_BIN="$TMP/no-hq-cli" "$SH" "$HOOK" >/dev/null 2>"$TMP/err" || rc=$?
  if [[ "$rc" -eq "$expect" ]]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL [$label] ($SH): expected exit $expect, got $rc; cmd: $cmd (cwd: $cwd)" >&2
    sed 's/^/    /' "$TMP/err" | head -5 >&2
  fi
}

for SH in "${BASHES[@]}"; do
  echo "== $("$SH" -c 'echo "bash $BASH_VERSION"')"

  # --- GIT_DIR / --git-dir / --work-tree name the HQ repository -------------
  # The tool cwd is the nested repo, so the cwd fallback alone would allow.
  run 2 "$NESTED" "GIT_DIR=$HQ/.git git commit -m x"            'GIT_DIR prefix names the HQ git dir'
  run 2 "$NESTED" "env GIT_DIR=$HQ/.git git commit -m x"        'env GIT_DIR names the HQ git dir'
  run 2 "$NESTED" "export GIT_DIR=$HQ/.git; git commit -m x"    'exported GIT_DIR names the HQ git dir'
  run 2 "$NESTED" "export GIT_DIR=$HQ/.git
git commit -m x"                                               'exported GIT_DIR on its own line'
  run 2 "$NESTED" "git --git-dir=$HQ/.git commit -m x"          '--git-dir= names the HQ git dir'
  run 2 "$NESTED" "git --git-dir $HQ/.git commit -m x"          '--git-dir <path> names the HQ git dir'
  run 2 "$NESTED" "git -C $NESTED --git-dir=../../../.git commit -m x" \
    'relative --git-dir after -C reaches the HQ git dir'
  run 2 "$NESTED" "git --git-dir=$NESTED/.git --work-tree=$HQ clean -fdx" \
    '--work-tree at the HQ root is checked'
  run 2 "$NESTED" "GIT_WORK_TREE=$HQ git --git-dir=$NESTED/.git checkout -- ." \
    'GIT_WORK_TREE at the HQ root is checked'
  run 2 "$NESTED" "git --git-dir=\$HQGIT commit -m x"           'unresolvable --git-dir blocks'
  # A git dir with no work tree uses the shell cwd as the work tree, so the
  # cwd still decides: at the HQ root the commit would stage HQ files.
  run 2 "$HQ" "GIT_DIR=$NESTED/.git git commit -m x"            'GIT_DIR without a work tree uses the HQ cwd as work tree'
  run 0 "$NESTED" "GIT_DIR=$NESTED/.git git commit -m x"        'GIT_DIR naming the nested repo from its own cwd'
  run 0 "$HQ" "git --git-dir=$NESTED/.git --work-tree=$NESTED commit -m x" \
    '--git-dir and --work-tree naming a nested repo are allowed'
  run 0 "$HQ" "git --git-dir=$NESTED/.git status"               'read-only git with --git-dir is allowed'

  # --- eval, sh -c, bash -c, zsh -c run the payload --------------------------
  run 2 "$HQ" "eval 'git push origin main'"                     'eval payload at the HQ root'
  run 2 "$HQ" 'eval git commit -m x'                            'unquoted eval words at the HQ root'
  run 2 "$HQ" "sh -c 'git commit -m x'"                         'sh -c payload at the HQ root'
  run 2 "$HQ" "bash -c \"git commit -m x\""                     'bash -c payload at the HQ root'
  run 2 "$HQ" "bash -lc 'git push origin main'"                 'bash -lc payload at the HQ root'
  run 2 "$HQ" "/bin/sh -c 'git push origin main'"               '/bin/sh -c payload at the HQ root'
  run 2 "$HQ" "zsh -c 'git push origin main'"                   'zsh -c payload at the HQ root'
  run 2 "$NESTED" "bash -c 'cd $HQ && git commit -m x'"         'cd to the HQ root inside bash -c'
  run 2 "$HQ" "eval \"eval 'git push'\""                        'nested eval at the HQ root'
  run 0 "$HQ" "bash -c 'git -C $NESTED commit -m x'"            'bash -c with git -C nested repo is allowed'
  run 0 "$HQ" "eval \"git -C $NESTED push\""                    'eval with git -C nested repo is allowed'
  run 0 "$HQ" "bash -c 'cd $NESTED && git commit -m x'"         'cd to a nested repo inside bash -c is allowed'
  run 0 "$HQ" "sh -c 'echo git push'"                           'sh -c prose is allowed'
  run 0 "$HQ" "bash -c 'ls -la'"                                'bash -c without git is allowed'

  # --- $VAR, ${VAR}, $(...), and backticks hide the command name --------------
  run 2 "$HQ" 'G=git; $G commit -m x'                           '$G resolves to git'
  run 2 "$HQ" 'G=git; ${G} push origin main'                    '${G} resolves to git'
  run 2 "$HQ" 'X=gi; ${X}t commit -m x'                         '${X}t resolves to git'
  run 2 "$HQ" 'G=git
$G push'                                                       '$G assigned on an earlier line'
  run 2 "$HQ" 'S=bash; $S -c "git push"'                        '$S resolves to bash -c'
  run 2 "$HQ" '$GIT_BIN commit -m x'                            'unresolvable $GIT_BIN before commit'
  run 2 "$HQ" 'if true; then G=git; else G=ls; fi; $G push'     'two values for G is unresolvable'
  run 2 "$HQ" '$(echo git) commit -m x'                         '$(...) command name before commit'
  run 2 "$HQ" '$(command -v git) -C . push'                     '$(...) command name with -C before push'
  run 2 "$HQ" '`echo git` commit -m x'                          'backtick command name before commit'
  run 2 "$NESTED" "D=$HQ; git -C \"\$D\" commit -m x"           '-C "$D" resolves to the HQ root'
  run 2 "$NESTED" "D=$HQ; cd \"\$D\" && git commit -m x"        'cd "$D" resolves to the HQ root'
  run 2 "$NESTED" 'git -C "$SOME_DIR" commit -m x'              'unresolvable -C "$SOME_DIR" blocks'
  run 0 "$HQ" "G=git; \$G -C $NESTED commit -m x"               '$G with -C nested repo is allowed'
  run 0 "$HQ" "D=$NESTED; git -C \"\$D\" commit -m x"           '-C "$D" naming a nested repo is allowed'
  run 0 "$HQ" 'G=ls; $G commit'                                 '$G resolving to ls is not git'
  run 0 "$HQ" '$EDITOR notes.txt'                               'unresolvable command without a git subcommand'
  run 0 "$HQ" '$PYTHON -m pip install requests'                 'unresolvable interpreter is allowed'
  run 0 "$HQ" 'echo "$(date) commit"'                           'substitution in an argument is allowed'

  # --- quote-split, path, and .exe spellings of git ---------------------------
  run 2 "$HQ" "g''it commit -m x"                               "g''it at the HQ root"
  run 2 "$HQ" '"g"it push origin main'                          '"g"it at the HQ root'
  run 2 "$HQ" 'g\it commit -m x'                                'g\it at the HQ root'
  run 2 "$HQ" "'g'i't' commit -m x"                             "'g'i't' at the HQ root"
  run 2 "$HQ" '/usr/bin/git commit -m x'                        '/usr/bin/git at the HQ root'
  run 2 "$HQ" 'git.exe commit -m x'                             'git.exe at the HQ root'
  run 2 "$HQ" '"C:\Program Files\Git\cmd\git.exe" push'        'Windows git.exe path at the HQ root'
  run 0 "$HQ" "echo \"g''it commit\""                           'quote-split prose is allowed'
  run 0 "$HQ" '/usr/bin/git status'                             '/usr/bin/git status is allowed'
  run 0 "$HQ" "/usr/bin/git -C $NESTED commit -m x"             '/usr/bin/git -C nested repo is allowed'

  # --- relative -C is resolved from the tool cwd too -------------------------
  run 2 "$NESTED" 'git -C ../../.. commit -m x'                 'relative -C from the nested cwd reaches the HQ root'
  run 0 "$HQ" 'git -C repos/private/app commit -m x'            'relative -C from the HQ root to a nested repo'
done

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "ALL PASS: block-hq-root-git-mutation-spellings"
