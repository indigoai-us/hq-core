#!/bin/bash
# block-core-writes-bash.sh — PreToolUse hook for Bash.
#
# Companion to block-core-writes.sh. Scans Bash command text and rejects
# high-confidence direct writes into core/ or .claude/ (except
# .claude/settings.local.json).
#
# Bypass: HQ_BYPASS_CORE_PROTECT="1" under "env" in .claude/settings.local.json.
# This is a real escape hatch, but enabling it disables protection for EVERY
# later write — so it must NEVER be set autonomously by an agent. The block
# message below instructs the agent to ask the user for explicit approval first.
# Inline env-var prefixes are NOT accepted.
#
# This is best-effort — exhaustive shell-command analysis is intractable.
# Exit codes: 0 = allow, 2 = block.

set -uo pipefail

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || true
[[ -z "$CMD" ]] && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/scripts/hook-lib.sh"
PROJECT_DIR="$(hq_normpath "$PROJECT_DIR" 2>/dev/null || echo "$PROJECT_DIR")"

SETTINGS_LOCAL="$PROJECT_DIR/.claude/settings.local.json"

# Bypass: must be declared in .claude/settings.local.json env section.
# NOTE: agents must ask the user before enabling this (see block message).
is_bypass_authorized() {
  [[ -f "$SETTINGS_LOCAL" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local val
  val=$(jq -r '.env.HQ_BYPASS_CORE_PROTECT // empty' "$SETTINGS_LOCAL" 2>/dev/null) || return 1
  [[ "$val" == "1" || "$val" == "true" ]] && return 0
  return 1
}

if is_bypass_authorized; then
  exit 0
fi

# Build absolute path prefixes.
CORE_ABS="$PROJECT_DIR/core/"
CLAUDE_ABS="$PROJECT_DIR/.claude/"
AGENTS_ABS="$PROJECT_DIR/.agents/"
CODEX_ABS="$PROJECT_DIR/.codex/"
OBSIDIAN_ABS="$PROJECT_DIR/.obsidian/"
TEMPLATE_ABS="$PROJECT_DIR/companies/_template/"

esc() { printf '%s' "$1" | sed 's/[][\\.*^$(){}?+|]/\\&/g'; }
CORE_ABS_ESC="$(esc "$CORE_ABS")"
CLAUDE_ABS_ESC="$(esc "$CLAUDE_ABS")"
AGENTS_ABS_ESC="$(esc "$AGENTS_ABS")"
CODEX_ABS_ESC="$(esc "$CODEX_ABS")"
OBSIDIAN_ABS_ESC="$(esc "$OBSIDIAN_ABS")"
TEMPLATE_ABS_ESC="$(esc "$TEMPLATE_ABS")"

# Per-dir path alternation patterns, split by how unambiguously each form
# denotes the LIVE HQ root:
#
#   *_ABS_ALTS  -- absolute prefixes and the ${CLAUDE_PROJECT_DIR}/${HQ_ROOT}
#                  env forms. These ALWAYS point at the live HQ scaffold, so
#                  they are enforced unconditionally.
#   *_REL_ALTS  -- bare-relative ("(\./)?.claude/") and ${REPO_ROOT}/ forms.
#                  From inside a checked-out repo under repos/ these denote the
#                  REPO's own scaffold (legitimate dev work -- e.g. editing
#                  hq-core-staging/.claude/hooks/*), not the live root. They are
#                  enforced only when the command is NOT operating inside a
#                  repos/ checkout (see in_repo_context). The command-text
#                  scanner cannot see the shell cwd, so without this split a
#                  relative ".claude/" typed from a repos/ checkout
#                  false-positives as a live-root write.
#
# companies/_template/ is a locked path per core.yaml; it follows the same
# ABS/REL split so the Bash guard matches the Edit/Write guard while still
# allowing legitimate edits to the prototype from inside a repos/ checkout.
CORE_ABS_ALTS='(\$\{?CLAUDE_PROJECT_DIR\}?/core/|\$\{?HQ_ROOT\}?/core/|'"$CORE_ABS_ESC"')'
CLAUDE_ABS_ALTS='(\$\{?CLAUDE_PROJECT_DIR\}?/\.claude/|\$\{?HQ_ROOT\}?/\.claude/|'"$CLAUDE_ABS_ESC"')'
AGENTS_ABS_ALTS='(\$\{?CLAUDE_PROJECT_DIR\}?/\.agents/|\$\{?HQ_ROOT\}?/\.agents/|'"$AGENTS_ABS_ESC"')'
CODEX_ABS_ALTS='(\$\{?CLAUDE_PROJECT_DIR\}?/\.codex/|\$\{?HQ_ROOT\}?/\.codex/|'"$CODEX_ABS_ESC"')'
OBSIDIAN_ABS_ALTS='(\$\{?CLAUDE_PROJECT_DIR\}?/\.obsidian/|\$\{?HQ_ROOT\}?/\.obsidian/|'"$OBSIDIAN_ABS_ESC"')'
TEMPLATE_ABS_ALTS='(\$\{?CLAUDE_PROJECT_DIR\}?/companies/_template/|\$\{?HQ_ROOT\}?/companies/_template/|'"$TEMPLATE_ABS_ESC"')'

CORE_REL_ALTS='((\./)?core/|\$\{?REPO_ROOT\}?/core/)'
CLAUDE_REL_ALTS='((\./)?\.claude/|\$\{?REPO_ROOT\}?/\.claude/)'
AGENTS_REL_ALTS='((\./)?\.agents/|\$\{?REPO_ROOT\}?/\.agents/)'
CODEX_REL_ALTS='((\./)?\.codex/|\$\{?REPO_ROOT\}?/\.codex/)'
OBSIDIAN_REL_ALTS='((\./)?\.obsidian/|\$\{?REPO_ROOT\}?/\.obsidian/)'
TEMPLATE_REL_ALTS='((\./)?companies/_template/|\$\{?REPO_ROOT\}?/companies/_template/)'

ABS_PATH_ALTS="($CORE_ABS_ALTS|$CLAUDE_ABS_ALTS|$AGENTS_ABS_ALTS|$CODEX_ABS_ALTS|$OBSIDIAN_ABS_ALTS|$TEMPLATE_ABS_ALTS)"
REL_PATH_ALTS="($CORE_REL_ALTS|$CLAUDE_REL_ALTS|$AGENTS_REL_ALTS|$CODEX_REL_ALTS|$OBSIDIAN_REL_ALTS|$TEMPLATE_REL_ALTS)"
ALL_PATH_ALTS="($ABS_PATH_ALTS|$REL_PATH_ALTS)"
# Boundary set includes = and : so VAR=<path> assignments and colon-joined
# PATH-style lists (...:/abs/core/...) are caught, not just whitespace-delimited args.
BND='(^|[[:space:]]|[;|&(=:]|["'\''])'
AGENTS_MD_TOKEN_RE='(^|[[:space:]]|[;|&(=:]|["'\''])AGENTS\.md'

