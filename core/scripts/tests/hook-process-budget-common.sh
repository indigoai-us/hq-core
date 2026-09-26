#!/usr/bin/env bash
# Shared process-count fixture for the c138c Bash guard budgets.

c138c_init_process_budget() {
  C138C_ROOT="${ROOT:-$(git rev-parse --show-toplevel)}"
  C138C_BASE_SHA="d3c1726c831181f43cf90731b916db4d36b5172b"
  C138C_STRACE="$(type -P strace || true)"
  [ -n "$C138C_STRACE" ] || { echo 'FAIL: strace is required for c138c process budgets' >&2; return 1; }
  timeout 20s git -C "$C138C_ROOT" cat-file -e "$C138C_BASE_SHA^{commit}" \
    || { echo "FAIL: pinned c138c baseline is unavailable: $C138C_BASE_SHA" >&2; return 1; }

  C138C_TMP_PARENT="$C138C_ROOT/workspace"
  mkdir -p "$C138C_TMP_PARENT"
  C138C_TMP="$(mktemp -d "$C138C_TMP_PARENT/c138c-hook-budget.XXXXXX")"
  trap 'rm -rf "$C138C_TMP"' EXIT

  mkdir -p "$C138C_TMP/source/base/.claude/hooks" \
    "$C138C_TMP/source/candidate/.claude/hooks" \
    "$C138C_TMP/fixture/.claude/hooks" "$C138C_TMP/fixture/core/scripts" \
    "$C138C_TMP/cwd/plain/a/b/c/d/e/f" "$C138C_TMP/cwd/age/a/b/c/d/e/f"

  for relative in \
    .claude/hooks/block-unsafe-package-install.sh \
    .claude/hooks/block-core-writes-bash.sh; do
    mkdir -p "$C138C_TMP/source/base/${relative%/*}" \
      "$C138C_TMP/source/candidate/${relative%/*}"
    timeout 20s git -C "$C138C_ROOT" show "$C138C_BASE_SHA:$relative" \
      > "$C138C_TMP/source/base/$relative" \
      || { echo "FAIL: pinned baseline is missing $relative" >&2; return 1; }
    cp "$C138C_ROOT/$relative" "$C138C_TMP/source/candidate/$relative"
  done
  timeout 20s git -C "$C138C_ROOT" show "$C138C_BASE_SHA:core/scripts/hook-lib.sh" \
    > "$C138C_TMP/fixture/core/scripts/hook-lib.sh" \
    || { echo 'FAIL: pinned baseline is missing core/scripts/hook-lib.sh' >&2; return 1; }
  cp "$C138C_ROOT/core/scripts/install-deps.allow" \
    "$C138C_TMP/fixture/core/scripts/install-deps.allow"
  mkdir -p "$C138C_TMP/fixture/core"

  # The age gate is exactly six parent directories above the measured CWD.
  printf 'minimum-release-age=1440\n' > "$C138C_TMP/cwd/age/a/.npmrc"
}

