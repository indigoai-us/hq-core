#!/bin/bash
# enforce-vault-write-access.sh — PreToolUse hook for Edit, Write, MultiEdit,
# NotebookEdit, and Bash.
#
# Blocks file mutations (edits, writes, deletes, moves, copies-into, …) under
# companies/<slug>/ when the local vault-access manifest says the current
# identity does NOT hold write permission on that path. A teammate whose vault
# share is read-only would otherwise edit or delete synced files locally and
# only discover the denial when the push is rejected server-side.
#
# Manifest: <hqRoot>/.hq/vault-access.json — refreshed by
# core/scripts/refresh-vault-access.sh from `hq files shared-with-me` plus the
# caller's membership role. Schema:
#
#   {
#     "version": 1,
#     "companies": {
#       "<slug>": {
#         "role": "owner|admin|member|guest|unknown",
#         "enforced": true,
#         "grants": [
#           { "path": "reports/*", "permission": "read|write|admin" }
#         ]
#       }
#     }
#   }
#
# Semantics (best-effort local mirror of server-side vault ACL resolution):
#   - Manifest missing/unparseable, company absent from it, role
#     owner/admin/unknown, or enforced=false  →  ALLOW (fail-open). The
#     server-side STS/ACL layer is the real security boundary; this hook only
#     stops doomed local edits to read-only shares before they happen.
#   - role member/guest  →  effective permission = most-specific matching
#     grant (longest pattern wins; tie → higher permission). Grant patterns
#     are company-relative: "*" (whole vault), "prefix/*" (subtree, also
#     matches the bare "prefix" directory itself), or an exact key. No match
#     → no access. write/admin → allow; read/none → BLOCK.
#   - companies/manifest.yaml and companies/_template/ are exempt.
#
# Bash coverage is best-effort (exhaustive shell analysis is intractable) and
# follows the same parser contract as block-core-writes-bash.sh: segment
# splitting on &&/||/;/|/&, whitespace tokenization, per-op target extraction,
# and redirect detection. Inside a repos/ or workspace/worktrees/ checkout
# (cd/pushd context), bare-relative "companies/…" tokens are the checkout's own
# tree and are NOT enforced; absolute and $CLAUDE_PROJECT_DIR/$HQ_ROOT forms
# always are.
#
# Bypass: HQ_BYPASS_VAULT_WRITE_PROTECT="1" under "env" in
# .claude/settings.local.json — same contract as HQ_BYPASS_CORE_PROTECT: it
# disables this protection for every later mutation, so an agent must NEVER
# set it autonomously; ask the user first. Inline env-var prefixes are NOT
# accepted.
#
# Exit codes: 0 = allow, 2 = block.

set -uo pipefail

INPUT=$(cat)

# No jq → cannot read the manifest → fail-open (consistent with other guards).
command -v jq >/dev/null 2>&1 || exit 0

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || true
case "$TOOL" in
  Edit|Write|MultiEdit|NotebookEdit|Bash) ;;
  *) exit 0 ;;
esac

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/scripts/hook-lib.sh"
PROJECT_DIR="$(hq_canonical_path "$PROJECT_DIR")"

MANIFEST="$PROJECT_DIR/.hq/vault-access.json"
[[ -f "$MANIFEST" ]] || exit 0
jq -e 'type == "object"' "$MANIFEST" >/dev/null 2>&1 || exit 0

SETTINGS_LOCAL="$PROJECT_DIR/.claude/settings.local.json"

# Bypass: must be declared in .claude/settings.local.json env section.
# NOTE: agents must ask the user before enabling this (see block message).
is_bypass_authorized() {
  [[ -f "$SETTINGS_LOCAL" ]] || return 1
  local val
  val=$(jq -r '.env.HQ_BYPASS_VAULT_WRITE_PROTECT // empty' "$SETTINGS_LOCAL" 2>/dev/null) || return 1
  [[ "$val" == "1" || "$val" == "true" ]] && return 0
  return 1
}

if is_bypass_authorized; then
  exit 0
fi

