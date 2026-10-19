# Sourced by the seeded mandatory-scope-authorizer regression suite.
# Round-two adversarial cases must run before the foreign symlink is installed.
mkdir -p "$TMP/workspace/a" "$TMP/workspace/b" "$TMP/workspace/claimed"
touch "$TMP/workspace/a/one" "$TMP/workspace/b/two" "$TMP/workspace/claimed/latest"
scope_112_case round2 0 'for f in workspace/a; do head "$f/$(ls $f | head -1)"; done'
for reader in bash sh python3 xargs tee; do
  scope_112_case round2 2 "cat <<'EOF' | $reader
cat companies/otherco/settings/x
EOF"
done
scope_112_case round2 2 "cat <<-'EOF' | sh
cat companies/otherco/settings/x
EOF"
scope_112_case round2 2 "cat <<'A' <<'B' | sh
safe
A
cat companies/otherco/settings/x
B"
scope_112_case round2 2 'eval "$(cat companies/otherco/settings/x)"'
scope_112_case round2 2 'bash <(cat companies/otherco/settings/x)'
scope_112_case round2 2 'hq lanes link report -m "Read workspace/$UNKNOWN/path"'
scope_112_case round2 2 'hq files put -m "Read workspace/$UNKNOWN/path"'
scope_112_case round2 2 "cat <<'EOF'
cat companies/otherco/settings/x
EOF
| sh"
for suffix in '> companies/otherco/x' '| tee companies/otherco/x' '; cat companies/otherco/x' '&& cat companies/otherco/x'; do
  scope_112_case round2 2 "hq lanes link report --text harmless $suffix"
done
for option in --out --body-file --text-file; do
  scope_112_case round2 2 "hq lanes link report $option companies/otherco/x"
done
for suffix in '> companies/otherco/x' '-o companies/otherco/x' '| tee companies/otherco/x' '--input companies/otherco/x' '-F body=@companies/otherco/x'; do
  scope_112_case round2 2 "gh api repos/owner/repo $suffix"
done
scope_112_case round2 2 'gh api companies/otherco/settings/x'
scope_112_case round2 2 'X=companies/otherco; gh api repos/$X'
for binding in 'f=companies/otherco' 'read f' 'export f=companies/otherco' 'declare f=companies/otherco' 'printf -v f companies/otherco' 'f+=/../../companies/otherco'; do
  scope_112_case round2 2 "for f in workspace/a; do $binding; head \"\$f/\$(ls \$f | head -1)\"; done"
