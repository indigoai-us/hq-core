# hq-core: public
# Round-3 probes for repo-symlink scope. Sourced after the owner-root fixture
# exists (scope_reg_outside, scope_cd_parent, HOME, TMP, scope_112_case).
# The hook does not run these commands; a directory swap is done by the test
# between hook invocations and then restored.

# Gap 1. A link change is judged from the directory the command is in, not
# from a literal repos/ token or a short tool list. A lone ln stays allowed.
scope_112_case round3 2 'cd repos/private && ln -sfn /x app && cat app/f'
scope_112_case round3 2 'pushd repos/private >/dev/null && ln -sfn /x app && cat app/f'
scope_112_case round3 2 'cd repos/private/app && ln -sfn /x ../app && cat file.txt'
scope_112_case round3 2 'ln -sfn /x repos/private/app; cat repos/private/app/f'
scope_112_case round3 2 'ln -sfn /x repos/private/app || cat repos/private/app/f'
scope_112_case round3 2 'ln -sfn /x repos/private/app | cat repos/private/app/f'
scope_112_case round3 2 $'ln -sfn /x repos/private/app\ncat repos/private/app/f'
scope_112_case round3 2 '( cd repos/private && ln -sfn /x app && cat app/f )'
scope_112_case round3 2 'command ln -sfn /x repos/private/app; cat repos/private/app/f'
scope_112_case round3 2 'command -p ln -sfn /x repos/private/app; cat repos/private/app/f'
scope_112_case round3 2 '/bin/ln -sfn /x repos/private/app; cat repos/private/app/f'
scope_112_case round3 2 'env ln -sfn /x repos/private/app; cat repos/private/app/f'
scope_112_case round3 2 'L=ln; $L -sfn /x repos/private/app; cat repos/private/app/f'
scope_112_case round3 2 'xargs ln -sfn /x repos/private/app; cat repos/private/app/f'
scope_112_case round3 2 "bash -c 'ln -sfn /x repos/private/app; cat repos/private/app/f'"
scope_112_case round3 2 "sh -c 'ln -sfn /x repos/private/app; cat repos/private/app/f'"
scope_112_case round3 2 "python3 -c 'import os; os.symlink(\"/x\", \"repos/private/app\")'; cat repos/private/app/f"
scope_112_case round3 2 "python3 -c 'import os; os.rename(\"/x\", \"repos/private/app\")'; cat repos/private/app/f"
scope_112_case round3 2 "node -e 'require(\"fs\").symlinkSync(\"/x\", \"repos/private/app\")'; cat repos/private/app/f"
scope_112_case round3 2 'cd repos/private && install /x app && cat app/f'
scope_112_case round3 2 'cd repos/private && rsync -l /x/ app && cat app/f'
scope_112_case round3 2 'cd repos/private && rsync -a /x/ app && cat app/f'
scope_112_case round3 2 'ln -sfn /x $dest; cat repos/private/app/f'
scope_112_case round3 2 "python3 -c 'import os; os.symlink(\"/x\", dst)'; cat repos/private/app/f"
scope_112_case round3 0 "ln -sfn $scope_reg_outside repos/private/app"
scope_112_case round3 0 'rm -f repos/private/app/file.txt'
scope_112_case round3 0 'cat repos/private/app/file.txt'
scope_112_case round3 0 'printf hi > workspace/notes.md'

# Gap 2. The owner-list guard resolves paths. A literal file name is already
# refused; these probes do not depend on that spelling.
mkdir -p "${HOME}/.hq/nested"
ln -sfn "${HOME}/.hq/repo-symlink-roots" "$TMP/workspace/roots-alias"
scope_112_case round3 2 'printf x >> ~/.hq/repo-symlink-r*'
scope_112_case round3 2 'printf x >> $HOME/.hq/repo-symlink-r*'
scope_112_case round3 2 'printf x >> ${HOME}/.hq/repo-symlink-r*'
scope_112_case round3 2 'cd ~/.hq && printf x >> repo-symlink-roots'
scope_112_case round3 2 'cd ~/.hq/nested && printf x >> ../repo-symlink-r*'
scope_112_case round3 2 'rm -rf ~/.hq'
scope_112_case round3 2 'mv ~/.hq /tmp/scope-moved-hq'
scope_112_case round3 2 'ln -sfn /tmp/scope-hq-alias ~/.hq'
scope_112_case round3 2 'printf x >> workspace/roots-alias'
payload="$(jq -cn --arg cwd "$TMP" --arg path "$TMP/workspace/roots-alias" \
  '{tool_name:"Write",session_id:"sess-bound",cwd:$cwd,tool_input:{file_path:$path,content:"x"}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "feedback_round3: Write through a symlink alias of the owner root list"
payload="$(jq -cn --arg cwd "$TMP" \
  '{tool_name:"Write",session_id:"sess-bound",cwd:$cwd,tool_input:{file_path:"workspace/roots-alias",content:"x"}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "feedback_round3: Write of a relative symlink alias of the owner root list"
scope_112_case round3 0 'printf hi > workspace/notes.md'

# Gap 5. cd into the linked checkout, then .., is the real target's parent.
echo outside > "$scope_cd_parent/scope-cd-outside.txt"
scope_112_case round3 2 'cd repos/private/app && cat ../scope-cd-outside.txt'
scope_112_case round3 2 'cd repos/private/app && cd .. && cat scope-cd-badco/settings/x'
scope_112_case round3 2 'cd repos/private/app && cd ../.. && cat scope-cd-badco/settings/x'
scope_112_case round3 0 'cd repos/private/app && cat sub/../file.txt'
scope_112_case round3 0 'cd repos/private/app/sub && cd .. && cat file.txt'

# Gap 4. macOS folds the repos prefix and the sensitive-name list. Linux does not.
if [ "$(uname -s)" = "Darwin" ]; then
  scope_112_case round3 0 'cat Repos/private/app/file.txt'
  scope_112_case round3 0 'cat REPOS/private/app/file.txt'
  scope_112_case round3 2 'cat repos/private/app/.ENV'
  scope_112_case round3 2 'cat repos/private/app/.SSH/id_rsa'
  scope_112_case round3 2 'cat Repos/private/stray/file.txt'
else
  scope_112_case round3 0 'cat repos/private/app/.ENV'
fi
scope_112_case round3 0 'cat repos/private/app/foo.aws'
scope_112_case round3 0 'cat repos/private/app/.environment'

# Gap 3. A listed root that is later replaced by a symlink is not trusted.
# Call 1 used the real directory. Call 2 is this hook invocation.
scope_listed="$scope_reg_outside"
scope_aside="${scope_listed}.aside-round3"
scope_other="$(mktemp -d "${TMP%/*}/scope-round3-other.XXXXXX")"
scope_other="$(cd "$scope_other" && pwd -P)"
echo swapped > "$scope_other/file.txt"
mv "$scope_listed" "$scope_aside"
ln -s "$scope_other" "$scope_listed"
scope_112_case round3 2 'cat repos/private/app/file.txt'
rm -f "$scope_listed"
mv "$scope_aside" "$scope_listed"
mv "$scope_listed" "$scope_aside"
ln -s "$HOME" "$scope_listed"
scope_112_case round3 2 'cat repos/private/app/file.txt'
rm -f "$scope_listed"
mv "$scope_aside" "$scope_listed"
rm -rf "$scope_other"
