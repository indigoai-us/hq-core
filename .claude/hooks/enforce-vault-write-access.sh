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
#   - A missing manifest allows writes so a fresh install remains usable before
#     the first successful manual refresh. By default, invalid data, an absent
#     company, and an unknown role retain the prior allow behavior. When
#     hooks.vault-write-deny-unknown-access is on, those cases block protected
#     company-path writes with refresh/sign-in guidance. Known owner/admin roles
#     and enforced=false retain their existing bypass. The server-side STS/ACL
#     layer remains the security boundary; this hook prevents doomed local edits.
#   - role member/guest  →  effective permission = most-specific matching
#     grant (longest pattern wins; tie → higher permission). Grant patterns
#     are company-relative: "*" (whole vault), "prefix/*" (subtree, also
#     matches the bare "prefix" directory itself), "prefix/" (private
#     create-only folder, hq-pro #3662: a write/admin grant covers direct
#     children only, since write there creates a new creator-owned child; a
#     read grant covers no children), or an exact key. No match
#     → no access. write/admin → allow; read/none → BLOCK.
#   - companies/manifest.yaml and companies/_template/ are exempt.
#
# Bash coverage is best-effort (exhaustive shell analysis is intractable) and
# follows the same parser contract as block-core-writes-bash.sh: segment
# splitting on &&/||/;/|/&, whitespace tokenization, per-op target extraction,
# and redirect detection. Words are split quote-aware; ~/ and $HOME/ prefixes
# expand; relative targets resolve against the payload cwd and any cd/pushd in
# the command. Inside a repos/ or workspace/worktrees/ checkout
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

INPUT=""
if [[ "${HQ_HOOK_TOOL_NAME+x}" ]]; then
  # master-hook has already parsed this field. On the common allow path, use
  # it before reading stdin or starting jq.
  TOOL="$HQ_HOOK_TOOL_NAME"
else
  INPUT=$(cat)

  # No jq → cannot parse the tool payload or manifest, so this guard cannot
  # determine whether a mutation targets a protected company path.
  command -v jq >/dev/null 2>&1 || exit 0

  TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || true
fi
case "$TOOL" in
  Edit|Write|MultiEdit|NotebookEdit|Bash) ;;
  *) exit 0 ;;
esac

# The dispatcher-provided tool name avoids parsing, but supported tools still
# need their original payload for path/command checks below.
if [[ ! "${HQ_HOOK_TOOL_NAME+x}" ]]; then
  : # INPUT was read above for the fallback path.
else
  INPUT=$(cat)
  command -v jq >/dev/null 2>&1 || exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/scripts/hook-lib.sh"
PROJECT_DIR="$(hq_canonical_path "$PROJECT_DIR")"