# effective_permission <slug> <company-relative-path>
# Prints: bypass | write | admin | read | none
effective_permission() {
  local slug="$1" rel="$2" out
  out=$(jq -r --arg slug "$slug" --arg rel "$rel" '
    def rank:
      if . == "admin" then 3
      elif . == "write" then 2
      elif . == "read" then 1
      else 0 end;
    (.companies[$slug] // null) as $c
    | if $c == null then "bypass"
      elif (($c.role // "unknown") | IN("owner", "admin", "unknown")) then "bypass"
      elif ((if ($c | has("enforced")) then $c.enforced else true end) | not) then "bypass"
      else (
        [ ($c.grants // [])[]
          | . as $g
          | select(
              ($g.path == "*")
              or ($g.path == $rel)
              or (($g.path | endswith("/*")) and ($rel | startswith($g.path[0:-1])))
              or (($g.path | endswith("/*")) and ($rel == $g.path[0:-2]))
            ) ]
        | if length == 0 then "none"
          else (sort_by([(.path | length), (.permission | rank)]) | last | .permission)
          end
      ) end
  ' "$MANIFEST" 2>/dev/null) || out="bypass"
  [[ -n "$out" ]] || out="bypass"
  printf '%s' "$out"
}

DENY_SLUG=""
DENY_REL=""
DENY_PERM=""

# check_vault_path <absolute-path>
# Returns 0 when the mutation is allowed (or not a vault path), 1 when denied.
check_vault_path() {
  local abs="$1" rel slug crel perm
  case "$abs" in
    "$PROJECT_DIR"/companies/?*) ;;
    *) return 0 ;;
  esac
  rel="${abs#"$PROJECT_DIR"/companies/}"
  case "$rel" in
    manifest.yaml|_template|_template/*) return 0 ;;
  esac
  slug="${rel%%/*}"
  if [[ "$slug" == "$rel" ]]; then
    crel=""
  else
    crel="${rel#*/}"
  fi
  perm="$(effective_permission "$slug" "$crel")"
  case "$perm" in
    bypass|write|admin) return 0 ;;
  esac
  DENY_SLUG="$slug"
  DENY_REL="$crel"
  DENY_PERM="$perm"
  return 1
}

block_message() {
  # $1 = human description of the attempted mutation
  local what="$1" have
  if [[ "$DENY_PERM" == "read" ]]; then
    have="read-only"
  else
    have="no"
  fi
  cat >&2 <<EOF
BLOCKED: you do not have write access to this vault path.
  $what
  Company: $DENY_SLUG
  Vault path: ${DENY_REL:-<entire vault>}
  Your access (from .hq/vault-access.json): $have

This path is synced from the company vault, and your membership grants do not
include write permission on it. A local edit or delete here would be rejected
(or clobbered) at the next sync — the server-side ACL is authoritative.

Options:
  - Ask a company owner/admin to grant you write on this prefix (/hq-files, or
    they run: hq files share <prefix> --with <you> --permission write).
  - If your grants recently changed, refresh the local access manifest:
    bash core/scripts/refresh-vault-access.sh
  - Work on a copy outside companies/ (e.g. workspace/drafts/) and share it
    back for someone with write access to land.

A bypass exists, but DO NOT enable it on your own. Setting
"HQ_BYPASS_VAULT_WRITE_PROTECT": "1" under "env" in
.claude/settings.local.json turns OFF this protection for EVERY later
mutation, so it requires the user's explicit approval. Ask the user to
confirm first; only with their go-ahead set the flag (and offer to turn it
back off when done). Inline env-var prefixes are not accepted.

If this block is wrong or surprising, report it with /hq-bug.
EOF
}

# ── Edit / Write / MultiEdit / NotebookEdit ─────────────────────────────────

if [[ "$TOOL" != "Bash" ]]; then
  FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null) || true
  [[ -z "$FILE_PATH" ]] && exit 0
  if ! hq_path_is_absolute "$FILE_PATH"; then
    FILE_PATH="$PROJECT_DIR/$FILE_PATH"
  fi
  FILE_PATH="$(hq_canonical_path "$FILE_PATH")"
  if ! check_vault_path "$FILE_PATH"; then
    block_message "File: ${FILE_PATH#$PROJECT_DIR/}"
    exit 2
  fi
  exit 0