WRITE_OPS='(^|[[:space:]])(rm|rmdir|cp|mv|mkdir|touch|chmod|chown|chgrp|tee|dd|rsync|sed[[:space:]]+-i[^[:space:]]*|sed[[:space:]]+--in-place|awk[[:space:]]+-i[[:space:]]+inplace|ln)([[:space:]]|$)'

# True when the command changes directory into a checked-out repo tree -- either
# a source checkout under repos/ or a git worktree under workspace/worktrees/
# (cd/pushd whose target path contains a repos/ or workspace/worktrees/ segment).
# A worktree under workspace/worktrees/<repo>/<name>/ is a checkout of <repo>, so
# its scaffold tokens (.claude/, core/, ...) are the repo's own tree, NOT the
# live HQ root -- same rationale as repos/. ONLY cd/pushd qualify: they move the
# shell cwd, so subsequent relative scaffold tokens refer to the checkout's tree.
# `git -C <path>` does NOT change the cwd (and git subcommands never match the
# shell WRITE_OPS scanner anyway), so it is deliberately excluded to avoid
# leaking the exemption to unrelated relative tokens in the same command. The
# "([^...]*/)?" requires any chars before the segment to end at a slash, so
# "/tmp/myrepos/" and "/tmp/myworkspace/worktrees/" do NOT match.
in_repo_context() {
  echo "$1" | grep -Eq '(^|[[:space:]])(cd|pushd)[[:space:]]+["'\'']?([^;&|[:space:]"'\'']*/)?(repos/|workspace/worktrees/)'
}

strip_token_quotes() {
  local tok="$1"
  case "$tok" in
    \"*\") tok="${tok#\"}"; tok="${tok%\"}" ;;
    \'*\') tok="${tok#\'}"; tok="${tok%\'}" ;;
  esac
  printf '%s' "$tok"
}

WRITE_TARGET_PROTECTED_CWD="no"
WRITE_TARGET_PROTECTED_VARS=""

raw_token_matches_re() {
  local token="$1" token_re="$2"
  printf ' %s' "$token" | grep -Eq "$token_re"
}

target_matches_re() {
  local token="$1" token_re="$2" var
  if raw_token_matches_re "$token" "$token_re"; then
    return 0
  fi
  for var in $WRITE_TARGET_PROTECTED_VARS; do
    case "$token" in
      "\$$var"|"\$$var/"*|"\${$var}"|"\${$var}/"*) return 0 ;;
    esac
  done
  if [[ "$WRITE_TARGET_PROTECTED_CWD" = "yes" ]]; then
    case "$token" in
      /*) ;;
      \$*) ;;
      *) return 0 ;;
    esac
  fi
  return 1
}

segment_fallback_matches() {
  local segment="$1" token_re="$2"
  echo "$segment" | grep -Eq "$token_re"
}

record_segment_context() {
  local segment="$1" token_re="$2"
  local words=() clean=() i tok key val next

  read -r -a words <<< "$segment"
  for ((i=0; i<${#words[@]}; i++)); do
    clean[$i]="$(strip_token_quotes "${words[$i]}")"
  done

  for ((i=0; i<${#clean[@]}; i++)); do
    tok="${clean[$i]}"
    case "$tok" in
      [A-Za-z_]*=*)
        key="${tok%%=*}"
        val="${tok#*=}"
        if [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && raw_token_matches_re "$val" "$token_re"; then
          case " $WRITE_TARGET_PROTECTED_VARS " in
            *" $key "*) ;;
            *) WRITE_TARGET_PROTECTED_VARS="$WRITE_TARGET_PROTECTED_VARS $key" ;;
          esac
        fi
        ;;
      cd|pushd)
        next="${clean[$((i+1))]:-}"
        if [[ -n "$next" ]] && raw_token_matches_re "$next" "$token_re"; then
          WRITE_TARGET_PROTECTED_CWD="yes"
        elif [[ "$tok" = "cd" && -n "$next" ]]; then
          WRITE_TARGET_PROTECTED_CWD="no"
        fi
        ;;
    esac
  done
}

write_targets_match() {
  local segment="$1" token_re="$2"
  local words=() clean=() targets=() positionals=()
  local word op="" op_i=-1 i j tok next positional_count has_inplace has_ef
  local target_dir="" target_count=0

  # Whitespace tokenization is deliberate: this is a best-effort guard and
  # matches the documented parser contract for the hook.
  read -r -a words <<< "$segment"
  for ((i=0; i<${#words[@]}; i++)); do
    clean[$i]="$(strip_token_quotes "${words[$i]}")"
  done

  for ((i=0; i<${#clean[@]}; i++)); do
    case "${clean[$i]}" in
      rm|rmdir|cp|mv|mkdir|touch|chmod|chown|chgrp|tee|dd|rsync|sed|awk|ln)
        op="${clean[$i]}"
        op_i=$i
        break
        ;;
    esac
  done

  [[ "$op_i" -ge 0 ]] || return 1

  case "$op" in
    rm|rmdir|touch|mkdir|tee)
      for ((i=op_i+1; i<${#clean[@]}; i++)); do
        tok="${clean[$i]}"
        [[ -z "$tok" || "$tok" == -* ]] && continue
        targets[${#targets[@]}]="$tok"
      done
      ;;

    cp|rsync|mv)
      for ((i=op_i+1; i<${#clean[@]}; i++)); do
        tok="${clean[$i]}"
        case "$tok" in
          -t)
            i=$((i+1))
            if [[ "$i" -lt "${#clean[@]}" ]]; then
              target_dir="${clean[$i]}"
            else
              return 2
            fi
            ;;
          --target-directory=*)
            target_dir="${tok#--target-directory=}"
            ;;
          --target-directory)
            i=$((i+1))
            if [[ "$i" -lt "${#clean[@]}" ]]; then
              target_dir="${clean[$i]}"
            else
              return 2
            fi
            ;;
          -*)
            ;;
          *)
            positionals[${#positionals[@]}]="$tok"
            ;;
        esac
      done
      if [[ -n "$target_dir" ]]; then
        targets[${#targets[@]}]="$target_dir"
      elif [[ "$op" = "mv" ]]; then
        for ((i=0; i<${#positionals[@]}; i++)); do
          targets[${#targets[@]}]="${positionals[$i]}"
        done
      elif [[ "${#positionals[@]}" -gt 0 ]]; then
        targets[${#targets[@]}]="${positionals[$((${#positionals[@]}-1))]}"
      else
        return 2
      fi
      ;;

    ln)
      for ((i=op_i+1; i<${#clean[@]}; i++)); do
        tok="${clean[$i]}"
        [[ -z "$tok" || "$tok" == -* ]] && continue
        positionals[${#positionals[@]}]="$tok"
      done
      if [[ "${#positionals[@]}" -gt 0 ]]; then
        targets[${#targets[@]}]="${positionals[$((${#positionals[@]}-1))]}"
      else
        return 2
      fi
      ;;

    chmod|chown|chgrp)
      positional_count=0
      for ((i=op_i+1; i<${#clean[@]}; i++)); do
        tok="${clean[$i]}"
        [[ -z "$tok" || "$tok" == -* ]] && continue
        positional_count=$((positional_count+1))
        [[ "$positional_count" -eq 1 ]] && continue
        targets[${#targets[@]}]="$tok"
      done
      ;;

    dd)
      for ((i=op_i+1; i<${#clean[@]}; i++)); do
        tok="${clean[$i]}"
        case "$tok" in
          of=*) targets[${#targets[@]}]="${tok#of=}" ;;
        esac
      done
      ;;

    sed)
      has_inplace="no"
      has_ef="no"
      for ((i=op_i+1; i<${#clean[@]}; i++)); do
        tok="${clean[$i]}"
        case "$tok" in
          -i|--in-place|-i*) has_inplace="yes" ;;
          -e|-f) has_ef="yes"; i=$((i+1)) ;;
          -e*|-f*) has_ef="yes" ;;
          --expression|--file) has_ef="yes"; i=$((i+1)) ;;
          --expression=*|--file=*) has_ef="yes" ;;
          --*) ;;
          -*) ;;
          *) positionals[${#positionals[@]}]="$tok" ;;
        esac
      done
      [[ "$has_inplace" = "yes" ]] || return 1
      j=0
      if [[ "$has_ef" = "no" ]]; then
        j=1
      fi
      for ((i=j; i<${#positionals[@]}; i++)); do
        targets[${#targets[@]}]="${positionals[$i]}"
      done
      ;;

    awk)
      has_inplace="no"
      for ((i=op_i+1; i<${#clean[@]}; i++)); do
        tok="${clean[$i]}"
        next="${clean[$((i+1))]:-}"
        if [[ "$tok" = "-i" && "$next" = "inplace" ]]; then
          has_inplace="yes"
          i=$((i+1))
          continue
        fi
        [[ -z "$tok" || "$tok" == -* ]] && continue
        positionals[${#positionals[@]}]="$tok"
      done
      [[ "$has_inplace" = "yes" ]] || return 1
      for ((i=1; i<${#positionals[@]}; i++)); do
        targets[${#targets[@]}]="${positionals[$i]}"
      done
      ;;
  esac

  target_count="${#targets[@]}"
  if [[ "$target_count" -eq 0 ]]; then
    return 2
  fi
  for ((i=0; i<target_count; i++)); do
    if target_matches_re "${targets[$i]}" "$token_re"; then
      return 0
    fi
  done
  return 1
}

write_op_targets_protected() {
  local cmd="$1" token_re="$2"
  local segments segment rc
  WRITE_TARGET_PROTECTED_CWD="no"
  WRITE_TARGET_PROTECTED_VARS=""
  segments=$(printf '%s' "$cmd" | sed -E 's/(&&|\|\||[;|&])/\n/g')
  while IFS= read -r segment; do
    [[ -z "$segment" ]] && continue
    record_segment_context "$segment" "$token_re"
    echo "$segment" | grep -Eq "$WRITE_OPS" || continue
    write_targets_match "$segment" "$token_re"
    rc=$?
    if [[ "$rc" -eq 0 ]]; then
      return 0
    fi
    if [[ "$rc" -eq 2 ]] && segment_fallback_matches "$segment" "$token_re"; then
      return 0
    fi
  done <<< "$segments"
  return 1
}

writes_to_protected() {
  local cmd="$1"
  # Strip settings.local.json refs -- that file is the allowed exception inside .claude/.
  local stripped
  stripped=$(echo "$cmd" | sed 's|[^[:space:]]*settings\.local\.json[^[:space:]]*||g; s|settings\.local\.json||g')

  # Absolute/live-root forms are always enforced; relative forms only outside a
  # repos/ checkout.
  local path_alts token_re repo_ctx="no"
  if in_repo_context "$cmd"; then
    repo_ctx="yes"
    path_alts="$ABS_PATH_ALTS"
    token_re="$BND$ABS_PATH_ALTS"
  else
    path_alts="$ALL_PATH_ALTS"
    token_re="$BND$ALL_PATH_ALTS"
  fi

  # Redirect (>) or append (>>) into any protected dir.
  if echo "$stripped" | grep -Eq '(^|[[:space:]]|=)>{1,2}[[:space:]]*["'\'']?'"$path_alts"; then
    return 0
  fi
  # Write-op tool + protected write target token.
  if write_op_targets_protected "$stripped" "$token_re"; then
    return 0
  fi
  # AGENTS.md (single file). In a repos/ checkout the bare AGENTS.md token is the
  # repo's own file, so skip it there -- same rationale as the relative alts.
  if [ "$repo_ctx" = "no" ]; then
    if echo "$cmd" | grep -Eq '(^|[[:space:]])>{1,2}[[:space:]]*["'\'']?AGENTS\.md'; then
      return 0
    fi
    if write_op_targets_protected "$cmd" "$AGENTS_MD_TOKEN_RE"; then
      return 0
    fi
  fi
  return 1
}

if writes_to_protected "$CMD"; then
  cat >&2 <<EOF
BLOCKED: Bash command appears to write into protected scaffold paths.
  Command: $CMD

Protected: core/, .claude/, .agents/, .codex/, .obsidian/, companies/_template/, AGENTS.md
Exception: .claude/settings.local.json is always writable.

Preferred fix: author the content under personal/ (reindex symlinks it into
core/), which needs no bypass at all.

A bypass exists, but DO NOT enable it on your own. Setting
"HQ_BYPASS_CORE_PROTECT": "1" under "env" in .claude/settings.local.json turns
OFF this protection for EVERY later write in the session, so it requires the
user's explicit approval. Ask the user to confirm first; only with their
go-ahead set the flag (and offer to turn it back off when done). Inline
env-var prefixes are not accepted.

If this block is wrong or surprising, report it with /hq-bug.
EOF
  exit 2
fi

exit 0