done
scope_112_case round2 2 'cd companies/otherco/settings && tail "$(ls -t | head -1)"'
scope_112_case round2 2 'for f in workspace/a companies/otherco/settings; do head "$f/$(ls $f | head -1)"; done'
scope_112_case round2 0 "cat > workspace/notes.md <<'EOF'
The words git update-index and eval \"\$(cat companies/otherco/settings/x)\" are prose.
EOF"
mkdir -p "$TMP/workspace/a" "$TMP/workspace/b" "$TMP/workspace/claimed"
touch "$TMP/workspace/a/one" "$TMP/workspace/b/two" "$TMP/workspace/claimed/latest"
scope_112_case b7568d4e 0 'hq lanes link report --text "These options include \$(...) that resolve inside workspace/ paths"'
scope_112_case b7568d4e 0 'hq lanes link report --text "HQ Sync treats companies/{co}/signals/ as server-owned"'
scope_112_case b7568d4e 0 "cat > workspace/report.json <<'EOF'
{\"Path: companies/_template/example next_steps\": \"text\"}
EOF"
scope_112_case b7568d4e 0 "cat <<'EOF'
Path: companies/{co}/signals/
EOF"
scope_112_case f286c9e5 0 'for f in workspace/a workspace/b; do head "$f/$(ls $f | head -1)"; done'
scope_112_case f286c9e5 0 'cd workspace/claimed && tail -c 600 "$(ls -t | head -1)"'
scope_112_case f286c9e5 0 'for f in a b; do gh api "repos/owner/repo/contents/$f?ref=main"; done'
scope_112_case b7568d4e 2 "cat > companies/otherco/report.json <<'EOF'
{}
EOF"
scope_112_case f286c9e5 2 'head "workspace/$(touch companies/otherco/x)"'
scope_112_case f286c9e5 2 'cat > "$UNKNOWN/output"'
scope_112_case f286c9e5 2 'for f in a b; do gh api "repos/owner/repo/contents/$f?ref=main" > companies/otherco/x; done'
scope_112_case b7568d4e 2 'hq lanes link report --text "Read $(cat companies/otherco/settings/x)"'
scope_112_case b7568d4e 2 'hq lanes link report --text "Write $(touch companies/otherco/settings/x)"'
scope_112_case f286c9e5 2 'for f in workspace/a; do head "$f/$(cat workspace/name)"; done'
scope_112_case f286c9e5 2 'for f in workspace/a; do f=companies/otherco; head "$f/$(ls $f | head -1)"; done'
# feedback_92211ef8: a repos/private symlink is that checkout only when the
# owner listed its real directory. The list is $HOME/.hq/repo-symlink-roots,
# not the company manifest. Targets live outside $TMP so the resolved path
# really leaves the HQ tree. The fixture writes the list directly; the hook
# refuses a session that tries to.
scope_reg_outside="$(mktemp -d "${TMP%/*}/scope-reg-repo.XXXXXX")"
scope_unreg_outside="$(mktemp -d "${TMP%/*}/scope-unreg-repo.XXXXXX")"
scope_chain_real="$(mktemp -d "${TMP%/*}/scope-chain-real.XXXXXX")"
scope_chain_mid="$(mktemp -d "${TMP%/*}/scope-chain-mid.XXXXXX")"
scope_escape_outside="$(mktemp -d "${TMP%/*}/scope-escape.XXXXXX")"
scope_sensitive_home="$(mktemp -d "${TMP%/*}/scope-sensitive-home.XXXXXX")"
scope_swap_alias="$(mktemp -d "${TMP%/*}/scope-swap-alias.XXXXXX")"
scope_reg_outside="$(cd "$scope_reg_outside" && pwd -P)"
scope_unreg_outside="$(cd "$scope_unreg_outside" && pwd -P)"
scope_chain_real="$(cd "$scope_chain_real" && pwd -P)"
scope_chain_mid="$(cd "$scope_chain_mid" && pwd -P)"
scope_escape_outside="$(cd "$scope_escape_outside" && pwd -P)"
scope_sensitive_home="$(cd "$scope_sensitive_home" && pwd -P)"
scope_swap_alias="$(cd "$scope_swap_alias" && pwd -P)"
mkdir -p "$TMP/repos/private" "$scope_reg_outside/sub" "$scope_sensitive_home/.ssh" \
  "$TMP/companies/otherco/settings" "${HOME}/.hq"
echo reg > "$scope_reg_outside/file.txt"
echo unreg > "$scope_unreg_outside/file.txt"
echo chain > "$scope_chain_real/file.txt"
echo nope > "$scope_escape_outside/secret.txt"
echo key > "$scope_sensitive_home/.ssh/id_rsa"
# Names that do not contain a company path. The same-command probes point at
# these so the block is the link swap, not the company-path text scan.
ln -s "$TMP/companies/otherco" "$scope_swap_alias/co"
ln -s "$scope_sensitive_home/.ssh" "$scope_swap_alias/keys"
# Earlier cases mkdir repos/private/app as a real directory. ln into that
# directory would nest the link instead of replacing the path.
rm -rf "$TMP/repos/private/app"
ln -s "$scope_reg_outside" "$TMP/repos/private/app"
ln -s "$scope_chain_real" "$scope_chain_mid/target"
ln -s "$scope_chain_mid/target" "$TMP/repos/private/chained"
ln -s "$scope_unreg_outside" "$scope_chain_mid/unreg-target"
ln -s "$scope_chain_mid/unreg-target" "$TMP/repos/private/stray"
ln -s "$TMP/companies/otherco" "$TMP/repos/private/badco"
ln -s "$scope_escape_outside/secret.txt" "$scope_reg_outside/escape"
ln -s "$scope_sensitive_home/.ssh" "$TMP/repos/private/keys"
printf '%s\n' "# owner-listed checkout roots" "$scope_reg_outside" "$scope_chain_real" \
  > "${HOME}/.hq/repo-symlink-roots"
scope_112_case 92211ef8 0 'cat repos/private/app/file.txt'
scope_112_case 92211ef8 0 'echo hi > repos/private/app/out.txt'
scope_112_case 92211ef8 0 'mkdir -p repos/private/app/sub'
scope_112_case 92211ef8 0 'rm -f repos/private/app/file.txt'
scope_112_case 92211ef8 0 'cat repos/private/app/sub/../file.txt'
scope_112_case 92211ef8 0 'git -C repos/private/app status'
scope_112_case 92211ef8 0 'cat repos/private/chained/file.txt'
scope_112_case 92211ef8 2 'cat repos/private/badco/settings/x'
scope_112_case 92211ef8 2 'echo hi > repos/private/stray/file.txt'
scope_112_case 92211ef8 2 'cat repos/private/stray/file.txt'
scope_112_case 92211ef8 2 'cat repos/private/app/escape'
scope_112_case 92211ef8 2 'cat repos/private/app/../file.txt'
scope_112_case 92211ef8 2 'cat repos/private/app/.config/gh/hosts.yml'
scope_112_case 92211ef8 2 'cat repos/private/app/.kube/config'
scope_112_case 92211ef8 2 'ls repos/private/app/.aws/sso/cache'
scope_112_case 92211ef8 2 'echo evil >> repos/private/app/.zlogin'
scope_112_case 92211ef8 2 'echo evil >> repos/private/app/.profile'
scope_112_case 92211ef8 2 'cat repos/private/app/.env'
scope_saved_home="${HOME:-}"
export HOME="$scope_sensitive_home"
scope_112_case 92211ef8 2 'cat repos/private/keys/id_rsa'
if [ -n "$scope_saved_home" ]; then export HOME="$scope_saved_home"; else unset HOME; fi
# Same-command swap. A lone ln that only names the link stays allowed; the
# next call rechecks the new target. The combined command is refused.
scope_112_case 92211ef8 2 "ln -sfn $scope_swap_alias/co repos/private/app; cat repos/private/app/settings/x"
scope_112_case 92211ef8 2 "ln -sfn $scope_swap_alias/keys repos/private/app; cat repos/private/app/id_rsa"
scope_112_case 92211ef8 0 "ln -sfn $scope_reg_outside repos/private/badco"
scope_112_case 92211ef8 2 'rm repos/private/app; cat repos/private/app/file.txt'
ln -s "$scope_swap_alias/co" "$TMP/repos/private/next"
scope_112_case 92211ef8 2 'cat repos/private/next/settings/x'
# Self-registration. Call 1 may append the manifest and create the link.
# Call 2 is still refused: the manifest is not the registry, and a root that
# is $HOME is rejected even if the owner file lists it.
scope_112_case 92211ef8 0 "ln -sfn \"\$HOME\" repos/private/evil; printf '%s\n' '    - repos/private/evil' >> companies/manifest.yaml"
ln -sfn "$HOME" "$TMP/repos/private/evil"
printf '%s\n' '    - repos/private/evil' >> "$TMP/companies/manifest.yaml"
printf '%s\n' "$HOME" >> "${HOME}/.hq/repo-symlink-roots"
scope_112_case 92211ef8 2 'cat repos/private/evil/.config/gh/hosts.yml'
scope_112_case 92211ef8 2 'cat repos/private/evil/.kube/config'
scope_112_case 92211ef8 2 'ls repos/private/evil/.aws/sso/cache'
scope_112_case 92211ef8 2 'echo evil >> repos/private/evil/.zlogin'
scope_112_case 92211ef8 2 'echo evil >> repos/private/evil/.profile'
# cd then .. is the sibling of the real checkout, not a path under repos/.
scope_cd_parent="$(cd "$scope_reg_outside/.." && pwd -P)"
mkdir -p "$scope_cd_parent/scope-cd-badco/settings"
echo x > "$scope_cd_parent/scope-cd-badco/settings/x"
scope_112_case 92211ef8 2 'cd repos/private/app && cat ../scope-cd-badco/settings/x'
scope_112_case 92211ef8 0 'cd repos/private/app && cat sub/../file.txt'
# A listed root that is the HQ root, or /, is not a checkout.
ln -s "$TMP" "$TMP/repos/private/hqroot"
ln -s / "$TMP/repos/private/rootlink"
printf '%s\n' "$TMP" / >> "${HOME}/.hq/repo-symlink-roots"
scope_112_case 92211ef8 2 'cat repos/private/hqroot/core/docs/readme.md'
scope_112_case 92211ef8 2 'echo hi > repos/private/hqroot/.claude/hooks/mandatory-scope-authorizer.sh'
scope_112_case 92211ef8 2 'cat repos/private/rootlink/etc/passwd'
scope_112_case 92211ef8 2 'printf "%s\n" /tmp/x >> "$HOME/.hq/repo-symlink-roots"'
scope_112_case 92211ef8 2 "cat ${HOME}/.hq/repo-symlink-roots"
payload="$(jq -cn --arg cwd "$TMP" --arg path "${HOME}/.hq/repo-symlink-roots" \
  '{tool_name:"Write",session_id:"sess-bound",cwd:$cwd,tool_input:{file_path:$path,content:"x"}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "feedback_92211ef8: Write cannot modify the owner root list"
payload="$(jq -cn --arg cwd "$TMP" --arg path "${HOME}/.hq/repo-symlink-roots" \
  '{tool_name:"Edit",session_id:"sess-bound",cwd:$cwd,tool_input:{file_path:$path,old_string:"a",new_string:"b"}}')"
rc="$(run_hook "$payload")"
expect_exit 2 "$rc" "feedback_92211ef8: Edit cannot modify the owner root list"
# shellcheck source=scope-hook-round3.cases.sh
. "$ROOT/core/scripts/tests/scope-hook-round3.cases.sh"
rm -rf "$scope_reg_outside" "$scope_unreg_outside" "$scope_chain_real" \
  "$scope_chain_mid" "$scope_escape_outside" "$scope_sensitive_home" \
  "$scope_swap_alias" "$scope_cd_parent/scope-cd-badco"
ln -s "$TMP/companies/otherco/settings/x" "$TMP/workspace/a/foreign"
scope_112_case f286c9e5 2 'for f in workspace/a; do head "$f/$(ls $f | head -1)"; done'
