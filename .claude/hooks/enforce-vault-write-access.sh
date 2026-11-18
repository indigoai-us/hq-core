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

SETTINGS_LOCAL="$PROJECT_DIR/.claude/settings.local.json"

# Path comparisons against companies/ ignore case on every platform. Default
# macOS (APFS) and Windows (NTFS) filesystems are case-insensitive, so
# Companies/, COMPANIES/ and companies/Example-Co/ name the same files as
# companies/example-co/; a case-sensitive match let those spellings skip the
# vault check. On a case-sensitive filesystem the only cost is that a
# differently cased sibling of companies/ is also checked (fail-closed).
# block-company-git-metadata.sh lowercases for the same reason.
# vault_under <path> <dir> — 0 when path is a strict descendant of dir.
vault_under() {
  local rc=1 restore=0
  shopt -q nocasematch || { shopt -s nocasematch; restore=1; }
  [[ "$1" == "$2"/?* ]] && rc=0
  [[ "$restore" == 1 ]] && shopt -u nocasematch
  return "$rc"
}
# vault_lower <string> — ASCII lowercase (bash 3.2 has no ${var,,}).
vault_lower() {
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}
VAULT_ROOT="$PROJECT_DIR/companies"
# Symlink-resolved companies/ root, computed lazily by vault_real_root. A
# symlink outside companies/ (or inside one company) can point into another
# company's folder, so check_vault_path checks the real path as well.
VAULT_ROOT_REAL=""
vault_real_root() {
  if [[ -z "$VAULT_ROOT_REAL" ]]; then
    VAULT_ROOT_REAL="$(hq_canonical_path "$(hq_realpath_dir "$PROJECT_DIR")")/companies"
  fi
  printf '%s' "$VAULT_ROOT_REAL"
}

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

# Arithmetic is independent of vault membership data, so check Bash even on
# a fresh install. Parse the command once and reuse it in the Bash path below.
if [ "$TOOL" = Bash ]; then
  CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || true
  [[ -z "$CMD" ]] && exit 0
  # jq.exe turns each LF in the payload command into CRLF (see hq_crlf_to_lf).
  hq_crlf_to_lf CMD
  if [ ! -f "${BASH_SOURCE[0]%/*}/bash-arith-subst-guard-lib.sh" ]; then
    printf '%s\n' 'BLOCKED: Bash arithmetic check. The arithmetic guard helper is missing; refresh the hook installation.' >&2
    exit 2
  fi
  . "${BASH_SOURCE[0]%/*}/bash-arith-subst-guard-lib.sh"
  if ! hq_arith_guard_check "$CMD"; then
    hq_arith_guard_message
    exit 2
  fi
fi