MANIFEST="$PROJECT_DIR/.hq/vault-access.json"
# A missing manifest is expected before the first successful manual refresh on
# a fresh install; preserve usability until access data has been created.
[[ -f "$MANIFEST" ]] || exit 0
MANIFEST_INVALID=0
jq -e 'type == "object"' "$MANIFEST" >/dev/null 2>&1 || MANIFEST_INVALID=1

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
  if [[ "$MANIFEST_INVALID" == 1 ]]; then
    out="unknown"
  else
    out=$(jq -r --arg slug "$slug" --arg rel "$rel" '
    def rank:
      if . == "admin" then 3
      elif . == "write" then 2
      elif . == "read" then 1
      else 0 end;
    (.companies[$slug] // null) as $c
    | if $c == null then "unknown"
      elif (($c.role // "unknown") | IN("owner", "admin")) then "bypass"
      elif ((if ($c | has("enforced")) then $c.enforced else true end) | not) then "bypass"
      elif (($c.role // "unknown") != "member" and ($c.role // "unknown") != "guest") then "unknown"
      else (
        [ ($c.grants // [])[]
          | . as $g
          | select(
              ($g.path == "*")
              or ($g.path == $rel)
              or (($g.path | endswith("/*")) and ($rel | startswith($g.path[0:-1])))
              or (($g.path | endswith("/*")) and ($rel == $g.path[0:-2]))
              or (($g.path | endswith("/"))
                  and ($g.permission == "write" or $g.permission == "admin")
                  and ($rel | startswith($g.path))
                  and (($rel | ltrimstr($g.path)) as $child
                       | ($child | length) > 0 and ($child | contains("/") | not)))
            ) ]
        | if length == 0 then "none"
          else (sort_by([(.path | length), (.permission | rank)]) | last | .permission)
          end
      ) end
  ' "$MANIFEST" 2>/dev/null) || out="unknown"
  fi
  [[ -n "$out" ]] || out="unknown"
  printf '%s' "$out"
}

DENY_SLUG=""
DENY_REL=""
DENY_PERM=""
# Exact-key grants that sit directly above the denied path, one per line as
# "<path> (<permission>)". A grant written as "knowledge" (no trailing "/" or
# "/*") covers only an object named exactly "knowledge" — on the server too —
# so a member who was meant to get the folder is denied under it. Naming the
# near miss in the block message turns a dead end into the right share command.
DENY_NEAR=""

# near_miss_grants <slug> <company-relative-path>
# Prints exact-key grants whose path is a strict directory prefix of the path.
near_miss_grants() {
  local slug="$1" rel="$2"
  [[ "$MANIFEST_INVALID" == 1 ]] && return 0
  jq -r --arg slug "$slug" --arg rel "$rel" '
    (.companies[$slug] // null) as $c
    | if $c == null then empty else
        ($c.grants // [])[]
        | . as $g
        | select(($g.path != "*")
            and ($g.path | endswith("/*") | not)
            and ($g.path | endswith("/") | not)
            and ($rel | startswith($g.path + "/")))
        | "\($g.path) (\($g.permission))"
      end
  ' "$MANIFEST" 2>/dev/null || true
}

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
  if [[ "$perm" == "unknown" ]]; then
    local flag_reader flag_enabled
    flag_reader="$(dirname "${BASH_SOURCE[0]}")/enforce-vault-write-access-flag.cjs"
    flag_enabled=false
    if [[ -n "${HQ_FLAGS_API_URL:-}" \
      && "${HQ_COMPANY_UID:-}" =~ ^cmp_[A-Za-z0-9]{3,128}$ ]] \
      && command -v node >/dev/null 2>&1 && [[ -f "$flag_reader" ]]; then
      flag_enabled="$(HQ_CLI_BIN="$(command -v hq 2>/dev/null || true)" \
        node "$flag_reader")" || flag_enabled=false
    fi
    [[ "$flag_enabled" == "true" ]] || return 0
  fi
  case "$perm" in
    bypass|write|admin) return 0 ;;
  esac
  DENY_SLUG="$slug"
  DENY_REL="$crel"
  DENY_PERM="$perm"
  DENY_NEAR=""
  if [[ "$perm" == "none" ]]; then
    DENY_NEAR="$(near_miss_grants "$slug" "$crel")"
  fi
  return 1
}

block_message() {
  # $1 = human description of the attempted mutation
  local what="$1" have
  if [[ "$DENY_PERM" == "read" ]]; then
    have="read-only"
  elif [[ "$DENY_PERM" == "unknown" ]]; then
    have="unknown"
  else
    have="no"
  fi
  cat >&2 <<EOF
BLOCKED: you do not have write access to this vault path.
  $what
  Company: $DENY_SLUG
  Vault path: ${DENY_REL:-<entire vault>}
  Your access (from .hq/vault-access.json): $have

EOF
  if [[ "$DENY_PERM" == "unknown" ]]; then
    cat >&2 <<'EOF'
The local manifest does not confirm your role for this company. Run HQ sync or
sign in again, then retry so the local access manifest can be refreshed.
EOF
  else
    cat >&2 <<'EOF'
This path is synced from the company vault, and your membership grants do not
include write permission on it. A local edit or delete here would be rejected
(or clobbered) at the next sync — the server-side ACL is authoritative.
EOF
  fi
  if [[ -n "$DENY_NEAR" ]]; then
    local near_path near_first
    near_first="${DENY_NEAR%%$'\n'*}"
    near_path="${near_first% (*}"
    cat >&2 <<EOF

Near miss: your manifest lists an exact-key grant above this path:
$(printf '%s\n' "$DENY_NEAR" | sed 's/^/  /')
An exact-key grant covers only an object named exactly '$near_path', not the
files under '$near_path/'. The server applies the same rule, so a push would be
refused as well. Ask a company owner/admin to share the folder instead:
    hq files share '$near_path/*' --with <you> --permission write
EOF
  fi
  cat >&2 <<EOF
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

# Bash parsing is best effort. Known gaps: an unknown cwd (cd "$VAR", cd -,
# cd $(...)) is not followed, so later relative targets are not checked;
# popd and subshell scope are not tracked; writes inside $(...), backticks or
# bash -c '...' strings are seen only when a companies/ token is visible.

# ── Bash ────────────────────────────────────────────────────────────────────

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || true
[[ -z "$CMD" ]] && exit 0
# Join backslash-newline continuations so a target on the next line is seen.
# The pattern sits in a quoted variable: bash 3.2 (macOS /bin/bash) matches
# nothing for an unquoted $'\\\n' pattern.
LINE_CONT=$'\\\n'
CMD="${CMD//"$LINE_CONT"/ }"
# `>|` (noclobber override) is a redirect; keep the segment splitter below
# from reading its `|` as a pipe.
CMD="${CMD//>|/>}"

# The Bash tool's working directory. When it is inside companies/, relative
# targets (cp x projects/y) land in the vault even without a companies/ token.
PAYLOAD_CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || true
if [[ -n "$PAYLOAD_CWD" ]]; then
  if hq_path_is_absolute "$PAYLOAD_CWD"; then
    PAYLOAD_CWD="$(hq_canonical_path "$PAYLOAD_CWD")"
  else
    PAYLOAD_CWD=""
  fi
fi

# Fast path: no companies token anywhere in the command and the shell is not
# already inside companies/ → nothing to check.
case "$CMD" in
  *companies/*) ;;
  *)
    case "$PAYLOAD_CWD" in
      "$PROJECT_DIR"/companies/*) ;;
      *) exit 0 ;;
    esac
    ;;
esac

WRITE_OPS='(^|[[:space:](/])(rm|rmdir|cp|mv|mkdir|touch|chmod|chown|chgrp|tee|dd|rsync|truncate|shred|sed[[:space:]]+-i[^[:space:]]*|sed[[:space:]]+--in-place|awk[[:space:]]+-i[[:space:]]+inplace|ln|install)([[:space:]]|$)'

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
  # Drop shell grouping characters glued to a word: (cp a b) / { cp a b; }.
  while [[ "$tok" == \(* || "$tok" == \{* ]]; do tok="${tok#?}"; done
  while [[ "$tok" == *\) || "$tok" == *\} ]]; do tok="${tok%?}"; done
  tok="${tok//\"/}"
  tok="${tok//\'/}"
  printf '%s' "$tok"
}

# split_words <string> — quote-aware word split. Whitespace inside '…' or "…"
# does not split, so "companies/x/a b.md" stays one word. Quote characters are
# kept (strip_token_quotes removes them). Fills WORDS.
WORDS=()
# Runs in the C locale: every delimiter is ASCII, UTF-8 continuation bytes
# never equal one, and ${s:i:1} is then a constant-time byte index instead of
# a rescan from the start of the string (quadratic under UTF-8).
split_words() {
  local LC_ALL=C
  local s="$1" cur="" q="" c i n have=0
  n=${#s}
  WORDS=()
  for ((i=0; i<n; i++)); do
    c="${s:i:1}"
    if [[ -n "$q" ]]; then
      cur+="$c"
      [[ "$c" == "$q" ]] && q=""
      continue
    fi
    case "$c" in
      \"|\') q="$c"; cur+="$c"; have=1 ;;
      " "|$'\t'|$'\n')
        if [[ "$have" == 1 ]]; then WORDS[${#WORDS[@]}]="$cur"; fi
        cur=""; have=0 ;;
      *) cur+="$c"; have=1 ;;
    esac
  done
  if [[ "$have" == 1 ]]; then WORDS[${#WORDS[@]}]="$cur"; fi
}

# expand_home <token> — expand a leading ~/, $HOME/ or ${HOME}/.
expand_home() {
  local tok="$1"
  if [[ -n "${HOME:-}" ]]; then
    case "$tok" in
      \~) tok="$HOME" ;;
      \~/*) tok="$HOME/${tok#\~/}" ;;
      "\$HOME") tok="$HOME" ;;
      "\$HOME/"*) tok="$HOME/${tok#\$HOME/}" ;;
      "\${HOME}") tok="$HOME" ;;
      "\${HOME}/"*) tok="$HOME/${tok#\$\{HOME\}/}" ;;
    esac
  fi
  printf '%s' "$tok"
}

# Effective working directory for relative tokens: the Bash tool's cwd, then
# updated by cd/pushd segments in the command. Empty = unknown.
CWD_CTX="$PAYLOAD_CWD"

# update_cwd_ctx <segment> — follow cd/pushd so later relative targets resolve
# against the directory the command actually moved into.
update_cwd_ctx() {
  local first target base
  [[ "$1" =~ ^[[:space:]\(\{]*[\"\']?(cd|pushd)[\"\']?([[:space:]]|$) ]] || return 0
  split_words "$1"
  [[ "${#WORDS[@]}" -gt 0 ]] || return 0
  first="$(strip_token_quotes "${WORDS[0]}")"
  case "$first" in
    cd|pushd) ;;
    *) return 0 ;;
  esac
  target="$(strip_token_quotes "${WORDS[1]:-}")"
  [[ "$target" == "-P" || "$target" == "-L" ]] && target="$(strip_token_quotes "${WORDS[2]:-}")"
  if [[ -z "$target" ]]; then
    target="${HOME:-}"
  fi
  target="$(expand_home "$target")"
  case "$target" in
    "\$CLAUDE_PROJECT_DIR"*|"\${CLAUDE_PROJECT_DIR}"*|"\$HQ_ROOT"*|"\${HQ_ROOT}"*)
      target="$PROJECT_DIR/${target#*/}"
      [[ "$target" == "$PROJECT_DIR/"*'$'* ]] && target="$PROJECT_DIR"
      ;;
    -|\$*|"") CWD_CTX=""; return 0 ;;
  esac
  if ! hq_path_is_absolute "$target"; then
    base="${CWD_CTX:-$PROJECT_DIR}"
    target="$base/$target"
  fi
  CWD_CTX="$(hq_canonical_path "$target")"
}

# resolve_vault_token <token>
# Prints the absolute live-root path when the token denotes a companies/ path
# this hook should check; prints nothing otherwise.
resolve_vault_token() {
  local tok
  tok="$(expand_home "$1")"
  case "$tok" in
    "\$CLAUDE_PROJECT_DIR"/companies/*) printf '%s' "$PROJECT_DIR/${tok#\$CLAUDE_PROJECT_DIR/}" ;;
    "\${CLAUDE_PROJECT_DIR}"/companies/*) printf '%s' "$PROJECT_DIR/${tok#\$\{CLAUDE_PROJECT_DIR\}/}" ;;
    "\$HQ_ROOT"/companies/*) printf '%s' "$PROJECT_DIR/${tok#\$HQ_ROOT/}" ;;
    "\${HQ_ROOT}"/companies/*) printf '%s' "$PROJECT_DIR/${tok#\$\{HQ_ROOT\}/}" ;;
    /*) printf '%s' "$tok" ;;
    \$*|-*|"") ;;
    companies/*|./companies/*)
      if [[ "$REPO_CTX" == "no" ]]; then
        printf '%s' "${CWD_CTX:-$PROJECT_DIR}/${tok#./}"
      fi
      ;;
    *)
      # Other relative tokens: inside companies/ every relative path matters;
      # elsewhere only ones that climb (../companies/...) can reach the vault.
      # An unknown cwd (cd "$VAR", cd -, cd $(...)) leaves CWD_CTX empty and
      # is not checked: best-effort parser, documented in the header.
      case "$CWD_CTX" in
        "$PROJECT_DIR"/companies/*) printf '%s' "$CWD_CTX/$tok" ;;
        "") ;;
        *)
          case "$tok" in
            ..|../*|*/../*|*/..) printf '%s' "$CWD_CTX/$tok" ;;
          esac
          ;;
      esac
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

  split_words "$segment"
  words=("${WORDS[@]+"${WORDS[@]}"}")
  for ((i=0; i<${#words[@]}; i++)); do
    clean[$i]="$(strip_token_quotes "${words[$i]}")"
  done

  for ((i=0; i<${#clean[@]}; i++)); do
    # /bin/cp and /usr/bin/install are the same ops as cp and install.
    case "${clean[$i]##*/}" in
      rm|rmdir|cp|mv|mkdir|touch|chmod|chown|chgrp|tee|dd|rsync|truncate|shred|sed|awk|ln|install)
        op="${clean[$i]##*/}"
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

    install)
      # install SRC... DEST, install -t DIR SRC..., install -d DIR...
      for ((i=op_i+1; i<${#clean[@]}; i++)); do
        tok="${clean[$i]}"
        case "$tok" in
          -d|--directory) has_inplace="dirs" ;;
          -t|--target-directory)
            i=$((i+1)); target_dir="${clean[$i]:-}"; [[ -n "$target_dir" ]] || return 2 ;;
          --target-directory=*) target_dir="${tok#--target-directory=}" ;;
          -m|-o|-g|--mode|--owner|--group|-S|--suffix) i=$((i+1)) ;;
          -*) ;;
          *) positionals[${#positionals[@]}]="$tok" ;;
        esac
      done
      if [[ -n "$target_dir" ]]; then
        SEG_TARGETS[${#SEG_TARGETS[@]}]="$target_dir"
      elif [[ "${has_inplace:-}" == "dirs" ]]; then
        for ((i=0; i<${#positionals[@]}; i++)); do
          SEG_TARGETS[${#SEG_TARGETS[@]}]="${positionals[$i]}"
        done
      elif [[ "${#positionals[@]}" -gt 0 ]]; then
        SEG_TARGETS[${#SEG_TARGETS[@]}]="${positionals[$((${#positionals[@]}-1))]}"
      else
        return 2
      fi
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
          -[!-]*t)
            # Grouped short options ending in t (cp -rt DIR): DIR is next.
            if [[ "$op" != "rsync" ]]; then
              i=$((i+1))
              if [[ "$i" -lt "${#clean[@]}" ]]; then
                target_dir="${clean[$i]}"
              else
                return 2
              fi
            fi
            ;;
          -[!-]*t?*)
            # Glued target (cp -tDIR, cp -rtDIR) when every letter before t
            # is a plain flag letter.
            if [[ "$op" != "rsync" && "${tok%%t*}" =~ ^-[A-Za-z]*$ ]]; then
              target_dir="${tok#"${tok%%t*}t"}"
            fi
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
  split_words "$segment"
  words=("${WORDS[@]+"${WORDS[@]}"}")
  for ((i=0; i<${#words[@]}; i++)); do
    tok="${words[$i]}"
    # A quoted word ("a>b") is data, not a redirection.
    [[ "$tok" == \"* || "$tok" == \'* ]] && continue
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

# Segments longer than this skip the quote-aware parser (bounded hook time on
# long one-line commands such as inline JSON or python3 -c). Instead every
# whitespace token that can name a vault path (a companies/ or ../ token, a
# ~ or $HOME form; redirect operands included) is checked. When the shell
# already sits inside companies/, any relative token can land in the vault, so
# a long segment there that has a write op or a redirect fails closed.
SEGMENT_PARSE_MAX=4096

check_segment() {
  local segment="$1" i rc tok
  [[ -z "$segment" ]] && return 0

  if [[ "${#segment}" -gt "$SEGMENT_PARSE_MAX" ]]; then
    local LC_ALL=C
    local -a toks=()
    case "$CWD_CTX" in
      "$PROJECT_DIR"/companies/*)
        if [[ "$segment" == *\>* ]] || echo "$segment" | grep -Eq "$WRITE_OPS"; then
          return 1
        fi
        ;;
    esac
    read -r -a toks <<< "$segment"
    for tok in "${toks[@]+"${toks[@]}"}"; do
      tok="${tok##*>}"
      case "$tok" in
        *companies/*|*../*|*\~*|*HOME*) ;;
        *) continue ;;
      esac
      if token_denied "$tok"; then
        return 1
      fi
    done
    return 0
  fi

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
    split_words "$segment"
    for tok in "${WORDS[@]+"${WORDS[@]}"}"; do
      if token_denied "$tok"; then
        return 1
      fi
    done
  fi
  return 0
}

SEGMENTS=$(printf '%s' "$CMD" | sed -E 's/(&&|\|\||[;|&])/\n/g')
while IFS= read -r SEGMENT; do
  update_cwd_ctx "$SEGMENT"
  if ! check_segment "$SEGMENT"; then
    block_message "Command: $CMD"
    exit 2
  fi
done <<< "$SEGMENTS"

exit 0