fi

# ── Bash ────────────────────────────────────────────────────────────────────

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || true
[[ -z "$CMD" ]] && exit 0

# Fast path: no companies token anywhere in the command → nothing to check.
case "$CMD" in
  *companies/*) ;;
  *) exit 0 ;;
esac

WRITE_OPS='(^|[[:space:]])(rm|rmdir|cp|mv|mkdir|touch|chmod|chown|chgrp|tee|dd|rsync|truncate|shred|sed[[:space:]]+-i[^[:space:]]*|sed[[:space:]]+--in-place|awk[[:space:]]+-i[[:space:]]+inplace|ln)([[:space:]]|$)'

# True when the command cd/pushd-es into a checked-out repo tree (repos/ or
# workspace/worktrees/) — there, bare-relative companies/ tokens denote the
# checkout's own tree, not the live HQ vault. Same contract as
# block-core-writes-bash.sh.
in_repo_context() {
  echo "$1" | grep -Eq '(^|[[:space:]])(cd|pushd)[[:space:]]+["'\'']?([^;&|[:space:]"'\'']*/)?(repos/|workspace/worktrees/)'
}

REPO_CTX="no"
if in_repo_context "$CMD"; then
  REPO_CTX="yes"
fi

strip_token_quotes() {
  local tok="$1"
  case "$tok" in
    \"*\") tok="${tok#\"}"; tok="${tok%\"}" ;;
    \'*\') tok="${tok#\'}"; tok="${tok%\'}" ;;
  esac
  printf '%s' "$tok"
}

# resolve_vault_token <token>
# Prints the absolute live-root path when the token denotes a companies/ path
# this hook should check; prints nothing otherwise.
resolve_vault_token() {
  local tok="$1"
  case "$tok" in
    "\$CLAUDE_PROJECT_DIR"/companies/*) printf '%s' "$PROJECT_DIR/${tok#\$CLAUDE_PROJECT_DIR/}" ;;
    "\${CLAUDE_PROJECT_DIR}"/companies/*) printf '%s' "$PROJECT_DIR/${tok#\$\{CLAUDE_PROJECT_DIR\}/}" ;;
    "\$HQ_ROOT"/companies/*) printf '%s' "$PROJECT_DIR/${tok#\$HQ_ROOT/}" ;;
    "\${HQ_ROOT}"/companies/*) printf '%s' "$PROJECT_DIR/${tok#\$\{HQ_ROOT\}/}" ;;
    "$PROJECT_DIR"/companies/*) printf '%s' "$tok" ;;
    /*) ;;
    \$*) ;;
    companies/*|./companies/*)
      if [[ "$REPO_CTX" == "no" ]]; then
        printf '%s' "$PROJECT_DIR/${tok#./}"
      fi
      ;;
  esac
}

# token_denied <token> — 0 when the token resolves to a vault path the caller
# may not write. Sets DENY_* on denial.
token_denied() {
  local tok abs
  tok="$(strip_token_quotes "$1")"
  abs="$(resolve_vault_token "$tok")"
  [[ -n "$abs" ]] || return 1
  abs="$(hq_canonical_path "$abs")"
  if ! check_vault_path "$abs"; then
    return 0
  fi
  return 1
}

# collect_write_targets <segment>
# Per-op write-target extraction (same parser contract as
# block-core-writes-bash.sh write_targets_match). Fills SEG_TARGETS.
# Returns 0 = targets extracted, 1 = no write op found, 2 = op found but
# targets undeterminable (caller falls back to checking every token).
SEG_TARGETS=()
collect_write_targets() {
  local segment="$1"
  local words=() clean=() positionals=()
  local op="" op_i=-1 i j tok next positional_count has_inplace has_ef
  local target_dir=""
  SEG_TARGETS=()

  read -r -a words <<< "$segment"
  for ((i=0; i<${#words[@]}; i++)); do
    clean[$i]="$(strip_token_quotes "${words[$i]}")"
  done

  for ((i=0; i<${#clean[@]}; i++)); do
    case "${clean[$i]}" in
      rm|rmdir|cp|mv|mkdir|touch|chmod|chown|chgrp|tee|dd|rsync|truncate|shred|sed|awk|ln)
        op="${clean[$i]}"
        op_i=$i
        break
        ;;
    esac
  done

  [[ "$op_i" -ge 0 ]] || return 1

  case "$op" in
    rm|rmdir|touch|mkdir|tee|truncate|shred)
      for ((i=op_i+1; i<${#clean[@]}; i++)); do
        tok="${clean[$i]}"
        [[ -z "$tok" || "$tok" == -* ]] && continue
        SEG_TARGETS[${#SEG_TARGETS[@]}]="$tok"
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
        SEG_TARGETS[${#SEG_TARGETS[@]}]="$target_dir"
      elif [[ "$op" = "mv" ]]; then
        # mv mutates every operand (sources are removed, dest is written).
        for ((i=0; i<${#positionals[@]}; i++)); do
          SEG_TARGETS[${#SEG_TARGETS[@]}]="${positionals[$i]}"
        done
      elif [[ "${#positionals[@]}" -gt 0 ]]; then
        SEG_TARGETS[${#SEG_TARGETS[@]}]="${positionals[$((${#positionals[@]}-1))]}"
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
        SEG_TARGETS[${#SEG_TARGETS[@]}]="${positionals[$((${#positionals[@]}-1))]}"
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
        SEG_TARGETS[${#SEG_TARGETS[@]}]="$tok"
      done
      ;;

    dd)
      for ((i=op_i+1; i<${#clean[@]}; i++)); do
        tok="${clean[$i]}"
        case "$tok" in
          of=*) SEG_TARGETS[${#SEG_TARGETS[@]}]="${tok#of=}" ;;
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
        SEG_TARGETS[${#SEG_TARGETS[@]}]="${positionals[$i]}"
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
        SEG_TARGETS[${#SEG_TARGETS[@]}]="${positionals[$i]}"
      done
      ;;
  esac

  if [[ "${#SEG_TARGETS[@]}" -eq 0 ]]; then
    return 2
  fi
  return 0
}

# collect_redirect_targets <segment> — fills REDIR_TARGETS with the file
# operands of > / >> redirections (fd-prefixed forms included, >&N excluded).
REDIR_TARGETS=()
collect_redirect_targets() {
  local segment="$1"
  local words=() i tok rest
  REDIR_TARGETS=()
  read -r -a words <<< "$segment"
  for ((i=0; i<${#words[@]}; i++)); do
    tok="${words[$i]}"
    case "$tok" in
      *\>\>*) rest="${tok#*>>}" ;;
      *\>*)   rest="${tok#*>}" ;;
      *) continue ;;
    esac
    case "$rest" in
      \&*) continue ;;
      "")
        rest="${words[$((i+1))]:-}"
        case "$rest" in
          ""|\&*) continue ;;
        esac
        ;;
    esac
    REDIR_TARGETS[${#REDIR_TARGETS[@]}]="$rest"
  done
}

check_segment() {
  local segment="$1" i rc tok
  [[ -z "$segment" ]] && return 0

  collect_redirect_targets "$segment"
  for ((i=0; i<${#REDIR_TARGETS[@]}; i++)); do
    if token_denied "${REDIR_TARGETS[$i]}"; then
      return 1
    fi
  done

  echo "$segment" | grep -Eq "$WRITE_OPS" || return 0

  collect_write_targets "$segment"
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    for ((i=0; i<${#SEG_TARGETS[@]}; i++)); do
      if token_denied "${SEG_TARGETS[$i]}"; then
        return 1
      fi
    done
  elif [[ "$rc" -eq 2 ]]; then
    # Targets undeterminable — conservatively check every token that looks
    # like a vault path.
    for tok in $segment; do
      if token_denied "$tok"; then
        return 1
      fi
    done
  fi
  return 0
}

SEGMENTS=$(printf '%s' "$CMD" | sed -E 's/(&&|\|\||[;|&])/\n/g')
while IFS= read -r SEGMENT; do
  if ! check_segment "$SEGMENT"; then
    block_message "Command: $CMD"
    exit 2
  fi
done <<< "$SEGMENTS"

exit 0