MANIFEST="$PROJECT_DIR/.hq/vault-access.json"
# A missing manifest still allows ordinary writes before the first refresh.
[[ -f "$MANIFEST" ]] || exit 0
MANIFEST_INVALID=0
jq -e 'type == "object"' "$MANIFEST" >/dev/null 2>&1 || MANIFEST_INVALID=1

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
    ([(.companies // {}) | to_entries[] | select((.key | ascii_downcase) == $slug) | .value] | first // null) as $c
    | if $c == null then "unknown"
      elif (($c.role // "unknown") | IN("owner", "admin")) then "bypass"
      elif ((if ($c | has("enforced")) then $c.enforced else true end) | not) then "bypass"
      elif (($c.role // "unknown") != "member" and ($c.role // "unknown") != "guest") then "unknown"
      else (
        [ ($c.grants // [])[]
          | (.path |= ascii_downcase)
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
    ([(.companies // {}) | to_entries[] | select((.key | ascii_downcase) == $slug) | .value] | first // null) as $c
    | if $c == null then empty else
        ($c.grants // [])[]
        | (.path |= ascii_downcase)
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
# Checks the path as written and its symlink-resolved real path (parent chain
# resolved; a leaf that does not exist yet is kept). Either one denying blocks.
check_vault_path() {
  local abs="$1" real root
  check_vault_path_one "$abs" "$VAULT_ROOT" || return 1
  real="$(hq_canonical_path "$(hq_realpath_lenient "$abs")")"
  root="$(vault_real_root)"
  if [[ "$real" != "$abs" || "$root" != "$VAULT_ROOT" ]]; then
    check_vault_path_one "$real" "$root" || return 1
  fi
  return 0
}

# check_vault_path_one <absolute-path> <companies-root>
check_vault_path_one() {
  local abs="$1" vroot="$2" rel slug crel perm
  vault_under "$abs" "$vroot" || return 0
  # Lowercase the company-relative path: slug keys, exemptions and grant
  # patterns are compared case-insensitively (see vault_under).
  rel="$(vault_lower "${abs:$((${#vroot} + 1))}")"
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
# Match the prefix as if quotes/backslashes were removed. A regex avoids
# Bash 3.2's quadratic whole-string replacement on large quoted commands.
VAULT_QUOTE_RUN="[\"'\\\\]*"
VAULT_PREFIX_RE="[cC]${VAULT_QUOTE_RUN}[oO]${VAULT_QUOTE_RUN}[mM]${VAULT_QUOTE_RUN}[pP]${VAULT_QUOTE_RUN}[aA]${VAULT_QUOTE_RUN}[nN]${VAULT_QUOTE_RUN}[iI]${VAULT_QUOTE_RUN}[eE]${VAULT_QUOTE_RUN}[sS]${VAULT_QUOTE_RUN}/"
# An escape inside $'...' can spell the prefix ($'\x63ompanies/'), which the
# regex cannot see, so a command holding $' and a \x, \u, \U or octal escape
# anywhere is parsed in full. Only those escapes can produce a letter or a
# slash, so commands whose escapes are \n, \t and the like keep the fast exit.
if ! [[ "$CMD" =~ $VAULT_PREFIX_RE ]] && [[ "$CMD" != *\$\'* || "$CMD" != *\\[xuU0-7]* ]]; then
  vault_under "$PAYLOAD_CWD" "$VAULT_ROOT" || exit 0
fi

WRITE_OPS='(^|[[:space:](/])(rm|rmdir|cp|mv|mkdir|touch|chmod|chown|chgrp|tee|dd|rsync|truncate|shred|g?sed[[:space:]]+([^;|&]*[[:space:]])?(-[A-Za-z]*[iI]|--in)[^[:space:]]*|(g|m)?awk[[:space:]]+([^;|&]*[[:space:]])?-i[[:space:]]*inplace|(perl|ruby)[[:space:]]+([^;|&]*[[:space:]])?-[A-Za-z]*i[^[:space:]]*|ln|install)([[:space:]]|$)'

# STRIPPED_OPS is matched against a segment with its quotes, backslashes and $
# removed. It holds the in-place forms of WRITE_OPS, plus a plain op only in
# command position: at segment start, after a path, a find -exec, or leading
# words that are assignments, redirects, options, numbers, shell keywords
# (then, do, if, ...) or launchers (env, sudo, timeout, ...). So 'rm' x and
# sed '-i' read as writes while grep 'rm' x does not.
STRIPPED_OPS='(^[[:space:](\{!]*(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|[0-9]*[<>][^[:space:]]*|sudo|env|command|builtin|exec|nice|nohup|time|timeout|stdbuf|xargs|then|do|else|if|elif|while|until|-[^[:space:]]*|[0-9][^[:space:]]*)[[:space:]]+)*([^[:space:]]*/)?(rm|rmdir|cp|mv|mkdir|touch|chmod|chown|chgrp|tee|dd|rsync|truncate|shred|ln|install)([[:space:]]|$))|([[:space:]]-(exec|execdir|ok|okdir)[[:space:]]+([^[:space:]]*/)?(rm|rmdir|cp|mv|mkdir|touch|chmod|chown|chgrp|tee|dd|rsync|truncate|shred|ln|install)([[:space:]]|$))|((^|[[:space:](/])(g?sed[[:space:]]+([^;|&]*[[:space:]])?(-[A-Za-z]*[iI]|--in)[^[:space:]]*|(g|m)?awk[[:space:]]+([^;|&]*[[:space:]])?-i[[:space:]]*inplace|(perl|ruby)[[:space:]]+([^;|&]*[[:space:]])?-[A-Za-z]*i[^[:space:]]*)([[:space:]]|$))'

# write_op_in <segment> — true when WRITE_OPS matches the segment, or
# STRIPPED_OPS matches a copy with quote characters, backslashes and $ removed
# ('rm' x, sed '-i', awk -i 'inplace', perl -p$'i'). tr does the removal: a
# bash ${//} replacement is quadratic on long segments.
write_op_in() {
  printf '%s\n' "$1" | grep -Eq "$WRITE_OPS" && return 0
  [[ "$1" == *[\"\'\\]* ]] || return 1
  printf '%s\n' "$1" | LC_ALL=C tr -d "\"'\\\\\$" | grep -Eq "$STRIPPED_OPS"
}

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

# decode_ansi_c <body> — the text of a $'...' segment with its escapes decoded
# as bash does (\xHH, \NNN, \n, \\, \', ...), so $'sour\x63e' reads as source.
# printf's format string takes the same escapes; % is doubled so it stays
# literal. \u and \U are rewritten to \xHH first when they name an ASCII
# character (bash 3.2 printf has no \u). Sets ANSI_DEC.
ANSI_DEC=""
decode_ansi_c() {
  local body="$1" pre="" pct='%' k ch hex max v
  for ((k=0; k<${#body}; k++)); do
    ch="${body:k:1}"
    if [[ "$ch" == \\ ]]; then
      ch="${body:k+1:1}"
      if [[ "$ch" == u || "$ch" == U ]]; then
        [[ "$ch" == u ]] && max=4 || max=8
        hex=""
        while [[ "${#hex}" -lt "$max" && "${body:k+2+${#hex}:1}" == [0-9A-Fa-f] ]]; do
          hex+="${body:k+2+${#hex}:1}"
        done
        if [[ -n "$hex" ]] && v=$((16#$hex)) && [[ "$v" -lt 128 ]]; then
          pre+="$(printf '\\x%02x' "$v")"
          k=$((k+1+${#hex}))
          continue
        fi
      fi
      pre+="\\$ch"
      k=$((k+1))
      continue
    fi
    pre+="$ch"
  done
  printf -v ANSI_DEC "x${pre//$pct/%%}" 2>/dev/null
  ANSI_DEC="${ANSI_DEC#x}"
}

strip_token_quotes() {
  local tok="$1" ansi="" q="" body="" i c
  # Drop shell grouping characters glued to a word: (cp a b) / { cp a b; }.
  while [[ "$tok" == \(* || "$tok" == \{* ]]; do tok="${tok#?}"; done
  while [[ "$tok" == *\) || "$tok" == *\} ]]; do tok="${tok%?}"; done
  # ANSI-C quoted words use $'...'; drop that unescaped quote marker even
  # when it starts inside an option word, while preserving an escaped dollar.
  # The segment's escapes are decoded, so $'-\x69' reads as -i.
  for ((i=0; i<${#tok}; i++)); do
    c="${tok:i:1}"
    if [[ "$q" == A ]]; then
      if [[ "$c" == \\ ]]; then
        body+="$c${tok:i+1:1}"
        i=$((i+1))
      elif [[ "$c" == "'" ]]; then
        decode_ansi_c "$body"
        ansi+="$ANSI_DEC"
        body=""
        q=""
      else
        body+="$c"
      fi
      continue
    fi
    if [[ "$c" == \\ ]]; then
      ansi+="$c"
      i=$((i+1))
      [[ "$i" -lt "${#tok}" ]] && ansi+="${tok:i:1}"
      continue
    fi
    if [[ "$c" == '"' ]]; then
      [[ -z "$q" ]] && q='"' || { [[ "$q" == '"' ]] && q=""; }
    elif [[ "$c" == "'" ]]; then
      [[ -z "$q" ]] && q="'" || { [[ "$q" == "'" ]] && q=""; }
    elif [[ "$c" == '$' && -z "$q" && "${tok:i+1:1}" == '$' ]]; then
      # $$ is the PID parameter: the quote after it is a plain one.
      ansi+='$$'
      i=$((i+1))
      continue
    elif [[ "$c" == '$' && -z "$q" && "${tok:i+1:1}" == "'" ]]; then
      q=A
      i=$((i+1))
      continue
    fi
    ansi+="$c"
  done
  if [[ "$q" == A ]]; then
    decode_ansi_c "$body"
    ansi+="$ANSI_DEC"
  fi
  tok="$ansi"
  tok="${tok//\"/}"
  tok="${tok//\'/}"
  tok="${tok//\\/}"
  printf '%s' "$tok"
}

# split_words <string> — quote-aware word split. Whitespace inside '…', "…" or
# $'…' does not split, so "companies/x/a b.md" stays one word. A backslash
# outside quotes, inside "…" or inside $'…' escapes the next character, so
# $'a\'b' and \' do not open or close a quote. Quote characters are kept
# (strip_token_quotes removes them). Fills WORDS.
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
      if [[ "$c" == \\ && "$q" != "'" ]]; then
        cur+="${s:i+1:1}"
        i=$((i+1))
      elif [[ "$q" == A ]]; then
        [[ "$c" == "'" ]] && q=""
      elif [[ "$c" == "$q" ]]; then
        q=""
      fi
      continue
    fi
    case "$c" in
      \\) cur+="$c${s:i+1:1}"; i=$((i+1)); have=1 ;;
      \$)
        # $$ is the PID parameter, so the quote after $$ is a plain one.
        if [[ "${s:i+1:1}" == '$' ]]; then
          cur+='$$'; i=$((i+1))
        elif [[ "${s:i+1:1}" == "'" ]]; then
          q=A; cur+="\$'"; i=$((i+1))
        else
          cur+="$c"
        fi
        have=1 ;;
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
  local tok out="" restore=0
  tok="$(expand_home "$1")"
  # Windows absolute forms (C:/x, C:\x) are absolute paths too.
  if [[ "$tok" == [A-Za-z]:[/\\]* ]] && hq_path_is_absolute "$tok"; then
    printf '%s' "$tok"
    return 0
  fi
  shopt -q nocasematch || { shopt -s nocasematch; restore=1; }
  out="$(resolve_vault_token_ci "$tok")"
  [[ "$restore" == 1 ]] && shopt -u nocasematch
  printf '%s' "$out"
}

# resolve_vault_token_ci <token> — body of resolve_vault_token; the caller
# turns on nocasematch so every companies/ form below matches in any case.
resolve_vault_token_ci() {
  local tok="$1"
  case "$tok" in
    "\$CLAUDE_PROJECT_DIR"/companies/*) printf '%s' "$PROJECT_DIR/${tok:20}" ;;
    "\${CLAUDE_PROJECT_DIR}"/companies/*) printf '%s' "$PROJECT_DIR/${tok:22}" ;;
    "\$HQ_ROOT"/companies/*) printf '%s' "$PROJECT_DIR/${tok:9}" ;;
    "\${HQ_ROOT}"/companies/*) printf '%s' "$PROJECT_DIR/${tok:11}" ;;
    /*) printf '%s' "$tok" ;;
    \$*|-*|"") ;;
    companies/*|./companies/*)
      # (case-insensitive: nocasematch is on here)
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

# SEG_IN_QUOTE is "yes" while checking a segment that begins inside an open
# quote of the original command. Segment splitting on ;|& is not quote-aware,
# so python3 -c 'x=1; re.sub("<style.*?</style>", ...)' yields a segment that
# starts inside the -c string, and its </style> reads as a redirect onto ","
# or "))" (feedback_e9ee6aa4). Only in such segments, a token that has no
# letter or digit, or that holds a "<", is code text and not a path. Segments
# that start outside quotes are checked as before.
SEG_IN_QUOTE="no"

# looks_like_vault_token <token> — 1 only for code fragments in a quoted segment.
looks_like_vault_token() {
  [[ "$SEG_IN_QUOTE" == "yes" ]] || return 0
  local t
  t="$(strip_token_quotes "$1")"
  case "$t" in
    *\<*) return 1 ;;
    *[A-Za-z0-9]*) return 0 ;;
  esac
  return 1
}

# token_denied <token> — 0 when the token resolves to a vault path the caller
# may not write. Sets DENY_* on denial.
token_denied() {
  local tok abs
  tok="$1"
  # On Windows a backslash inside a quoted word is a path separator, and
  # strip_token_quotes would delete it (companies\x -> companiesx).
  # Treating every backslash as a separator only adds checks.
  [[ "${HQ_LIB_WINSEP:-0}" == 1 ]] && tok="${tok//\\//}"
  tok="$(strip_token_quotes "$tok")"
  looks_like_vault_token "$tok" || return 1
  abs="$(resolve_vault_token "$tok")"
  [[ -n "$abs" ]] || return 1
  abs="$(hq_canonical_path "$abs")"
  if ! check_vault_path "$abs"; then
    return 0
  fi
  return 1
}

# cut_operand <has_ef> <n> <last_pos> <last raw word> — for a segment the
# splitter cut inside a quote. Returns 0 when the cut word is the script (the
# only operand, with no -e or -f), whose file operands follow in later
# fragments. When the cut word is a later operand it is a file name holding
# ; | or &: it stays a target, checked as far as it goes, and SEG_CUT keeps it
# so the main loop checks the whole name once its quote closes.
cut_operand() {
  [[ "$SEG_OPEN" = "o" && "$3" = "yes" ]] || return 1
  [[ "$1" = "no" && "$2" -eq 1 ]] && return 0
  SEG_CUT="$4"
  return 1
}

# collect_write_targets <segment>
# Per-op write-target extraction (same parser contract as
# block-core-writes-bash.sh write_targets_match). Fills SEG_TARGETS.
# Returns 0 = targets extracted, 1 = no write op found, 2 = op found but
# targets undeterminable (caller falls back to checking every token).
SEG_TARGETS=()
# SEG_OPEN is "o" when the splitter cut the segment inside a quote; SEG_INPLACE
# is set to "yes" when the segment is an in-place sed or awk edit, and SEG_OP to
# that op. SEG_CUT is the raw start of a file operand the splitter cut inside
# its quotes (a name holding ; | or &), so the main loop can check the whole name.
SEG_OPEN="c"
SEG_INPLACE="no"
SEG_OP=""
SEG_CUT=""
# SEG_EOO is "yes" when the in-place sed, perl, ruby or awk command saw --
# before the splitter cut it, so later dash-named words are file operands.
SEG_EOO="no"
# awk_program_opt <word> — true when <word> (a gawk -W argument, or a long
# option name without its leading --) names the source, file or exec option,
# with or without an =value. gawk takes any unique prefix of a long option
# name, so a prefix counts too. Treating it as the program option makes every
# positional a file operand, which can only add targets.
awk_program_opt() {
  local name="${1%%=*}"
  [[ -n "$name" ]] || return 1
  [[ "source" == "$name"* || "file" == "$name"* || "exec" == "$name"* ]]
}

# collect_write_targets_after <index> — called from collect_write_targets
# (whose local words array it reads) when the op word at <index> turned out
# not to write: searches the words after it for another write op.
collect_write_targets_after() {
  local from=$(( $1 + 1 )) rest="" k
  for ((k=from; k<${#words[@]}; k++)); do
    rest="$rest ${words[$k]}"
  done
  [[ -n "${rest// /}" ]] || return 1
  collect_write_targets "$rest"
}

collect_write_targets() {
  local segment="$1"
  local words=() clean=() positionals=()
  local eoo op="" op_i=-1 i j n tok next rest positional_count has_inplace has_ef
  local last_pos
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
      rm|rmdir|cp|mv|mkdir|touch|chmod|chown|chgrp|tee|dd|rsync|truncate|shred|sed|gsed|awk|gawk|mawk|perl|ruby|ln|install)
        op="${clean[$i]##*/}"
        op_i=$i
        break
        ;;
    esac
  done
  case "$op" in gsed) op="sed" ;; gawk|mawk) op="awk" ;; esac

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

    sed|perl|ruby)
      eoo="no"
      has_inplace="no"
      has_ef="no"
      last_pos="no"
      for ((i=op_i+1; i<${#clean[@]}; i++)); do
        tok="${clean[$i]}"
        [[ "$i" -eq $((${#clean[@]}-1)) ]] && last_pos="yes"
        if [[ "$eoo" = "yes" ]]; then
          # After -- every word is an operand; ./ keeps a leading - a path.
          [[ "$tok" == -* ]] && tok="./$tok"
          positionals[${#positionals[@]}]="$tok"
          continue
        fi
        case "$tok" in
          --) eoo="yes"; last_pos="no" ;;
          --expression|--file) has_ef="yes"; i=$((i+1)); last_pos="no" ;;
          --line-length) i=$((i+1)); last_pos="no" ;;
          --expression=*|--file=*) has_ef="yes"; last_pos="no" ;;
          --*)
            last_pos="no"
            # GNU sed accepts any prefix of --in-place from --in on.
            rest="${tok%%=*}"
            if [[ "$op" = "sed" && "${#rest}" -ge 4 && "--in-place" == "$rest"* ]]; then
              has_inplace="yes"
            fi
            ;;
          -?*)
            last_pos="no"
            # A short-option cluster (-n, -Ei, -ni, -i.bak, -pi, -e, -f, -l).
            # Read it left to right: -i takes the rest of the cluster as its
            # suffix, and -e, -f and -l take the rest of the cluster or the next
            # word. BSD sed -I takes the next word as its suffix.
            rest="${tok#-}"
            while [[ -n "$rest" ]]; do
              case "${rest:0:1}" in
                i) has_inplace="yes"; break ;;
                I)
                  if [[ "$op" = "sed" ]]; then
                    has_inplace="yes"
                    [[ "${#rest}" -eq 1 ]] && i=$((i+1))
                  fi
                  break
                  ;;
                e|f|E|l)
                  if [[ "$op" = "sed" ]]; then
                    case "${rest:0:1}" in e|f) has_ef="yes" ;; esac
                    case "${rest:0:1}" in e|f|l) [[ "${#rest}" -eq 1 ]] && i=$((i+1)); break ;; esac
                  else
                    case "${rest:0:1}" in e|E) has_ef="yes"; [[ "${#rest}" -eq 1 ]] && i=$((i+1)); break ;; esac
                  fi
                  ;;
                M|m|x|F|C|D|d|V)
                  [[ "$op" != "sed" ]] && break
                  ;;
              esac
              rest="${rest:1}"
            done
            # Bare -i followed by a separate empty suffix word (the macOS form).
            if [[ "$tok" = "-i" && -z "${clean[$((i+1))]-x}" ]]; then i=$((i+1)); fi
            ;;
          *) positionals[${#positionals[@]}]="$tok" ;;
        esac
      done
      if [[ "$has_inplace" != "yes" ]]; then
        # Not an in-place edit, so this word is not the write op. A later
        # word can still be one (ruby -run -e cp SRC DEST, perl
        # -MExtUtils::Command -e touch FILE), as it was before sed, perl and
        # ruby were ops here.
        collect_write_targets_after "$op_i"
        return $?
      fi
      SEG_INPLACE="yes"
      SEG_EOO="$eoo"
      j=0
      if [[ "$has_ef" = "no" ]]; then
        j=1
      fi
      SEG_OP="$op"
      n=${#positionals[@]}
      cut_operand "$has_ef" "$n" "$last_pos" "${words[$((${#words[@]}-1))]}" && n=0
      for ((i=j; i<n; i++)); do
        SEG_TARGETS[${#SEG_TARGETS[@]}]="${positionals[$i]}"
      done
      [[ "$SEG_OPEN" = "o" ]] && return 0
      ;;

    awk)
      eoo="no"
      has_inplace="no"
      has_ef="no"
      last_pos="no"
      for ((i=op_i+1; i<${#clean[@]}; i++)); do
        tok="${clean[$i]}"
        next="${clean[$((i+1))]:-}"
        [[ "$i" -eq $((${#clean[@]}-1)) ]] && last_pos="yes"
        if [[ "$eoo" = "yes" ]]; then
          # After -- every word is an operand; ./ keeps a leading - a path.
          [[ "$tok" == -* ]] && tok="./$tok"
          positionals[${#positionals[@]}]="$tok"
          continue
        fi
        case "$tok" in
          -i) [[ "$next" = "inplace" ]] && has_inplace="yes"; i=$((i+1)); last_pos="no" ;;
          -iinplace) has_inplace="yes"; last_pos="no" ;;
          -v|-F|-e|-f|-E|-l|-W)
            # -e, -f and -E supply the program, so every positional is a file.
            # So does -W source=, -W file= or -W exec= (or a prefix of them).
            case "$tok" in
              -e|-f|-E) has_ef="yes" ;;
              -W) awk_program_opt "$next" && has_ef="yes" ;;
            esac
            i=$((i+1))
            last_pos="no"
            ;;
          --) eoo="yes"; last_pos="no" ;;
          -W?*) awk_program_opt "${tok#-W}" && has_ef="yes"; last_pos="no" ;;
          --?*=*) awk_program_opt "${tok#--}" && has_ef="yes"; last_pos="no" ;;
          --?*)
            # gawk accepts any unique prefix of a long option.
            if awk_program_opt "${tok#--}"; then has_ef="yes"; i=$((i+1)); fi
            last_pos="no"
            ;;
          -e?*|-f?*|-E?*) has_ef="yes"; last_pos="no" ;;
          -?*) last_pos="no" ;;
          *) positionals[${#positionals[@]}]="$tok" ;;
        esac
      done
      if [[ "$has_inplace" != "yes" ]]; then
        # Not an in-place edit, so this word is not the write op. A later
        # word can still be one (ruby -run -e cp SRC DEST, perl
        # -MExtUtils::Command -e touch FILE), as it was before sed, perl and
        # ruby were ops here.
        collect_write_targets_after "$op_i"
        return $?
      fi
      SEG_INPLACE="yes"
      SEG_EOO="$eoo"
      j=0
      if [[ "$has_ef" = "no" ]]; then
        j=1
      fi
      SEG_OP="$op"
      n=${#positionals[@]}
      cut_operand "$has_ef" "$n" "$last_pos" "${words[$((${#words[@]}-1))]}" && n=0
      for ((i=j; i<n; i++)); do
        SEG_TARGETS[${#SEG_TARGETS[@]}]="${positionals[$i]}"
      done
      [[ "$SEG_OPEN" = "o" ]] && return 0
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
    if vault_under "$CWD_CTX" "$VAULT_ROOT"; then
      if [[ "$segment" == *\>* ]] || write_op_in "$segment"; then
        return 1
      fi
    fi
    if write_op_in "$segment"; then SEG_INPLACE="yes"; fi
    read -r -a toks <<< "$segment"
    for tok in "${toks[@]+"${toks[@]}"}"; do
      tok="${tok##*>}"
      # nocasematch, not vault_lower: no fork per token on long segments.
      shopt -s nocasematch
      case "$tok" in
        *companies/*|*companies\\*|*../*|*..\\*|*\~*|*HOME*) shopt -u nocasematch ;;
        *\$\'*\\*)
          shopt -u nocasematch
          # Decoded first: $'\x63ompanies/x' is a vault path, $'\t' is not.
          case "$(vault_lower "$(strip_token_quotes "$tok")")" in
            *companies/*|*companies\\*|*../*|*..\\*|*\~*) ;;
            *) continue ;;
          esac
          ;;
        *) shopt -u nocasematch; continue ;;
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

  # An escape inside $'...' can hide the op or its in-place flag from the raw
  # text (sed $'-\x69'), so such a segment goes to the parser, which decodes it.
  if ! write_op_in "$segment"; then
    [[ "$segment" == *\$\'*\\* ]] || return 0
  fi

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

# Same split as before (&&, ||, ;, |, & and newlines), with each segment
# prefixed by Q or U. Q means the segment starts inside a '...' or "..." that
# was opened as the argument of a -c or -e word on the same line (python3 -c,
# bash -c, perl -e). Separators still split inside quotes, as the old sed split
# did. Quote state carries across lines as in bash, but only a quote opened on the
# current line can mark a segment Q, and quote tracking stops at an unquoted # comment,
# and $'...' is read with backslash escapes, so an apostrophe in a comment,
# heredoc line or $'...' string cannot mark later segments Q. A Q segment in
# which that quote closes and any shell text follows is U again, so a redirect
# after the closing quote is checked in full.
# The skip applies only to one-line commands with no heredoc, command
# substitution or ${...}: those can nest quotes or hide them from bash, which
# puts the tracker out of step with the shell.
Q_ALLOWED="yes"
case "$CMD" in
  *$'\n'*|*'<<'*|*'$('*|*'`'*|*'${'*) Q_ALLOWED="no" ;;
esac
SEGMENTS=$(printf '%s\n' "$CMD" | LC_ALL=C awk '
{
  line = $0; n = length(line); pad = "    " line
  seg = ""; qc = 0; cmt = 0; start = (q != "" ? "S" : "U"); cl = -1; k = "n"
  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1)
    if (c == ";" || c == "|" || c == "&") {
      d = substr(line, i + 1, 1)
      if ((c == "&" && d == "&") || (c == "|" && d == "|")) i++
      emit(start, seg, cl); seg = ""; cl = -1; start = (q != "" ? (qc ? "Q" : "S") : "U")
      k = (c == ";" ? "s" : (c == "&" ? (d == "&" ? "A" : "a") : (d == "|" ? "P" : "p"))); continue
    }
    seg = seg c
    if (cmt) continue
    if (q == "\047") { if (c == "\047") { q = ""; if (cl < 0) cl = length(seg) }; continue }
    if (c == "\\" && i < n) {
      d = substr(line, i + 1, 1)
      if (d != ";" && d != "|" && d != "&") { seg = seg d; i++ }
      continue
    }
    if (q == "$") { if (c == "\047") { q = ""; if (cl < 0) cl = length(seg) }; continue }
    if (q == "\"") { if (c == "\"") { q = ""; if (cl < 0) cl = length(seg) }; continue }
    w = substr(pad, i, 4)
    if (c == "#" && (substr(w, 4, 1) == " " || substr(w, 4, 1) == "\t")) { cmt = 1; continue }
    if (c == "$" && substr(line, i + 1, 1) == "$") { seg = seg "$"; i++; continue }
    if (c == "$" && substr(line, i + 1, 1) == "\047") { q = "$"; qc = 0; seg = seg "\047"; i++; continue }
    if (c == "\047" || c == "\"") {
      q = c
      qc = ((w == " -c " || w == " -e " || w == "\t-c " || w == "\t-e ") ? 1 : 0)
    }
  }
  emit(start, seg, cl)
}
function emit(st, sg, at) {
  if (st == "Q" && at >= 0 && substr(sg, at + 1) ~ /[^ \t]/) st = "U"
  print st (q != "" ? "o" : "c") k at "|" sg
}')
# The split above also cuts inside quotes, so a sed or awk script such as
# 's/a/b/;s/c/d/' arrives as fragments and its file operands land in a later
# fragment. Each fragment still gets its own full check. In addition, after an
# in-place sed or awk fragment that ends inside an open quote, the words after
# the closing quote are checked as that command's file operands.
# tail_denied <raw word> — token_denied for a word after a cut in-place
# script. BSD sed and gawk stop reading options at the script, so a dash-named
# word there can be a file: it is checked as ./<word> after --, or whenever it
# is not shaped like an option (letters only, or --name[=value]). Quotes are
# stripped first, so a quoted dash-named file is read the same way.
tail_denied() {
  local w
  w="$(strip_token_quotes "$1")"
  if [[ "$w" == -?* ]]; then
    if [[ "$SED_EOO" == "yes" ]] || ! [[ "$w" =~ ^-[A-Za-z]+$ || "$w" =~ ^--[A-Za-z][A-Za-z-]*(=.*)?$ ]]; then
      token_denied "./$w" && return 0
    fi
  fi
  token_denied "$1"
}

SED_TAIL="no"
SED_OP=""
SED_CUT=""
SED_EOO="no"
while IFS= read -r SEGMENT; do
  SEG_ST="${SEGMENT:0:1}"
  SEG_OPEN="${SEGMENT:1:1}"
  # The separator the splitter cut before this fragment.
  case "${SEGMENT:2:1}" in
    s) SEG_SEP=";" ;; a) SEG_SEP="&" ;; A) SEG_SEP="&&" ;;
    p) SEG_SEP="|" ;; P) SEG_SEP="||" ;; *) SEG_SEP=$'\n' ;;
  esac
  SEGMENT="${SEGMENT:3}"
  SEG_AT="${SEGMENT%%|*}"
  SEGMENT="${SEGMENT#*|}"
  SEG_IN_QUOTE="no"
  [[ "$SEG_ST" == "Q" && "$Q_ALLOWED" == "yes" ]] && SEG_IN_QUOTE="yes"
  # A file name cut inside its quotes: rebuild it with the separator and check
  # the whole name once its quote closes.
  if [[ -n "$SED_CUT" ]]; then
    if [[ "$SEG_AT" -ge 0 ]]; then
      if tail_denied "$SED_CUT$SEG_SEP${SEGMENT:0:$SEG_AT}"; then
        block_message "Command: $CMD"
        exit 2
      fi
      SED_CUT=""
    else
      SED_CUT="$SED_CUT$SEG_SEP$SEGMENT"
    fi
  fi
  if [[ "$SED_TAIL" == "yes" && "$SEG_AT" -ge 0 ]]; then
    split_words "${SEGMENT:$SEG_AT}"
    SEG_WN=${#WORDS[@]}
    # A quote reopened in this fragment is cut again. It is a script when it
    # continues the closed word or is the argument of a script option (-e,
    # -f); any other reopened word is a file name, checked as far as it goes
    # here and in full once its quote closes.
    if [[ "$SEG_OPEN" == "o" && "$SEG_WN" -gt 0 ]]; then
      SEG_PREV=""
      [[ "$SEG_WN" -gt 1 ]] && SEG_PREV="$(strip_token_quotes "${WORDS[$((SEG_WN-2))]}")"
      SEG_SCRIPT_ARG="no"
      case "$SED_OP" in
        sed) [[ "$SEG_PREV" =~ ^(-[nsrEuz]*[ef]|--expression|--file)$ ]] && SEG_SCRIPT_ARG="yes" ;;
        perl|ruby) [[ "$SEG_PREV" =~ ^-[pnaslw]*[eE]$ ]] && SEG_SCRIPT_ARG="yes" ;;
        awk) [[ "$SEG_PREV" =~ ^-[vFefE]$ ]] && SEG_SCRIPT_ARG="yes" ;;
      esac
      # The only word, glued to the closing quote, continues the closed word.
      case "$SEG_WN:${SEGMENT:$SEG_AT:1}" in
        1:" "|1:$'\t'|1:) ;;
        1:*) SEG_SCRIPT_ARG="yes" ;;
      esac
      if [[ "$SEG_SCRIPT_ARG" == "yes" ]]; then
        SEG_WN=$((SEG_WN-1))
      else
        SED_CUT="${WORDS[$((SEG_WN-1))]}"
      fi
    fi
    for ((SEG_WI=0; SEG_WI<SEG_WN; SEG_WI++)); do
      SEG_W="${WORDS[$SEG_WI]}"
      if [[ "$SED_EOO" != "yes" && "$(strip_token_quotes "$SEG_W")" == "--" ]]; then
        SED_EOO="yes"
        continue
      fi
      if tail_denied "$SEG_W"; then
        block_message "Command: $CMD"
        exit 2
      fi
    done
  fi
  if [[ "$SEG_OPEN" == "c" ]]; then SED_TAIL="no"; fi
  SEG_INPLACE="no"
  SEG_OP=""
  SEG_CUT=""
  SEG_EOO="no"
  update_cwd_ctx "$SEGMENT"
  if ! check_segment "$SEGMENT"; then
    block_message "Command: $CMD"
    exit 2
  fi
  if [[ "$SEG_OPEN" == "o" && "$SEG_INPLACE" == "yes" ]]; then
    SED_TAIL="yes"
    SED_OP="$SEG_OP"
    SED_EOO="$SEG_EOO"
    [[ -n "$SEG_CUT" ]] && SED_CUT="$SEG_CUT"
  fi
done <<< "$SEGMENTS"
# A cut file name whose quote never closed: check what there is.
if [[ -n "$SED_CUT" ]] && tail_denied "$SED_CUT"; then
  block_message "Command: $CMD"
  exit 2
fi

exit 0