c138c_measure_hook() {
  local variant="$1" hook_kind="$2" label="$3" command="$4" cwd_kind="$5"
  local timeout_seconds="${6:-30}"
  local relative hook_path source_root cwd payload trace out err rc counts
  case "$hook_kind" in
    unsafe) relative=.claude/hooks/block-unsafe-package-install.sh ;;
    core) relative=.claude/hooks/block-core-writes-bash.sh ;;
    *) echo "FAIL: unknown c138c hook kind: $hook_kind" >&2; return 1 ;;
  esac
  source_root="$C138C_TMP/source/$variant"
  hook_path="$C138C_TMP/fixture/$relative"
  cp "$source_root/$relative" "$hook_path"
  if [ "$cwd_kind" = fixture ]; then
    cwd="$C138C_TMP/fixture"
    mkdir -p "$C138C_TMP/fixture/core"
    : > "$C138C_TMP/fixture/core/adversarial-target.txt"
  else
    cwd="$C138C_TMP/cwd/$cwd_kind/a/b/c/d/e/f"
  fi
  payload="$(jq -cn --arg cmd "$command" '{tool_name:"Bash",tool_input:{command:$cmd}}')"
  trace="$C138C_TMP/$hook_kind-$label-$variant.strace"
  out="$C138C_TMP/$hook_kind-$label-$variant.out"
  err="$C138C_TMP/$hook_kind-$label-$variant.err"

  if ( cd "$cwd" && printf '%s' "$payload" | timeout "${timeout_seconds}s" "$C138C_STRACE" \
      -f -c -e trace=clone,clone3,fork,vfork,execve -o "$trace" \
      env -u BASH_ENV -u ENV \
        HQ_ROOT="$C138C_TMP/fixture" CLAUDE_PROJECT_DIR="$C138C_TMP/fixture" \
        TMPDIR="$C138C_TMP" bash "$hook_path" > "$out" 2> "$err" ); then
    rc=0
  else
    rc=$?
  fi
  [ -f "$trace" ] || { echo "FAIL: strace produced no summary for $hook_kind/$label/$variant" >&2; return 1; }
  counts="$(awk '
    $NF ~ /^(clone|clone3|fork|vfork)$/ {
      errors = (NF >= 6 ? $5 : 0)
      forks += $4 - errors
    }
    $NF == "execve" { execves += $4 }
    END { print forks + 0, execves + 0 }
  ' "$trace")" || { echo "FAIL: could not parse strace summary for $hook_kind/$label/$variant" >&2; return 1; }
  read -r C138C_HOOK_FORKS C138C_HOOK_EXECVES <<< "$counts"
  C138C_HOOK_EXIT="$rc"
  C138C_HOOK_OUT="$out"
  C138C_HOOK_ERR="$err"
}

c138c_measure_pair() {
  local hook_kind="$1" label="$2" command="$3" expected_exit="$4" cwd_kind="$5"
  local timeout_seconds="${6:-30}"
  local base_forks base_execves base_exit base_out base_err
  local candidate_forks candidate_execves candidate_exit candidate_out candidate_err

  c138c_measure_hook base "$hook_kind" "$label" "$command" "$cwd_kind" "$timeout_seconds"
  base_forks="$C138C_HOOK_FORKS"; base_execves="$C138C_HOOK_EXECVES"
  base_exit="$C138C_HOOK_EXIT"; base_out="$C138C_HOOK_OUT"; base_err="$C138C_HOOK_ERR"
  c138c_measure_hook candidate "$hook_kind" "$label" "$command" "$cwd_kind" "$timeout_seconds"
  candidate_forks="$C138C_HOOK_FORKS"; candidate_execves="$C138C_HOOK_EXECVES"
  candidate_exit="$C138C_HOOK_EXIT"; candidate_out="$C138C_HOOK_OUT"; candidate_err="$C138C_HOOK_ERR"

  if [ "$expected_exit" = parity ]; then
    [ "$base_exit" -eq "$candidate_exit" ] \
      || { echo "FAIL: exit differs for $hook_kind/$label: base $base_exit, candidate $candidate_exit" >&2; return 1; }
  else
    [ "$base_exit" -eq "$expected_exit" ] \
      || { echo "FAIL: pinned source $hook_kind/$label exited $base_exit, expected $expected_exit" >&2; return 1; }
    [ "$candidate_exit" -eq "$expected_exit" ] \
      || { echo "FAIL: candidate $hook_kind/$label exited $candidate_exit, expected $expected_exit" >&2; return 1; }
  fi
  cmp -s "$base_out" "$candidate_out" \
    || { echo "FAIL: stdout differs for $hook_kind/$label" >&2; return 1; }
  cmp -s "$base_err" "$candidate_err" \
    || { echo "FAIL: stderr differs for $hook_kind/$label" >&2; return 1; }

  # shellcheck disable=SC2034 # Sourcing budget tests consume these globals.
  C138C_PAIR_BASE_FORKS="$base_forks"
  # shellcheck disable=SC2034 # Sourcing budget tests consume these globals.
  C138C_PAIR_CANDIDATE_FORKS="$candidate_forks"
  printf '%s/%s: forks %s -> %s; execve %s -> %s; exit=%s\n' \
    "$hook_kind" "$label" "$base_forks" "$candidate_forks" \
    "$base_execves" "$candidate_execves" "$candidate_exit"
}
