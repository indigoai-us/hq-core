#!/bin/bash
# block-unsafe-package-install.sh — PreToolUse hard block.
#
# Enforces .claude/policies/hq-pnpm-min-release-age-supply-chain.md.
#
# Blocks:
#   - npm install <pkg>     (any positional package arg)
#   - npm i <pkg>
#   - yarn add <pkg>
#   - bun install <pkg> / bun i <pkg> / bun add <pkg>
#   - pnpm install <pkg> / pnpm i <pkg> / pnpm add <pkg>
#     UNLESS minimum-release-age is configured (.npmrc walking up, pnpm-workspace.yaml,
#     env var npm_config_minimum_release_age, or --config.minimumReleaseAge=... in cmd)
#
# Allows:
#   - npm install / npm ci   (lockfile hydration, no positional pkg arg)
#   - pnpm install / pnpm i  (same — lockfile hydration only)
#   - yarn install (no `add`)
#   - bun install / bun i    (no positional pkg)
#   - GLOBAL installs (-g/--global) where EVERY positional package token matches
#     an entry in core/scripts/install-deps.allow (HQ's sanctioned CLI deps:
#     qmd, hq CLI, Claude Code). `name@exact` allows only that version;
#     `name@*` allows any explicit pin but never a bare name or dist-tag.
#     If the allow file is missing, nothing is allow-listed.
#   - Anything when HQ_ALLOW_UNSAFE_INSTALL=1 is set in THIS hook's process
#     environment (via .claude/settings.local.json "env", or exported before
#     launching Claude Code). NOTE: prefixing that assignment onto the install
#     command itself (an inline command prefix) does NOT work — it sets the var
#     only in the command's own subprocess, never in this hook's env, so the
#     block still fires.
#
# Audit: bypasses append a row to workspace/learnings/unsafe-install-bypasses.jsonl.
#
# Exit codes:
#   0 — allow (pattern not matched, gate satisfied, or bypass set)
#   2 — block (stderr surfaces the rule + remediation)
#
# Input: Claude Code PreToolUse JSON on stdin.

set -uo pipefail

STDIN_JSON="$(cat 2>/dev/null || echo '{}')"

HOOK_SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$HOOK_SOURCE_ROOT}}"
. "$HOOK_SOURCE_ROOT/core/scripts/hook-lib.sh"

extract() {
  printf '%s' "$STDIN_JSON" | hq_json_get "$1"
}

TOOL_NAME="$(extract tool_name)"
[ "$TOOL_NAME" = "Bash" ] || exit 0

CMD="$(extract tool_input.command)"

# Command-level package-source overrides (review of PR 1674). A reviewed name
# or pin only means the package from the default registry, so anything in the
# same command that can redirect an install voids the trusted-scope and
# allow-list shortcuts in check_segment:
#   - package-manager registry / config-file / CA / TLS / proxy env vars
#     (npm_config_* is also read by pnpm and yarn 1; YARN_* is yarn berry;
#     BUN_CONFIG_* is bun; COREPACK_*REGISTRY*), anywhere in the command;
#   - general env vars that change where npm looks for config or how it
#     trusts the network (HOME, XDG_CONFIG_HOME, *_PROXY, NODE_EXTRA_CA_CERTS,
#     NODE_TLS_REJECT_UNAUTHORIZED, SSL_CERT_*) only when exported or declared
#     in the command; as an install-segment prefix they are caught in
#     check_segment (GENERAL_ENV_RE), so `HOME=/tmp/h ls; npm i ...` passes;
#   - writes to .npmrc / etc/npmrc / .yarnrc / .yarnrc.yml / bunfig.toml
#     (redirect, tee, dd of=, sed -i, curl -o, wget -O, and cp/mv/ln/install/rsync when the rc
#     file is the destination or an rc-named source lands in a directory);
#   - `<pm> config set|edit` and `npm|pnpm set`;
#   - a standalone `HOME=...;` style statement before the install;
#   - indirect env names: `export $x=`, `declare -x "a_$(..)"=`.
# Env loaded via source / . / eval / set -a / env $(...) is not inspected
# (it would block nvm, venv and cargo setup); see the PR's known limits.
# The scan is on the raw text and case-insensitive, so it fails closed: text
# that only looks like an override blocks a shortcut install, and only when an
# install is present (commands without one are unaffected).
CMD_SOURCE_OVERRIDE=0
GENERAL_ENV_RE='https?_proxy|all_proxy|node_extra_ca_certs|node_tls_reject_unauthorized|ssl_cert_file|ssl_cert_dir|home|xdg_config_home'
cmd_source_override_scan() {
  # Fork-free: nocasematch makes the [[ =~ ]] and case tests below
  # case-insensitive instead of lowercasing through tr.
  local lc="$1" nocase_restore=0
  shopt -q nocasematch || { nocase_restore=1; shopt -s nocasematch; }
  local env_re='(npm_config_[a-z0-9_]*(registry|userconfig|globalconfig|cafile|strict_ssl|strict-ssl)[a-z0-9_]*|npm_config_ca|npm_config_@[^[:space:]=]*registry|npm_config_(https_|http_)?proxy|corepack_[a-z0-9_]*registr[a-z0-9_]*|yarn_[a-z0-9_]*(registry|ca_file_path|cafile|strict_ssl|rc_filename|scopes)[a-z0-9_]*|bun_config_registry|bun_config_[a-z0-9_]*registr[a-z0-9_]*|bun_install_[a-z0-9_]*registr[a-z0-9_]*)[[:space:]]*:?='
  # /npmrc covers a prefix's etc/npmrc. A glob char in an rc-looking target
  # (.npmr?, .npm*rc, .yarnrc*, .npm{rc,x}) fails closed.
  local rc_re='(\.npmrc|/npmrc|\.yarnrc|\.yarnrc\.yml|bunfig\.toml|(\.[ny[]|/n|bunf)[^[:space:];&|/]*[][?*{])'
  local write_re="(>[|]?[[:space:]]*[^[:space:];&|]*${rc_re}|(^|[^a-z0-9_])tee[[:space:]][^;&|]*${rc_re}|sed[[:space:]]+(-[a-z]*[[:space:]]+)*-i[^;&|]*${rc_re}|(curl|wget)[[:space:]][^;&|]*(-o|--output|--output-document)(=|[[:space:]]*)[^[:space:];&|]*${rc_re}|of=[^[:space:]]*${rc_re})"
  local cfg_re='(^|[^a-z0-9_])(npm|pnpm|yarn|bun)([[:space:]]+[^;&|[:space:]]+)*[[:space:]]+(config|c)[[:space:]]+([^;&|[:space:]]+[[:space:]]+)*(set|edit)([^a-z0-9_-]|$)'
  local set_re='(^|[^a-z0-9_])(npm|pnpm)[[:space:]]+set[[:space:]]'
  # `export $x=...` / `declare -x "$x"=...` names the variable indirectly.
  local indirect_re='(^|[^a-z0-9_])(export|declare|typeset|readonly|local)([[:space:]]+-[a-z]+)*[[:space:]]+([^;&|]*[[:space:]])?["]?[a-z0-9_]*\$(\([^)]*\)|[^=[:space:]])*='
  # A standalone `HOME=/tmp/evil;` statement changes an (already exported)
  # variable for every later command; `HOME=/tmp/h ls;` only prefixes ls.
  local standalone_re="(^|[;&|({]|then|do|else)[[:space:]]*(${GENERAL_ENV_RE})=[^[:space:];&|]*[[:space:]]*([;&|)}]|\$)"
  local gen_export_re="(^|[^a-z0-9_])(export|declare|typeset|readonly)([[:space:]]+-[a-z]+)*[[:space:]]+([^;&|]*[[:space:]])?[\"]?(${GENERAL_ENV_RE})[[:space:]]*="
  # A dequoted copy catches ~/.npm''rc and npm_config_regi''stry.
  local dq
  # $'...' is decoded to its text first, so ~/$'.npmrc' reads as ~/.npmrc.
  dq="${lc//\$\'/\'}"
  dq="${dq//\"/}"; dq="${dq//\'/}"; dq="${dq//\\/}"
  local text
  for text in "$lc" "$dq"; do
    if [[ "$text" =~ $env_re ]] || [[ "$text" =~ $write_re ]] \
      || [[ "$text" =~ $cfg_re ]] || [[ "$text" =~ $set_re ]] \
      || [[ "$text" =~ $indirect_re ]] || [[ "$text" =~ $gen_export_re ]] \
      || [[ "$text" =~ $standalone_re ]]; then
      CMD_SOURCE_OVERRIDE=1
    fi
  done
  [ "$CMD_SOURCE_OVERRIDE" = 1 ] || copy_dest_scan "$dq" "$rc_re"
  [ "$nocase_restore" = 0 ] || shopt -u nocasematch
}

# cp / mv / ln / install / rsync write an rc file when it is the destination
# (the -t / --target-directory operand, else the last operand; `ln <src>`
# alone links into the current directory), or when an rc-named source
# (.npmrc, npmrc, .yarnrc, .yarnrc.yml, bunfig.toml) is copied into a
# directory-looking destination (~, ., $home, anything ending in /, or -t).
# `cp ~/.npmrc /tmp/backup` reads the rc file and is not a write.
copy_dest_scan() {
  local text="$1" rc_re="$2" unit
  local nl=$'\n'
  # Once per command, no line-by-line read loop: skip unless a copy tool
  # appears, then walk the units with parameter expansion.
  local copy_re='(^|[^a-z0-9_])(cp|mv|ln|install|rsync|gcp|gmv|ditto)[[:space:]]'
  [[ "$text" =~ $copy_re ]] || return 0
  text="${text//;/$nl}"; text="${text//&/$nl}"; text="${text//|/$nl}"
  text+="$nl"
  while [ -n "$text" ]; do
    unit="${text%%"$nl"*}"
    text="${text#*"$nl"}"
    local -a words=()
    read -r -a words <<< "$unit"
    [ "${#words[@]}" -gt 0 ] || continue
    local k=0
    while [ "$k" -lt "${#words[@]}" ]; do
      case "${words[$k]}" in
        sudo|doas|command|exec|nohup|env|time|-*|*=*) k=$((k + 1)) ;;
        *) break ;;
      esac
    done
    [ "$k" -lt "${#words[@]}" ] || continue
    local tool="${words[$k]##*/}"
    case "$tool" in cp|mv|ln|install|rsync|gcp|gmv|ditto) ;; *) continue ;; esac
    local -a ops=()
    local tdir="" want_t=0 w
    for w in "${words[@]:$((k + 1))}"; do
      if [ "$want_t" = 1 ]; then tdir="$w"; want_t=0; continue; fi
      case "$w" in
        -t|--target-directory) want_t=1 ;;
        --target-directory=*) tdir="${w#*=}" ;;
        -t?*) tdir="${w#-t}" ;;
        -*) ;;
        *) ops+=("$w") ;;
      esac
    done
    local n="${#ops[@]}" dest="" dirlike=0
    if [ -n "$tdir" ]; then
      dest="$tdir"; dirlike=1
    elif [ "$n" -ge 2 ]; then
      dest="${ops[$((n - 1))]}"; unset "ops[$((n - 1))]"
    elif [ "$n" -eq 1 ] && [ "$tool" = ln ]; then
      dest="."; dirlike=1
    else
      continue
    fi
    local dbase="${dest%/}"; dbase="${dbase##*/}"
    case "$dbase" in
      .npmrc|npmrc|.yarnrc|.yarnrc.yml|bunfig.toml) CMD_SOURCE_OVERRIDE=1; return 0 ;;
    esac
    if [[ "$dbase" == *[][?*\{]* ]] && [[ "$dbase" =~ $rc_re ]]; then
      CMD_SOURCE_OVERRIDE=1; return 0
    fi
    case "$dest" in
      \~|\~/|.|./|'$home'|'${home}'|'$home/'|'${home}/'|*/) dirlike=1 ;;
    esac
    [ "$dirlike" = 1 ] || continue
    local src base
    for src in ${ops[@]+"${ops[@]}"}; do
      src="${src%/}"; base="${src##*/}"
      case "$base" in
        .npmrc|npmrc|.yarnrc|.yarnrc.yml|bunfig.toml) CMD_SOURCE_OVERRIDE=1; return 0 ;;
      esac
      if [[ "$base" == *[][?*\{]* ]] && [[ "$base" =~ $rc_re ]]; then
        CMD_SOURCE_OVERRIDE=1; return 0
      fi
    done
  done
  return 0
}
case "$CMD" in
  *[Nn][Pp][Mm]*|*[Yy][Aa][Rr][Nn]*|*[Bb][Uu][Nn]*) cmd_source_override_scan "$CMD" ;;
esac

# Is this install flag a package-source override? npm (nopt) accepts any
# unambiguous prefix of a long option and a single leading dash, so
# --reg=, --regis, -registry and --userc count. Case-folded to fail closed.
is_source_override_flag() {
  local name="$1" hit=1 nocase_restore=0 target min bare
  local glob_targets=" registry userconfig globalconfig cafile strict-ssl proxy https-proxy"
  case "$name" in
    --*) name="${name#--}" ;;
    -?*) name="${name#-}" ;;
    *) return 1 ;;
  esac
  name="${name%%=*}"
  # Fork-free case folding: compare under nocasematch.
  shopt -q nocasematch || { nocase_restore=1; shopt -s nocasematch; }
  [[ "$name" == no-* ]] && name="${name#???}"
  if [[ "$name" == *[][?*\{]* ]]; then
    bare="${name%%[][?*\{]*}"
    [[ -n "$bare" && "$glob_targets" == *" $bare"* ]] && hit=0
  fi
  [[ "$name" == config.*registry* || "$name" == @*:registry || "$name" == ca ]] && hit=0
  for target in registry:2 userconfig:5 globalconfig:7 cafile:3 strict-ssl:8 proxy:4 https-proxy:5; do
    min="${target##*:}"; target="${target%%:*}"
    if [ "${#name}" -ge "$min" ] && [[ "$target" == "$name"* ]]; then
      hit=0
    fi
  done
  [ "$nocase_restore" = 0 ] || shopt -u nocasematch
  return "$hit"
}
[ -z "$CMD" ] && exit 0

# Honor explicit bypass — audit it.
if [ "${HQ_ALLOW_UNSAFE_INSTALL:-0}" = "1" ]; then
  HQ_ROOT="$HOOK_ROOT"
  AUDIT_DIR="$HQ_ROOT/workspace/learnings"
  mkdir -p "$AUDIT_DIR" 2>/dev/null || true
  printf '{"ts":"%s","cwd":"%s","cmd":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(pwd)" \
    "$(printf '%s' "$CMD" | hq_json_encode)" \
    >> "$AUDIT_DIR/unsafe-install-bypasses.jsonl" 2>/dev/null || true
  exit 0
fi

# Walk the command. We may have multiple statements separated by &&/;/| — check each.
# Split on common separators but keep quoted handling simple (good-enough heuristic).
# We feed each segment through the matcher.

emit_block() {
  local pm="$1" sub="$2" reason="$3"
  cat >&2 <<EOF

BLOCKED — supply-chain guard (.claude/policies/hq-pnpm-min-release-age-supply-chain.md)

  Command:  $pm $sub ...
  Why:      $reason

  Use pnpm with minimum-release-age=1440 (24h) instead:

    1. One-time fix this repo:        echo 'minimum-release-age=1440' >> .npmrc
    2. Or per-invocation:             pnpm add <pkg> --config.minimumReleaseAge=1440
       (in a repo NOT already managed by pnpm, also pass
        --config.node-linker=hoisted so pnpm keeps a flat, npm-compatible node_modules)
    3. Or workspace-wide:             add  minimumReleaseAge: 1440  to pnpm-workspace.yaml

  Installing an HQ dependency CLI (qmd, hq CLI, Claude Code)? Use the sanctioned
  pinned form from core/scripts/install-deps.allow, e.g.
    npm install -g @tobilu/qmd@2.5.3
  — the guard allows exact pins listed there. Do NOT install these unpinned.

  Emergency bypass (audited): set HQ_ALLOW_UNSAFE_INSTALL=1 in THIS hook's
  ENVIRONMENT — prefixing the assignment onto the command itself does NOT work
  (it never reaches the hook, so the block still fires). Either:
    - add  "env": { "HQ_ALLOW_UNSAFE_INSTALL": "1" }  to .claude/settings.local.json, or
    - run  export HQ_ALLOW_UNSAFE_INSTALL=1  before launching Claude Code,
  then remove it afterward (it is session-scoped, not per-command).

EOF
  exit 2
}

# Release age must be an unsigned decimal integer of at least 1440 minutes.
# Strip leading zeroes before the comparison so large values cannot overflow
# Bash arithmetic; only four-digit values reach the numeric test.
release_age_is_valid() {
  local value="$1" digits
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  while [[ "${#value}" -gt 1 && "$value" == 0* ]]; do
    value="${value#0}"
  done
  digits="${#value}"
  [ "$digits" -gt 4 ] && return 0
  [ "$digits" -eq 4 ] || return 1
  [ "$value" -ge 1440 ]
}

# Detect whether the command (or env) supplies a valid release-age gate. A
# present but invalid higher-precedence source must not fall through to a
# weaker source such as the environment or repository config.
RELEASE_AGE_CMD_PRESENT=0
has_release_age_in_cmd() {
  local token value normalized continuation_pattern found_invalid=0
  local -a tokens=()
  RELEASE_AGE_CMD_PRESENT=0
  # A shell command may continue an invocation onto the next physical line.
  # Join escaped newlines before tokenizing so a gate on the continued line is
  # validated with the same precedence as one on the first line.
  normalized="$1"
  continuation_pattern=$'\\\n'
  # Shell removes the backslash-newline pair without inserting whitespace;
  # keep that distinction so an unspaced continuation cannot invent a flag.
  normalized="${normalized//"$continuation_pattern"/}"
  read -r -a tokens <<< "$normalized"
  for token in "${tokens[@]}"; do
    case "$token" in
      \"*\") token="${token#\"}"; token="${token%\"}" ;;
      \'*\') token="${token#\'}"; token="${token%\'}" ;;
    esac
    case "$token" in
      --config.minimumReleaseAge=*|--config.minimum-release-age=*)
        RELEASE_AGE_CMD_PRESENT=1
        value="${token#*=}"
        case "$value" in
          \"*\") value="${value#\"}"; value="${value%\"}" ;;
          \'*\') value="${value#\'}"; value="${value%\'}" ;;
        esac
        release_age_is_valid "$value" || found_invalid=1
        ;;
    esac
  done
  [ "$RELEASE_AGE_CMD_PRESENT" = "1" ] && [ "$found_invalid" = "0" ]
}

RELEASE_AGE_ENV_PRESENT=0
has_release_age_in_env() {
  local value found_invalid=0
  RELEASE_AGE_ENV_PRESENT=0
  if [[ ${npm_config_minimum_release_age+x} ]]; then
    RELEASE_AGE_ENV_PRESENT=1
    value="$npm_config_minimum_release_age"
    release_age_is_valid "$value" || found_invalid=1
  fi
  if [[ ${NPM_CONFIG_MINIMUM_RELEASE_AGE+x} ]]; then
    RELEASE_AGE_ENV_PRESENT=1
    value="$NPM_CONFIG_MINIMUM_RELEASE_AGE"
    release_age_is_valid "$value" || found_invalid=1
  fi
  [ "$RELEASE_AGE_ENV_PRESENT" = "1" ] && [ "$found_invalid" = "0" ]
}

RELEASE_AGE_REPO_CACHE_FILE=""
RELEASE_AGE_REPO_CACHE_READY=0
RELEASE_AGE_REPO_CACHE_PWD=""
RELEASE_AGE_REPO_CACHE_RESULT=0
RELEASE_AGE_SESSION_ID="${HQ_HOOK_SESSION_ID:-}"

release_age_cache_init() {
  [ "$RELEASE_AGE_REPO_CACHE_READY" = "0" ] || return 0
  RELEASE_AGE_REPO_CACHE_READY=1
  if [ -z "$RELEASE_AGE_SESSION_ID" ]; then
    RELEASE_AGE_SESSION_ID="$(extract session_id)"
  fi
  case "$RELEASE_AGE_SESSION_ID" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  case "$PWD" in *$'\n'*) return 0 ;; esac
  RELEASE_AGE_REPO_CACHE_FILE="$HOOK_ROOT/workspace/orchestrator/hook-state/unsafe-package-release-age/$RELEASE_AGE_SESSION_ID"
}

release_age_cache_load() {
  local cached_pwd="" cached_result="" dir file
  [ -n "$RELEASE_AGE_REPO_CACHE_FILE" ] && [ -f "$RELEASE_AGE_REPO_CACHE_FILE" ] || return 1
  {
    IFS= read -r cached_pwd || true
    IFS= read -r cached_result || true
  } < "$RELEASE_AGE_REPO_CACHE_FILE"
  [ "$cached_pwd" = "$PWD" ] || return 1
  case "$cached_result" in 0|1) ;; *) return 1 ;; esac

  # The cache must be newer than every searched directory and config file.
  # Directory mtimes also invalidate a cached miss when a config is added.
  dir="$PWD"
  for _ in 1 2 3 4 5 6; do
    [ "$RELEASE_AGE_REPO_CACHE_FILE" -nt "$dir" ] || return 1
    for file in "$dir/.npmrc" "$dir/pnpm-workspace.yaml"; do
      if [ -e "$file" ]; then
        [ "$RELEASE_AGE_REPO_CACHE_FILE" -nt "$file" ] || return 1
      fi
    done
    [ "$dir" = "/" ] && break
    case "$dir" in
      */*) dir="${dir%/*}"; [ -n "$dir" ] || dir="/" ;;
      *) dir="." ;;
    esac
  done
  RELEASE_AGE_REPO_CACHE_RESULT="$cached_result"
  return 0
}

release_age_cache_save() {
  local tmp
  [ -n "$RELEASE_AGE_REPO_CACHE_FILE" ] || return 0
  tmp="$RELEASE_AGE_REPO_CACHE_FILE.tmp.$$"
  (umask 077; mkdir -p "${RELEASE_AGE_REPO_CACHE_FILE%/*}" 2>/dev/null) || return 0
  if printf '%s\n%s\n' "$PWD" "$RELEASE_AGE_REPO_CACHE_RESULT" > "$tmp" 2>/dev/null \
     && mv -f "$tmp" "$RELEASE_AGE_REPO_CACHE_FILE" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
}

has_release_age_in_repo() {
  # Walk up to 6 levels looking for a .npmrc with minimum-release-age or
  # a pnpm-workspace.yaml with minimumReleaseAge. A configured but invalid
  # value must not count as satisfying the supply-chain gate. Reuse the result
  # for this session and cwd until a searched directory or config file changes.
  local dir line value found=0 found_invalid=0
  release_age_cache_init
  if [ "$RELEASE_AGE_REPO_CACHE_PWD" = "$PWD" ]; then
    [ "$RELEASE_AGE_REPO_CACHE_RESULT" = "1" ] && return 0
    return 1
  fi
  if release_age_cache_load; then
    RELEASE_AGE_REPO_CACHE_PWD="$PWD"
    [ "$RELEASE_AGE_REPO_CACHE_RESULT" = "1" ] && return 0
    return 1
  fi

  dir="$PWD"
  for _ in 1 2 3 4 5 6; do
    if [ -f "$dir/.npmrc" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^[[:space:]]*minimum-release-age[[:space:]]*=(.*)$ ]]; then
          found=1
          value="${BASH_REMATCH[1]}"
          value="${value#"${value%%[![:space:]]*}"}"
          value="${value%"${value##*[![:space:]]}"}"
          case "$value" in
            \"*\") value="${value#\"}"; value="${value%\"}" ;;
            \'*\') value="${value#\'}"; value="${value%\'}" ;;
          esac
          release_age_is_valid "$value" || found_invalid=1
        fi
      done < "$dir/.npmrc"
    fi
    if [ -f "$dir/pnpm-workspace.yaml" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^[[:space:]]*minimumReleaseAge[[:space:]]*:(.*)$ ]]; then
          found=1
          value="${BASH_REMATCH[1]}"
          # YAML permits an inline comment after a scalar. Trim it before
          # validating the configured value.
          value="${value%%[[:space:]]#*}"
          value="${value#"${value%%[![:space:]]*}"}"
          value="${value%"${value##*[![:space:]]}"}"
          case "$value" in
            \"*\") value="${value#\"}"; value="${value%\"}" ;;
            \'*\') value="${value#\'}"; value="${value%\'}" ;;
          esac
          release_age_is_valid "$value" || found_invalid=1
        fi
      done < "$dir/pnpm-workspace.yaml"
    fi
    [ "$dir" = "/" ] && break
    case "$dir" in
      */*) dir="${dir%/*}"; [ -n "$dir" ] || dir="/" ;;
      *) dir="." ;;
    esac
  done
  RELEASE_AGE_REPO_CACHE_PWD="$PWD"
  RELEASE_AGE_REPO_CACHE_RESULT=0
  if [ "$found" = "1" ] && [ "$found_invalid" = "0" ]; then
    RELEASE_AGE_REPO_CACHE_RESULT=1
  fi
  release_age_cache_save
  [ "$RELEASE_AGE_REPO_CACHE_RESULT" = "1" ]
}

gate_configured() {
  has_release_age_in_cmd "$1" && return 0
  [ "$RELEASE_AGE_CMD_PRESENT" = "1" ] && return 1
  has_release_age_in_env && return 0
  [ "$RELEASE_AGE_ENV_PRESENT" = "1" ] && return 1
  has_release_age_in_repo && return 0
  return 1
}

# Drop shell redirection tokens from an argument list.
#
# `2>&1`, `>file`, `>>file`, `<file`, `&>file`, `2>/dev/null` and the `N>&M`
# forms are shell plumbing, not arguments to the package manager. Every token
# loop below classifies anything not starting with '-' as a positional package
# name, so an install written as `pnpm add -g <pkg> 2>&1` used to fail the
# "every positional token is allow-listed" check and get blocked — which killed
# the first-party override in practice, since agents almost always append
# `2>&1 | tail`. A bare operator (`>`, `2>>`, `<`) also consumes the token that
# follows it as its target.
strip_redirection_tokens() {
  local out="" tok skip_next=0
  for tok in $1; do
    if [ "$skip_next" = "1" ]; then
      skip_next=0
      continue
    fi
    if [[ "$tok" =~ ^([0-9]+|\&)?(\>\>?|\<) ]]; then
      # Operator with no target attached — the next token is its target.
      [[ "$tok" =~ ^([0-9]+|\&)?(\>\>?|\<)\&?$ ]] && skip_next=1
      continue
    fi
    out="$out $tok"
  done
  STRIP_REDIRECTION_RESULT="${out# }"
}

# Drop value-taking flags AND their separate value token from an argument list.
#
# npm/pnpm/yarn/bun accept flags that consume the FOLLOWING token as their value
# (`--prefix /path`, `--registry <url>`, `--cache <dir>`, `--userconfig <f>`, …).
# Every token loop below classifies anything not starting with '-' as a
# positional package name, so a bare value like `~/.local` (from
# `npm i -g --prefix ~/.local <pkg>`) was misread as an untrusted package
# and BLOCKED an otherwise sanctioned first-party / allow-listed global install.
# The `--flag=value` form is already a single '-'-prefixed token and needs no
# handling; this only collapses the space-separated form. Boolean flags such as
# `-g` / `--global` are NOT in the set, so global-install detection still works.
strip_flag_values() {
  local out="" tok skip_next=0
  for tok in $1; do
    if [ "$skip_next" = "1" ]; then
      skip_next=0
      continue
    fi
    case "$tok" in
      --prefix|-C|--registry|--cache|--userconfig|--globalconfig|--dir|--cwd|--store-dir|--virtual-store-dir|--node-linker|--otp|-w|--workspace)
        skip_next=1
        continue
        ;;
    esac
    out="$out $tok"
  done
  STRIP_FLAG_VALUES_RESULT="${out# }"
}

# Has at least one positional, non-flag argument after the subcommand?
# Args: "<rest-of-command-after-subcmd>"
has_positional_pkg_arg() {
  local rest="$1"
  # Strip leading whitespace.
  rest="${rest#"${rest%%[![:space:]]*}"}"
  [ -z "$rest" ] && return 1
  # Scan tokens; first token that doesn't start with '-' is a positional pkg.
  for tok in $rest; do
    case "$tok" in
      -*) continue ;;
      *) return 0 ;;
    esac
  done
  return 1
}

# ── Sanctioned global CLI allow-list (core/scripts/install-deps.allow) ────────
ALLOW_FILE="$HOOK_ROOT/core/scripts/install-deps.allow"

# Does one positional token match an allow entry?
# Args: "<token>"  — e.g. @tobilu/qmd@2.5.3
allow_matches_token() {
  local tok="$1" name ver entry ename ever
  [ -f "$ALLOW_FILE" ] || return 1
  # Split token into name / version: the LAST '@' that is not at position 0.
  # Scoped names start with '@', so strip that first.
  local body="$tok" prefix=""
  if [[ "$body" == @* ]]; then prefix="@"; body="${body#@}"; fi
  if [[ "$body" != *@* ]]; then
    return 1   # bare name — never allowed
  fi
  name="${prefix}${body%@*}"
  ver="${body##*@}"
  [ -z "$ver" ] && return 1
  case "$ver" in
    latest|next|beta|alpha|canary|rc|'*'|x) return 1 ;;   # dist-tags / wildcards
  esac
  while IFS= read -r entry || [ -n "$entry" ]; do
    entry="${entry%%#*}"
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [ -z "$entry" ] && continue
    local ebody="$entry" eprefix=""
    if [[ "$ebody" == @* ]]; then eprefix="@"; ebody="${ebody#@}"; fi
    [[ "$ebody" == *@* ]] || continue
    ename="${eprefix}${ebody%@*}"
    ever="${ebody##*@}"
    [ "$ename" = "$name" ] || continue
    if [ "$ever" = "*" ] || [ "$ever" = "$ver" ]; then
      return 0
    fi
  done < "$ALLOW_FILE"
  return 1
}

# Is this a GLOBAL install whose every positional package token is allow-listed?
# Args: "<rest-of-command-after-subcmd>"
allowed_global_install() {
  local rest="$1" tok is_global=0 npos=0
  [ -f "$ALLOW_FILE" ] || return 1
  for tok in $rest; do
    case "$tok" in
      -g|--global) is_global=1 ;;
      -*) ;;
      *)
        npos=$((npos+1))
        allow_matches_token "$tok" || return 1
        ;;
    esac
  done
  [ "$is_global" = "1" ] && [ "$npos" -gt 0 ]
}

# Remove leading launcher wrappers so `mise exec -- bun install x`,
# `env FOO=1 npm i x` or `npx pnpm add x` are matched like the bare command.
# Each pass must shrink the segment, with a fixed pass cap, so a crafted
# segment cannot spin.
skip_word() {
  SKIP_WORD_RESULT="${1#"${1%%[![:space:]]*}"}"
  case "$SKIP_WORD_RESULT" in
    *[[:space:]]*) SKIP_WORD_RESULT="${SKIP_WORD_RESULT#*[[:space:]]}" ;;
    *) SKIP_WORD_RESULT="" ;;
  esac
  SKIP_WORD_RESULT="${SKIP_WORD_RESULT#"${SKIP_WORD_RESULT%%[![:space:]]*}"}"
}

strip_launcher_wrappers() {
  local seg="$1" before pass=0 w w2 inner guard
  local mise_re='^[^[:space:]]+[[:space:]]+(exec|x)([[:space:]]+[^[:space:]]+)*[[:space:]]+--[[:space:]]+(.*)$'
  local assign_re='^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]'
  local -a words=()
  STRIP_LAUNCHER_XARGS=0
  seg="${seg#"${seg%%[![:space:]]*}"}"
  while [ "$pass" -lt 8 ]; do
    pass=$((pass + 1))
    before="$seg"
    # A quoted or backslash-escaped first word ("npm", 'env', \npm) runs
    # the same program; unwrap it so the match below sees the bare name.
    if [[ "$seg" =~ ^(\\|\"|\')([A-Za-z0-9_./@+-]+)(\"|\')?([[:space:]]|$) ]]; then
      case "${BASH_REMATCH[1]}:${BASH_REMATCH[3]}" in
        '\:'|'":"'|"':'") seg="${BASH_REMATCH[2]}${seg:$(( ${#BASH_REMATCH[1]} + ${#BASH_REMATCH[2]} + ${#BASH_REMATCH[3]} ))}" ;;
      esac
    fi
    words=()
    read -r -a words <<< "$seg"
    w="${words[0]:-}"
    w="${w##*/}"
    w2="${words[1]:-}"
    case "$w" in
      mise)
        if [ "$w2" = "exec" ] || [ "$w2" = "x" ]; then
          IFS= read -r inner <<< "$seg" || :
          if [[ "$inner" =~ $mise_re ]]; then
            # The command starts after the FIRST `--`; later `--` tokens
            # belong to the command itself.
            inner="${inner#*[[:space:]]--[[:space:]]}"
            seg="${inner#"${inner%%[![:space:]]*}"}${seg:${#BASH_REMATCH[0]}}"
          fi
        fi
        ;;
      env)
        skip_word "$seg"; seg="$SKIP_WORD_RESULT"
        guard=0
        while [ "$guard" -lt 64 ] && [ -n "$seg" ]; do
          guard=$((guard + 1))
          case "$seg" in
            -S[[:space:]]*|--split-string[[:space:]]*|-S[!-[:space:]]*|--split-string=*)
              # -S takes the command as one (usually quoted) string.
              case "$seg" in
                --split-string=*) seg="${seg#--split-string=}" ;;
                -S[[:space:]]*|--split-string[[:space:]]*) skip_word "$seg"; seg="$SKIP_WORD_RESULT" ;;
                *) seg="${seg#-S}" ;;
              esac
              case "$seg" in
                \'*) seg="${seg#\'}"; seg="${seg/\'/ }" ;;
                \"*) seg="${seg#\"}"; seg="${seg/\"/ }" ;;
              esac
              break ;;
            -u[[:space:]]*|-C[[:space:]]*|--unset[[:space:]]*|--chdir[[:space:]]*)
              skip_word "$seg"; skip_word "$SKIP_WORD_RESULT"; seg="$SKIP_WORD_RESULT" ;;
            -*)
              skip_word "$seg"; seg="$SKIP_WORD_RESULT" ;;
            *)
              if [[ "$seg" =~ $assign_re ]]; then
                skip_word "$seg"; seg="$SKIP_WORD_RESULT"
              else
                break
              fi ;;
          esac
        done
        ;;
      npx|pnpx|bunx|command|exec|nohup|time|sudo|doas|nice|timeout|stdbuf|caffeinate|xargs|corepack|ionice|chrt|taskset|arch|chronic|unbuffer)
        [ "$w" != xargs ] || STRIP_LAUNCHER_XARGS=1
        skip_word "$seg"; seg="$SKIP_WORD_RESULT"
        guard=0
        while [ "$guard" -lt 64 ] && [[ "$seg" == -* ]]; do
          guard=$((guard + 1))
          # sudo combined short flags (-iu x, -Hu x): the first value-taking
          # letter takes the rest of the token, or the next word when it is
          # the last letter.
          if [ "$w" = sudo ] && [[ "$seg" =~ ^-([A-Za-z]+)([[:space:]]|$) ]]; then
            local flags="${BASH_REMATCH[1]}" k
            for ((k = 0; k < ${#flags}; k++)); do
              case "${flags:$k:1}" in
                u|g|C|D|h|p|r|t|U|T)
                  if [ "$k" -eq $((${#flags} - 1)) ]; then
                    skip_word "$seg"; seg="$SKIP_WORD_RESULT"
                  fi
                  break ;;
              esac
            done
            skip_word "$seg"; seg="$SKIP_WORD_RESULT"
            continue
          fi
          case "$w:$seg" in
            # Value-taking options consume the following word.
            sudo:-u[[:space:]]*|sudo:-g[[:space:]]*|sudo:-C[[:space:]]*|sudo:-D[[:space:]]*|doas:-u[[:space:]]*|npx:-p[[:space:]]*|npx:--package[[:space:]]*|exec:-a[[:space:]]*|nice:-n[[:space:]]*|timeout:-s[[:space:]]*|timeout:-k[[:space:]]*|timeout:--signal[[:space:]]*|timeout:--kill-after[[:space:]]*|xargs:-[IdEnLPs][[:space:]]*|xargs:-a[[:space:]]*|ionice:-[cn][[:space:]]*|taskset:-c[[:space:]]*|stdbuf:-[oei][[:space:]]*)
              skip_word "$seg"; seg="$SKIP_WORD_RESULT" ;;
          esac
          skip_word "$seg"; seg="$SKIP_WORD_RESULT"
        done
        # timeout and taskset take a positional DURATION / mask before the
        # command; chrt takes a priority.
        case "$w" in
          timeout|chrt|taskset)
            if [[ "$seg" =~ ^[0-9.]+[smhd]?([[:space:]]|$) ]] || { [ "$w" = taskset ] && [[ "$seg" =~ ^0?x?[0-9a-fA-F,-]+[[:space:]] ]]; }; then
              skip_word "$seg"; seg="$SKIP_WORD_RESULT"
            fi ;;
        esac
        # npx npm@10 install x: the launched manager may carry a version.
        if [[ "$seg" =~ ^(npm|yarn|bun|pnpm)@[^[:space:]]*([[:space:]].*)?$ ]]; then
          seg="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
        fi
        ;;
      pnpm|yarn|npm|bun)
        # pnpm/yarn dlx, pnpm/yarn/npm/bun exec, bun x and volta-style
        # launchers run the following command as a child.
        case "$w:$w2" in
          yarn:npx|yarn:pnpx|yarn:bunx|yarn:npm|yarn:pnpm|yarn:bun)
            # `yarn <bin>` runs a binary; these binaries are launchers or
            # package managers themselves.
            skip_word "$seg"; seg="$SKIP_WORD_RESULT" ;;
          pnpm:dlx|yarn:dlx|pnpm:exec|yarn:exec|npm:exec|bun:exec|bun:x|npm:x|pnpm:x)
            skip_word "$seg"; skip_word "$SKIP_WORD_RESULT"; seg="$SKIP_WORD_RESULT"
            guard=0
            while [ "$guard" -lt 64 ] && [[ "$seg" == -* ]]; do
              guard=$((guard + 1))
              case "$seg" in
                -c[[:space:]]*|--call[[:space:]]*|--call=*)
                  # -c/--call take the command as one (usually quoted)
                  # string; analyse that string as the command.
                  case "$seg" in
                    --call=*) seg="${seg#--call=}" ;;
                    *) skip_word "$seg"; seg="$SKIP_WORD_RESULT" ;;
                  esac
                  case "$seg" in
                    \'*) seg="${seg#\'}"; seg="${seg%%\'*}" ;;
                    \"*) seg="${seg#\"}"; seg="${seg%%\"*}" ;;
                  esac
                  break ;;
                -p[[:space:]]*|--package[[:space:]]*|-w[[:space:]]*|--workspace[[:space:]]*)
                  skip_word "$seg"; seg="$SKIP_WORD_RESULT" ;;
              esac
              skip_word "$seg"; seg="$SKIP_WORD_RESULT"
            done
            if [[ "$seg" =~ ^(npm|yarn|bun|pnpm)@[^[:space:]]*([[:space:]].*)?$ ]]; then
              seg="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
            fi ;;
        esac
        ;;
      volta)
        if [ "$w2" = "run" ]; then
          skip_word "$seg"; skip_word "$SKIP_WORD_RESULT"; seg="$SKIP_WORD_RESULT"
          guard=0
          while [ "$guard" -lt 64 ] && [[ "$seg" == -* ]]; do
            guard=$((guard + 1))
            case "$seg" in
              --node[[:space:]]*|--npm[[:space:]]*|--yarn[[:space:]]*|--pnpm[[:space:]]*|--env[[:space:]]*)
                skip_word "$seg"; seg="$SKIP_WORD_RESULT" ;;
            esac
            skip_word "$seg"; seg="$SKIP_WORD_RESULT"
          done
        fi
        ;;
    esac
    guard=0
    while [ "$guard" -lt 64 ] && [[ "$seg" =~ $assign_re ]]; do
      guard=$((guard + 1))
      skip_word "$seg"; seg="$SKIP_WORD_RESULT"
    done
    [ "$seg" != "$before" ] || break
  done
  # The last allowed pass still stripped a wrapper, so more may remain that
  # the guard never inspected. Fail closed.
  STRIP_LAUNCHER_CAPPED=0
  if [ "$pass" -ge 8 ] && [ "$seg" != "$before" ]; then
    STRIP_LAUNCHER_CAPPED=1
  fi
  STRIP_LAUNCHER_RESULT="$seg"
}

check_segment() {
  local seg="$1" depth="${2:-0}"
  # Nothing to check unless a package-manager name appears once quotes and
  # backslashes are removed (this also covers bash -c / eval script text).
  local probe="${seg//[\"\'\\]/}"
  case "$probe" in
    *npm*|*yarn*|*bun*) ;;
    *) return 0 ;;
  esac
  # Strip ALL leading whitespace (spaces, tabs, newlines).
  seg="${seg#"${seg%%[![:space:]]*}"}"

  # Strip reserved words and grouping that can start a command:
  # { ! if then elif else while until do coproc.
  local kw_pass=0
  while [ "$kw_pass" -lt 16 ]; do
    case "$seg" in
      "{"[[:space:]]*|"!"[[:space:]]*|if[[:space:]]*|then[[:space:]]*|elif[[:space:]]*|else[[:space:]]*|while[[:space:]]*|until[[:space:]]*|do[[:space:]]*|coproc[[:space:]]*)
        seg="${seg#*[[:space:]]}"
        seg="${seg#"${seg%%[![:space:]]*}"}"
        ;;
      function[[:space:]]*)
        # `function name [()] {`: drop the keyword and the name.
        seg="${seg#function}"
        seg="${seg#"${seg%%[![:space:]]*}"}"
        seg="${seg#"${seg%%[[:space:]]*}"}"
        seg="${seg#"${seg%%[![:space:]]*}"}"
        ;;
      *) break ;;
    esac
    kw_pass=$((kw_pass + 1))
  done

  # Strip a leading env-assignment prefix (FOO=bar BAR=baz pm install ...).
  # Every iteration must shrink the segment. A prefix the strip cannot
  # consume (feedback_3d0f49f4: newline-separated assignments spun this loop
  # until the 300 s harness timeout; feedback_f692e290: orphaned copies kept
  # spinning a core each) ends the strip instead of looping forever.
  local seg_before
  local orig_seg="$seg"
  if [[ "$seg" =~ ^env[[:space:]] ]]; then
    local env_sub_re='^(.*)(\$\([^()]*\)|`[^`]*`)(.*)$' env_sub_pass=0
    while [ "$env_sub_pass" -lt 16 ] && [[ "$seg" =~ $env_sub_re ]]; do
      seg="${BASH_REMATCH[1]} ${BASH_REMATCH[3]}"
      env_sub_pass=$((env_sub_pass + 1))
    done
  fi
  local seg_assign_re='^([A-Za-z_][A-Za-z0-9_]*|[Nn][Pp][Mm]_[Cc][Oo][Nn][Ff][Ii][Gg]_@[^[:space:]=]*)=[^[:space:]]*[[:space:]]'
  while [[ "$seg" =~ $seg_assign_re ]]; do
    seg_before="$seg"
    seg="${seg#*[[:space:]]}"
    seg="${seg#"${seg%%[![:space:]]*}"}"
    [ "$seg" != "$seg_before" ] || break
  done

  # Strip launcher wrappers that run the package manager as a child command
  # (feedback_a041edbc): mise exec/x ... --, env [opts] [VAR=val]..., npx,
  # bunx, pnpm/yarn dlx, command, exec, nohup, time.
  strip_launcher_wrappers "$seg"
  seg="$STRIP_LAUNCHER_RESULT"
  if [ "${STRIP_LAUNCHER_CAPPED:-0}" = 1 ]; then
    emit_block "launcher" "wrapper" "more than 8 stacked launcher wrappers; the guard cannot see the command they run."
  fi

  # eval runs its arguments as a command line.
  case "$seg" in
    eval[[:space:]]*)
      local eval_line
      eval_line="$(LC_ALL=C awk -v mode=evalargs "$SHELL_SPLIT_AWK" <<< "$seg")"
      analyze_command "$eval_line" $((depth + 1))
      return 0
      ;;
  esac
  # A shell: analyze the -c script operand as a command line. Option forms
  # such as -lc, -c -- 'x', -c -e 'x', --norc -c 'x', -o errexit -c 'x' and
  # /bin/bash are handled by mode=shellc. A shell without -c reads stdin,
  # which the splitter already checked.
  local first_word="${seg%%[[:space:]]*}"
  case "${first_word##*/}" in
    find)
      # find ... -exec|-execdir|-ok|-okdir <command> ; or +
      local -a find_words=()
      read -r -a find_words <<< "$seg"
      local find_word find_cmd="" find_in=0
      for find_word in ${find_words[@]+"${find_words[@]}"}; do
        if [ "$find_in" = 1 ]; then
          case "$find_word" in
            ';'|'\;'|'+')
              find_in=0
              [ -n "$find_cmd" ] && analyze_command "$find_cmd" $((depth + 1))
              find_cmd=""
              continue
              ;;
          esac
          find_cmd="${find_cmd:+$find_cmd }$find_word"
        else
          case "$find_word" in -exec|-execdir|-ok|-okdir) find_in=1 ;; esac
        fi
      done
      [ -n "$find_cmd" ] && analyze_command "$find_cmd" $((depth + 1))
      return 0
      ;;
    watch)
      # watch [options] <command...> runs its arguments through sh -c.
      local -a watch_words=()
      read -r -a watch_words <<< "$seg"
      local wk=1
      while [ "$wk" -lt "${#watch_words[@]}" ]; do
        case "${watch_words[$wk]}" in
          -n|--interval|-q|--equexit) wk=$((wk + 2)) ;;
          -*) wk=$((wk + 1)) ;;
          *) break ;;
        esac
      done
      if [ "$wk" -lt "${#watch_words[@]}" ]; then
        local watch_line
        watch_line="$(LC_ALL=C awk -v mode=evalargs "$SHELL_SPLIT_AWK" <<< "watch ${watch_words[*]:$wk}")"
        analyze_command "$watch_line" $((depth + 1))
      fi
      return 0
      ;;
    flock|script|parallel)
      # flock(1): [opts] <lockfile> <cmd...> | flock(1) <lockfile> -c <script>
      # script [opts] <file> <cmd...> (BSD) | script -c <script> <file> (Linux)
      # parallel [opts] <cmd...> ::: <args...>
      local -a lw=()
      read -r -a lw <<< "$seg"
      local lk=1 lname="${first_word##*/}" lcmd="" lword
      while [ "$lk" -lt "${#lw[@]}" ]; do
        case "$lname:${lw[$lk]}" in
          *:-c|*:--command)
            lk=$((lk + 1))
            local lscript
            lscript="$(LC_ALL=C awk -v mode=evalargs "$SHELL_SPLIT_AWK" <<< "x ${lw[*]:$lk}")"
            analyze_command "$lscript" $((depth + 1))
            return 0
            ;;
          flock:-w|flock:--timeout|flock:-E|flock:--conflict-exit-code|script:-t|script:-T|script:-F|script:-I|script:-O|script:-B|script:-E|parallel:-j|parallel:--jobs|parallel:-S|parallel:--sshlogin)
            lk=$((lk + 2)) ;;
          *:-*) lk=$((lk + 1)) ;;
          *) break ;;
        esac
      done
      # flock(1)/script(1) take a lock/typescript file before the command.
      [ "$lname" = parallel ] || lk=$((lk + 1))
      while [ "$lk" -lt "${#lw[@]}" ]; do
        lword="${lw[$lk]}"
        case "$lword" in
          ':::'|'::::'|':::+') : ;;  # parallel separators; the arguments are appended
          -c|--command)
            if [ "$lname" = "flock" ] && [ -z "$lcmd" ]; then
              lk=$((lk + 1))
              local lscript2
              lscript2="$(LC_ALL=C awk -v mode=evalargs "$SHELL_SPLIT_AWK" <<< "x ${lw[*]:$lk}")"
              analyze_command "$lscript2" $((depth + 1))
              return 0
            fi
            lcmd="${lcmd:+$lcmd }$lword" ;;
          *) lcmd="${lcmd:+$lcmd }$lword" ;;
        esac
        lk=$((lk + 1))
      done
      [ -n "$lcmd" ] && analyze_command "$lcmd" $((depth + 1))
      return 0
      ;;
    bash|sh|zsh|dash|ksh|ash|fish|tcsh|csh|busybox)
      local inner
      inner="$(LC_ALL=C awk -v mode=shellc "$SHELL_SPLIT_AWK" <<< "$seg")"
      [ -n "$inner" ] && analyze_command "$inner" $((depth + 1))
      return 0
      ;;
  esac

  # `yarn global add <pkg>` is a global install: inspect it as `yarn add -g`.
  if [[ "$seg" =~ ^yarn[[:space:]] ]]; then
    local yg_re='^(yarn([[:space:]]+[^[:space:]]+)*)[[:space:]]+global[[:space:]]+add([[:space:]]+(.*)|$)'
    if [[ "$seg" =~ $yg_re ]]; then
      seg="${BASH_REMATCH[1]} add -g ${BASH_REMATCH[4]:-}"
    fi
  fi

  # Global options before the subcommand (`npm --prefix /tmp i x`): move
  # them after it so the matcher below sees `<pm> <subcmd>`.
  if [[ "$seg" =~ ^(npm|yarn|bun|pnpm)[[:space:]]+- ]]; then
    local -a pm_words=() pm_opts=()
    read -r -a pm_words <<< "$seg"
    local pk=1 pm_word pm_prev_opt=0
    while [ "$pk" -lt "${#pm_words[@]}" ]; do
      pm_word="${pm_words[$pk]}"
      case "$pm_word" in
        install|i|in|ins|inst|insta|instal|isnt|isnta|isntal|isntall|it|install-test|add|ci) break ;;
        -*)
          pm_opts+=("$pm_word")
          case "$pm_word" in *=*) pm_prev_opt=0 ;; *) pm_prev_opt=1 ;; esac
          ;;
        *)
          [ "$pm_prev_opt" = 1 ] || break
          pm_opts+=("$pm_word"); pm_prev_opt=0
          ;;
      esac
      pk=$((pk + 1))
    done
    if [ "$pk" -lt "${#pm_words[@]}" ]; then
      case "${pm_words[$pk]}" in
        install|i|in|ins|inst|insta|instal|isnt|isnta|isntal|isntall|it|install-test|add|ci)
          seg="${pm_words[0]} ${pm_words[$pk]} ${pm_opts[*]+"${pm_opts[*]}"} ${pm_words[*]:$((pk + 1))}"
          ;;
      esac
    fi
  fi

  # Match: <pm> <subcmd> <rest>
  # pm in {npm, yarn, bun, pnpm}; sub in {install, i, add, ci}.
  # NOTE: no `$` end anchor — `rest` may span multiple lines (heredocs); we
  # only care that the segment STARTS with the pm command.
  local pm="" sub="" rest=""
  # Subcommand aliases (npm in/ins/isntall/it/install-test, ...) count as
  # install; the subcommand must be a whole word (`npm init` is not `npm i`).
  if [[ "$seg" =~ ^(npm|yarn|bun|pnpm)[[:space:]]+(install|i|in|ins|inst|insta|instal|isnt|isnta|isntal|isntall|it|install-test|add|ci)([[:space:]]+(.*)|$) ]]; then
    pm="${BASH_REMATCH[1]}"
    sub="${BASH_REMATCH[2]}"
    case "$sub" in
      ci|add|i) ;;
      *) sub=install ;;
    esac
    rest="${BASH_REMATCH[4]:-}"
    # `rest` may include trailing content from later lines (heredoc body, etc.) —
    # we only need the FIRST line for positional-arg detection.
    # (read takes the first line in linear time; ${rest%%<newline>*} is
    # quadratic on a long single-line payload.)
    IFS= read -r rest <<< "$rest" || :
    # Redirections are shell plumbing, never package arguments. Strip them once
    # here so every token loop below (hydration detection, trusted-scope check,
    # allow-list check) sees the same package-only argument list.
    strip_redirection_tokens "$rest"
    rest="$STRIP_REDIRECTION_RESULT"
    # A flag that changes where the package manager fetches from, or which
    # config it reads, voids both shortcuts below (trusted scope and the
    # pinned allowlist): a reviewed name or pin only means the package from
    # the default registry. Checked before strip_flag_values drops the
    # space-separated forms.
    # Env vars, config writes and `config set` elsewhere in the command
    # (CMD_SOURCE_OVERRIDE) count too.
    SOURCE_OVERRIDE="${CMD_SOURCE_OVERRIDE:-0}"
    # HOME / XDG_CONFIG_HOME / proxy / CA assignments that prefix this
    # install, directly or through env / sudo / other launchers.
    local -a pre_words=()
    read -r -a pre_words <<< "$orig_seg"
    local pre_w pre_gen_re="^[\"']?(${GENERAL_ENV_RE})=" pre_restore=0
    shopt -q nocasematch || { pre_restore=1; shopt -s nocasematch; }
    for pre_w in ${pre_words[@]+"${pre_words[@]}"}; do
      case "${pre_w##*/}" in npm|pnpm|yarn|bun) break ;; esac
      case "$pre_w" in
        *=*) [[ "$pre_w" =~ $pre_gen_re ]] && SOURCE_OVERRIDE=1 ;;
      esac
    done
    [ "$pre_restore" = 0 ] || shopt -u nocasematch
    local -a so_words=()
    read -r -a so_words <<< "$rest"
    for tok in ${so_words[@]+"${so_words[@]}"}; do
      case "$tok" in
        -*) is_source_override_flag "$tok" && SOURCE_OVERRIDE=1 ;;
      esac
    done
    # Collapse value-taking flags (`--prefix /path`, `--registry <url>`, …) so a
    # space-separated value is never mistaken for a positional package name.
    strip_flag_values "$rest"
    rest="$STRIP_FLAG_VALUES_RESULT"
    # `... | xargs npm i` takes its package names from stdin, which the hook
    # cannot see. Treat them as one unknown, untrusted package.
    if [ "${STRIP_LAUNCHER_XARGS:-0}" = 1 ]; then
      rest="${rest:+$rest }xargs-stdin-package"
    fi
  else
    return 0
  fi

  # yarn: 'yarn install' / 'yarn' alone is hydration. 'yarn add <pkg>' is what we want to block.
  # 'yarn ci' is not a thing; treat as no-op match.
  if [ "$pm" = "yarn" ]; then
    case "$sub" in
      add) ;;
      *) return 0 ;;
    esac
  fi

  # npm/bun/pnpm ci is always lockfile-strict, safe.
  if [ "$sub" = "ci" ]; then
    return 0
  fi

  # 'install' / 'i' with no positional pkg arg = lockfile hydration, allowed.
  if [ "$sub" = "install" ] || [ "$sub" = "i" ]; then
    if ! has_positional_pkg_arg "$rest"; then
      return 0
    fi
  fi

  # First-party trust allowlist: when EVERY positional package arg belongs to a
  # trusted npm scope (default: @indigoai-us — HQ's own CLI/packs), the
  # release-age gate does not apply. Override scopes (space-separated) via
  # HQ_TRUSTED_INSTALL_SCOPES. A mixed install (trusted + third-party) still blocks.
  local trusted_scopes="${HQ_TRUSTED_INSTALL_SCOPES:-@indigoai-us}"
  local all_trusted=1 saw_pkg=0 tok scope
  for tok in $rest; do
    case "$tok" in
      -*) continue ;;
      *)
        saw_pkg=1
        local tok_trusted=0
        for scope in $trusted_scopes; do
          case "$tok" in
            "$scope"/*) tok_trusted=1 ;;
          esac
        done
        [ "$tok_trusted" = "1" ] || all_trusted=0
        ;;
    esac
  done
  if [ "$saw_pkg" = "1" ] && [ "$all_trusted" = "1" ] && [ "${SOURCE_OVERRIDE:-0}" = "0" ]; then
    return 0
  fi

  # Sanctioned HQ CLI deps: global install, every pkg pinned + allow-listed.
  if [ "${SOURCE_OVERRIDE:-0}" = "0" ] && allowed_global_install "$rest"; then
    return 0
  fi

  # At this point we have <pm> <sub> <pkg> (or pnpm add etc.) — must enforce.
  case "$pm" in
    npm|yarn|bun)
      emit_block "$pm" "$sub" "npm/yarn/bun do not honor pnpm minimumReleaseAge. Switch to pnpm."
      ;;
    pnpm)
      if gate_configured "$seg"; then
        return 0
      fi
      emit_block "pnpm" "$sub" "no minimum-release-age configured in .npmrc, pnpm-workspace.yaml, env, or command flags."
      ;;
  esac
}

# Quote-aware command splitting (feedback_03770784).
#
# Earlier versions exited 0 for the WHOLE command when it started with a
# text-wrapping word (echo, printf, cat, git commit, gh pr create, bash -c,
# ...) or contained `<<`, because the operator splitter was not quote-aware.
# That let `echo x | npm install pkg` or `git commit -m x; npm i pkg` through.
#
# SHELL_SPLIT_AWK parses the command once, over a character array so long
# inputs stay linear, and prints the command units that name a package
# manager, separated by \x01:
#   - splits on unquoted ; & | ( ) and newlines; keeps >& &> >| redirections;
#   - never splits inside '...', $'...' (where \' is escaped), "..." or after
#     a backslash; backslash-newline joins lines; # starts a comment;
#   - $( ), backticks and ${ } are parsed recursively, also inside "..." and
#     inside unquoted heredoc bodies, so their commands become units too;
#   - $(( )) and (( )) are arithmetic, so << inside them is not a heredoc;
#   - heredoc bodies are skipped (quoted delimiters keep them inert text);
#   - each unit is printed raw and, when different, with its first words
#     dequoted (n''pm, \npm, "npm");
#   - text a shell reads from stdin (`| bash`, `bash <<< ...`, `bash <<EOF`)
#     is printed with a \x02 prefix and analyzed again as a command.
# An unterminated quote keeps the rest of the payload inside that quote.
# check_segment only matches a package manager at the START of a unit, so
# `echo "a; npm i x"` is one unit that starts with echo.
#
# mode=shellc prints the script operand of `bash [opts] -c [opts] [--] <script>`;
# mode=evalargs prints the command line `eval <args>` runs.
# Out of scope: interpreters that spawn a shell themselves (python -c
# "os.system(...)", node -e "child_process...").
DELIM=$'\x01'
SHELL_SPLIT_AWK='
function sl(a, b,    t, k) {
  if (b < a) return ""
  if (b - a < 256) { t = ""; for (k = a; k <= b; k++) t = t C[k]; return t }
  return substr(s, a, b - a + 1)
}
function relevant(t) {
  gsub(/["\\\047]/, "", t)
  return t ~ /npm|yarn|bun/
}
function emitscript(t) {
  if (relevant(t)) addunit("\002" t)
}
function skipparen(k,    d) {
  d = 0
  while (k <= N) {
    if (C[k] == "(") d++
    else if (C[k] == ")") { d--; if (d == 0) return k + 1 }
    k++
  }
  return N + 1
}
function arith(k,    d) {
  d = 2
  while (k <= N) {
    if (C[k] == "(") d++
    else if (C[k] == ")") { d--; if (d == 0) return k + 1 }
    k++
  }
  return N + 1
}
# Last path component; a regex like /.*\// is quadratic on long words.
function basename(t,    p) {
  while ((p = index(t, "/")) > 0) t = substr(t, p + 1)
  return t
}
function hexv(c) { return index("0123456789abcdef", tolower(c)) - 1 }
# Decode an ANSI-C quoted body starting at j; sets AEND past the closing quote.
function ansi(j, lim,    w, c, d, v, h, t) {
  w = ""
  while (j <= lim && C[j] != "\047") {
    c = C[j]
    if (c != "\\") {
      t = j
      while (j <= lim && C[j] != "\\" && C[j] != "\047") j++
      w = w sl(t, j - 1)
      continue
    }
    d = C[j + 1]; j += 2
    if (d == "n") w = w "\n"
    else if (d == "t") w = w "\t"
    else if (d == "r") w = w "\r"
    else if (d == "a") w = w "\007"
    else if (d == "b") w = w "\b"
    else if (d == "e" || d == "E") w = w "\033"
    else if (d == "f") w = w "\f"
    else if (d == "v") w = w "\v"
    else if (d == "x" || d == "u" || d == "U") {
      t = (d == "x") ? 2 : ((d == "u") ? 4 : 8); v = 0; h = 0
      while (h < t && j <= lim && index("0123456789abcdefABCDEF", C[j]) > 0) { v = v * 16 + hexv(C[j]); j++; h++ }
      if (h == 0) w = w "\\" d
      else if (v > 0 && v < 128) w = w sprintf("%c", v)
      else w = w "?"
    } else if (d ~ /[0-7]/) {
      v = d + 0; h = 1
      while (h < 3 && j <= lim && C[j] ~ /[0-7]/) { v = v * 8 + C[j]; j++; h++ }
      if (v > 0 && v < 128) w = w sprintf("%c", v); else w = w "?"
    } else w = w d
  }
  AEND = j + 1
  return w
}
function dqword(k, lim,    w, c, j, a) {
  w = ""
  while (k <= lim) {
    c = C[k]
    if (c == " " || c == "\t" || c == "\n") break
    if (c == "\\") { if (C[k + 1] != "\n") w = w C[k + 1]; k += 2; continue }
    if (c == "\047") {
      j = k + 1; while (j <= lim && C[j] != "\047") j++
      w = w sl(k + 1, j - 1); k = j + 1; continue
    }
    if (c == "$" && C[k + 1] == "\047") { w = w ansi(k + 2, lim); k = AEND; continue }
    if (c == "\"") {
      j = k + 1
      while (j <= lim && C[j] != "\"") {
        a = j; while (j <= lim && C[j] != "\"" && C[j] != "\\") j++
        w = w sl(a, j - 1)
        if (j <= lim && C[j] == "\\") {
          if (C[j + 1] ~ /[\\"$`]/) w = w C[j + 1]
          else if (C[j + 1] != "\n") w = w "\\" C[j + 1]
          j += 2
        }
      }
      k = j + 1; continue
    }
    if (c == "$" && C[k + 1] == "(") { j = skipparen(k + 1); w = w sl(k, j - 1); k = j; continue }
    # Copy a run of ordinary characters in one step.
    a = k
    while (k <= lim && C[k] != " " && C[k] != "\t" && C[k] != "\n" && C[k] != "\\" && C[k] != "\047" && C[k] != "\"" && C[k] != "$") k++
    if (k == a) k++
    w = w sl(a, k - 1)
  }
  WEND = k
  return w
}
function dqwords(us, ue,    k, nw, j) {
  k = us; nw = 0
  while (nw < 16) {
    while (k <= ue && (C[k] == " " || C[k] == "\t" || (C[k] == "\\" && C[k + 1] == "\n"))) k += (C[k] == "\\") ? 2 : 1
    if (k > ue) break
    W[++nw] = dqword(k, ue)
    if (WEND == k) {
      j = k; while (j <= ue && C[j] != " " && C[j] != "\t") j++
      W[nw] = sl(k, j - 1); WEND = j
    }
    k = WEND
  }
  DQEND = k
  return nw
}
# Close one command unit [us, ue]. Emits it (raw, plus a dequoted form of
# its first words) when it names a package manager. Sets EU_SHELL when the
# unit is a shell reading its script from stdin, and EU_ARGS (its
# dequoted arguments) for a following `| bash`.
function endunit(us, ue, prevsep, prevargs, hs,    k, c, p1, p2, p3, rel, nw, j, dq, b, n, parts, joined, t, f) {
  EU_SHELL = 0; EU_ARGS = ""
  if (us == 0 || ABORT) return
  while (ue >= us && (C[ue] == " " || C[ue] == "\t" || C[ue] == "\r")) ue--
  if (ue < us) return
  rel = 0; p1 = ""; p2 = ""; p3 = ""
  for (k = us; k <= ue; k++) {
    c = C[k]
    if (c == "\047" || c == "\"" || c == "\\") continue
    if ((c == "m" && p1 == "p" && p2 == "n") || (c == "n" && p1 == "u" && p2 == "b") || (c == "n" && p1 == "r" && p2 == "a" && p3 == "y")) { rel = 1; break }
    p3 = p2; p2 = p1; p1 = c
  }
  nw = dqwords(us, ue)
  # Decoded ANSI-C words can name a manager the raw text hides.
  if (!rel) for (j = 1; j <= nw; j++) if (W[j] ~ /npm|yarn|bun/) rel = 1
  # Skip assignments and launcher wrappers (sudo bash, env bash, ...).
  f = 1
  while (f <= nw) {
    t = W[f]; b = basename(t)
    if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { f++; continue }
    if (b ~ /^(env|sudo|doas|nohup|time|command|exec|stdbuf|nice|timeout|ionice|chrt|taskset|caffeinate|busybox|arch|chronic|unbuffer|flock|script)$/) {
      f++
      while (f <= nw && W[f] ~ /^-/) {
        if (W[f] ~ /^-[ugCDnoeiskcp]$/ || W[f] ~ /^--(signal|kill-after|user|group)$/) f++
        f++
      }
      if (b ~ /^(timeout|chrt|taskset|flock|script)$/) f++
      continue
    }
    break
  }
  b = basename(W[f])
  if (b ~ /^(bash|sh|zsh|dash|ksh|ash|fish|tcsh|csh)$/ && (f == nw || W[f + 1] ~ /^[-+<]/ || hs > 0)) {
    EU_SHELL = 1
    if (prevsep == "|" && prevargs != "") {
      n = split(prevargs, parts, "\002"); joined = ""
      for (j = 2; j <= n; j++) {
        emitscript(parts[j])
        if (joined == "" && parts[j] ~ /^-/) continue
        joined = (joined == "") ? parts[j] : joined " " parts[j]
      }
      emitscript(joined)
    }
    if (hs > 0) emitscript(dqword(hs, ue))
  }
  if (!rel) return
  for (j = 2; j <= nw; j++) EU_ARGS = EU_ARGS "\002" W[j]
  # Plain text commands never run their arguments; skip them so a long
  # list of `echo npm ...` lines costs nothing downstream.
  if (b ~ /^(echo|printf|cat|grep|egrep|fgrep|rg|awk|sed|jq|head|tail|ls|cd|test|true|false|wc|sort|uniq|tr|cut|mkdir|touch|git|gh)$/) return
  # `<pm> ci` is always allowed, and identical units need one check.
  if (W[1] ~ /^(npm|pnpm|yarn|bun)$/ && W[2] == "ci" && nw == 2) return
  addunit(sl(us, ue))
  dq = ""
  for (j = 1; j <= nw; j++) {
    t = W[j]
    if (t ~ /[ \t\n]/ && t !~ /\047/) t = "\047" t "\047"
    dq = (j == 1) ? t : dq " " t
  }
  if (DQEND <= ue) dq = dq " " sl(DQEND, ue)
  addunit(dq)
}
function addunit(t) {
  if (t in SEEN) return
  SEEN[t] = 1
  U[++NU] = t
}
function hdreg(k,    dash, w, q, c) {
  dash = 0; if (C[k] == "-") { dash = 1; k++ }
  while (C[k] == " " || C[k] == "\t") k++
  w = ""; q = 0
  # ANSI-C and locale quoted delimiters (dollar-quote) are quoted too.
  if (C[k] == "$" && C[k + 1] == "\047") { w = ansi(k + 2, N); q = 1; k = AEND }
  else if (C[k] == "$" && C[k + 1] == "\"") k++
  while (k <= N) {
    c = C[k]
    if (c == "\047" || c == "\"") { q = 1; k++; while (k <= N && C[k] != c) { w = w C[k]; k++ }; k++; continue }
    if (c == "\\") { q = 1; w = w C[k + 1]; k += 2; continue }
    if (c == " " || c == "\t" || c == "\n" || c == ";" || c == "&" || c == "|" || c == "<" || c == ">" || c == "(" || c == ")") break
    w = w c; k++
  }
  if (w != "") { HN++; HD[HN] = w; HQ[HN] = q; HDASH[HN] = dash }
  return k
}
function isdelim(a, d,    l, t) {
  l = length(d)
  if (a + l - 1 > N) return 0
  if (a + l <= N && C[a + l] != "\n" && C[a + l] != "\r") return 0
  for (t = 1; t <= l; t++) if (C[a + t - 1] != substr(d, t, 1)) return 0
  return 1
}
# Skip the bodies of the heredocs registered since index hb. Unquoted
# bodies still run $( ) and backticks, so those are scanned as commands.
function heredocs(i, hb, ls, depth,    he, h, bs, be, a) {
  he = HN
  for (h = hb + 1; h <= he; h++) {
    bs = i; be = N
    while (i <= N) {
      a = i; if (HDASH[h]) while (C[a] == "\t") a++
      if (isdelim(a, HD[h])) {
        be = i - 1; i = a + length(HD[h])
        while (i <= N && C[i] != "\n") i++
        i++
        break
      }
      while (i <= N && C[i] != "\n") {
        if (!HQ[h]) {
          if (C[i] == "\\") { i += 2; continue }
          if (C[i] == "`") { i = scan(i + 1, "bq", depth + 1); continue }
          if (C[i] == "$" && C[i + 1] == "(") {
            if (C[i + 2] == "(") i = arith(i + 3); else i = scan(i + 2, "subst", depth + 1)
            continue
          }
        }
        i++
      }
      i++
    }
    if (ls) emitscript(sl(bs, be))
  }
  return i
}
function dqscan(k, depth,    c) {
  while (k <= N) {
    c = C[k]
    if (c == "\\") { k += 2; continue }
    if (c == "\"") return k + 1
    if (c == "`") { k = scan(k + 1, "bq", depth + 1); continue }
    if (c == "$" && C[k + 1] == "(") {
      if (C[k + 2] == "(") k = arith(k + 3); else k = scan(k + 2, "subst", depth + 1)
      continue
    }
    if (c == "$" && C[k + 1] == "{") { k = brace(k + 2, depth); continue }
    k++
  }
  return N + 1
}
function brace(k, depth,    d, c) {
  d = 1
  while (k <= N) {
    c = C[k]
    if (c == "\\") { k += 2; continue }
    if (c == "\047") { k++; while (k <= N && C[k] != "\047") k++; k++; continue }
    if (c == "\"") { k = dqscan(k + 1, depth); continue }
    if (c == "$" && C[k + 1] == "(") {
      if (C[k + 2] == "(") k = arith(k + 3); else k = scan(k + 2, "subst", depth + 1)
      continue
    }
    if (c == "{") d++
    else if (c == "}") { d--; if (d == 0) return k + 1 }
    k++
  }
  return N + 1
}
# Walk a command list. m is top, subst (ends at the matching `)`), or bq
# (ends at the closing backtick).
function scan(i, m, depth,    c, a, j, us, pd, hb, ls, sep, pargs, hs) {
  us = 0; pd = 0; hb = HN; ls = 0; sep = ""; pargs = ""; hs = 0
  # Past the nesting limit the guard cannot see the commands: stop parsing
  # and fail closed (\003 record) when the payload names a package manager.
  if (depth > 64) { ABORT = 1; return N + 1 }
  while (i <= N) {
    c = C[i]
    if (c == " " || c == "\t") { i++; continue }
    if (c == "\\") {
      if (C[i + 1] == "\n") { i += 2; continue }
      if (!us) us = i
      i += 2; continue
    }
    if (c == "\n") {
      endunit(us, i - 1, sep, pargs, hs); if (EU_SHELL) ls = 1
      us = 0; sep = ""; pargs = ""; hs = 0
      i = heredocs(i + 1, hb, ls, depth); HN = hb; ls = 0
      continue
    }
    if ((c == "`" && m == "bq") || (c == ")" && m == "subst" && pd == 0)) {
      endunit(us, i - 1, sep, pargs, hs)
      HN = hb
      return i + 1
    }
    if (c == ";" || c == "|" || c == "&" || c == "(" || c == ")") {
      if (c == "&" && (C[i - 1] == ">" || C[i - 1] == "<" || C[i + 1] == ">")) { if (!us) us = i; i++; continue }
      if (c == "|" && C[i - 1] == ">") { i++; continue }
      if (c == "(" && C[i + 1] == "(" && !us) { i = arith(i + 2); continue }
      endunit(us, i - 1, sep, pargs, hs); if (EU_SHELL) ls = 1
      # A pipeline feeds the text of every earlier stage toward a later shell.
      if (c == "|" && C[i + 1] != "|") pargs = ((sep == "|") ? pargs : "") EU_ARGS
      else pargs = ""
      sep = c
      if (c == "|" && C[i + 1] == "|") { sep = "||"; i++ }
      else if (c == "|" && C[i + 1] == "&") i++
      if (c == "(") pd++
      else if (c == ")" && pd > 0) pd--
      us = 0; hs = 0; i++
      continue
    }
    if (c == "#" && (!us || C[i - 1] == " " || C[i - 1] == "\t")) {
      endunit(us, i - 1, sep, pargs, hs); if (EU_SHELL) ls = 1
      us = 0; hs = 0
      while (i <= N && C[i] != "\n") i++
      continue
    }
    if (!us) us = i
    if (c == "\047") { j = i + 1; while (j <= N && C[j] != "\047") j++; i = j + 1; continue }
    if (c == "\"") { i = dqscan(i + 1, depth); continue }
    if (c == "`") { i = scan(i + 1, "bq", depth + 1); continue }
    if (c == "$") {
      a = C[i + 1]
      if (a == "\047") {
        j = i + 2
        while (j <= N && C[j] != "\047") { if (C[j] == "\\") j++; j++ }
        i = j + 1; continue
      }
      if (a == "(" && C[i + 2] == "(") { i = arith(i + 3); continue }
      if (a == "(") { i = scan(i + 2, "subst", depth + 1); continue }
      if (a == "{") { i = brace(i + 2, depth); continue }
      i++; continue
    }
    if (c == "<" && C[i + 1] == "<") {
      if (C[i + 2] == "<") { j = i + 3; while (C[j] == " " || C[j] == "\t") j++; hs = j; i = j; continue }
      i = hdreg(i + 2); continue
    }
    i++
  }
  endunit(us, N, sep, pargs, hs)
  HN = hb
  return N + 1
}
# mode=shellc: print the script operand of `bash [opts] -c [opts] [--] <script>`.
function shellc(    k, nw, b, sc, w, f) {
  k = 1; nw = 0
  while (k <= N && nw < 64) {
    while (k <= N && (C[k] == " " || C[k] == "\t" || C[k] == "\n")) k++
    if (k > N) break
    w = dqword(k, N)
    if (WEND == k) break
    SW[++nw] = w; k = WEND
  }
  f = 1; b = basename(SW[1])
  if (b == "busybox") { f = 2; b = basename(SW[2]) }
  if (b !~ /^(bash|sh|zsh|dash|ksh|ash|fish|tcsh|csh)$/) return
  sc = 0
  for (k = f + 1; k <= nw; k++) {
    w = SW[k]
    if (w == "--") { k++; break }
    if (w ~ /^--command=/) { printf "%s", substr(w, 11); return }
    if (w == "--command") { sc = 1; continue }
    if (w ~ /^--(rcfile|init-file|init-command)$/ || (b == "fish" && w == "-C")) { k++; continue }
    if (w ~ /^-[A-Za-z]*c[A-Za-z]*$/) { sc = 1; continue }
    if (w ~ /^[-+][oO]$/) { k++; continue }
    if (w ~ /^[-+]/) continue
    break
  }
  if (sc && k <= nw) printf "%s", SW[k]
}
# mode=evalargs: print the dequoted words after the first, joined by spaces,
# which is the command line eval runs.
function evalargs(    k, nw, w, out) {
  k = 1; nw = 0; out = ""
  while (k <= N) {
    while (k <= N && (C[k] == " " || C[k] == "\t" || C[k] == "\n")) k++
    if (k > N) break
    w = dqword(k, N)
    if (WEND == k) { w = C[k]; WEND = k + 1 }
    nw++; k = WEND
    if (nw > 1) out = (out == "") ? w : out " " w
  }
  printf "%s", out
}
BEGIN { RS = "\002" }
{ s = (NR > 1) ? s "\002" $0 : $0 }
END {
  N = split(s, C, "")
  if (N > 0 && C[N] == "\n") N--
  HN = 0; NU = 0
  if (mode == "shellc") { shellc(); exit }
  if (mode == "evalargs") { evalargs(); exit }
  scan(1, "top", 0)
  if (ABORT) { if (relevant(s)) printf "\003\001"; exit }
  for (k = 1; k <= NU; k++) printf "%s\001", U[k]
}
'

ANALYZE_MAX_DEPTH=4
analyze_command() {
  local cmd="$1" depth="${2:-0}" normalized seg
  if [ "$depth" -gt "$ANALYZE_MAX_DEPTH" ]; then
    case "$cmd" in
      *npm*|*yarn*|*pnpm*|*bun*)
        emit_block "shell" "-c" "more than $ANALYZE_MAX_DEPTH nested shell -c layers; the guard cannot see the command they run." ;;
    esac
    return 0
  fi
  normalized="$(LC_ALL=C awk -v mode=split "$SHELL_SPLIT_AWK" <<< "$cmd")"
  # read -d walks the units in one pass; pattern expansions on a large
  # remainder cost seconds on big payloads.
  local -a units=()
  local unit
  while IFS= read -r -d "$DELIM" unit; do
    units+=("$unit")
  done < <(printf '%s%s' "$normalized" "$DELIM")
  for seg in ${units[@]+"${units[@]}"}; do
    case "$seg" in
      $'\x02'*) analyze_command "${seg#?}" $((depth + 1)) ;;
      $'\x03')
        emit_block "shell" "nesting" "command substitutions nested past the parser limit; the guard cannot see the command they run." ;;
      *) check_segment "$seg" "$depth" ;;
    esac
  done
}

# Legacy whole-command pass, kept as an extra check on top of the
# quote-aware pass above. It splits on operators even inside quotes, so it
# still blocks install text passed as quoted arguments to an unknown command
# (`bash other.sh --body "x; npm i pkg"`). Its whole-command text-wrapper
# exemptions now only skip THIS pass; the quote-aware pass already checked
# every unit of those commands.
legacy_unquoted_pass() {
  case "$CMD" in
    *npm*|*yarn*|*bun*) ;;
    *) return 0 ;;
  esac
  if [[ "$CMD" == *"<<"* ]]; then
    return 0
  fi

  # First non-whitespace token of the command (after env-assignment strip).
  FIRST="$CMD"
  FIRST="${FIRST#"${FIRST%%[![:space:]]*}"}"
  # Same no-progress guard as check_segment: never loop without shrinking.
  while [[ "$FIRST" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]] ]]; do
    FIRST_BEFORE="$FIRST"
    FIRST="${FIRST#*[[:space:]]}"
    FIRST="${FIRST#"${FIRST%%[![:space:]]*}"}"
    [ "$FIRST" != "$FIRST_BEFORE" ] || break
  done
  # Take the first two tokens to recognize "git commit", "gh pr create", etc.
  FIRST_TWO=""
  FIRST_THREE=""
  FIRST_ONE=""
  FIRST_LINE_COUNT=0
  while IFS= read -r first_line || [ -n "$first_line" ]; do
    first_words=()
    read -r -a first_words <<< "$first_line"
    first_two="${first_words[0]:-} ${first_words[1]:-}"
    first_three="${first_words[0]:-} ${first_words[1]:-} ${first_words[2]:-}"
    first_one="${first_words[0]:-}"
    if [ "$FIRST_LINE_COUNT" -gt 0 ]; then
      FIRST_TWO+=$'\n'
      FIRST_THREE+=$'\n'
      FIRST_ONE+=$'\n'
    fi
    FIRST_TWO+="$first_two"
    FIRST_THREE+="$first_three"
    FIRST_ONE+="$first_one"
    FIRST_LINE_COUNT=$((FIRST_LINE_COUNT + 1))
  done <<< "$FIRST"

  case "$FIRST_ONE" in
    echo|printf|cat|osascript|awk|sed) return 0 ;;
  esac
  case "$FIRST_TWO" in
    "git commit"|"git tag"|"git stash"|"bash -c"|"sh -c"|"zsh -c"|"python -c"|"python3 -c"|"node -e"|"ruby -e"|"perl -e") return 0 ;;
  esac
  # The gh pr create wrapper gets the "gh pr create" exemption below under any
  # path form: bash/sh/zsh or direct execution, relative, ./, or absolute.
  if [ "$FIRST_LINE_COUNT" -eq 1 ]; then
    case "$FIRST_ONE" in
      bash|sh|zsh) pr_wrapper_word="${FIRST_TWO#* }" ;;
      *) pr_wrapper_word="$FIRST_ONE" ;;
    esac
    pr_wrapper_re='^"?([^[:space:]"]*/)?core/scripts/hq-pr-create\.sh"?$'
    [[ "$pr_wrapper_word" =~ $pr_wrapper_re ]] && return 0
  fi
  case "$FIRST_THREE" in
    "gh pr create"|"gh pr edit"|"gh issue create"|"gh issue edit"|"gh release create") return 0 ;;
  esac

  # Split on shell operators (&& / || / ; / |) ONLY — never on newlines, since
  # newlines inside heredocs / quoted message bodies are not shell-command
  # boundaries. Each operator-separated chunk is one shell "command unit"; the
  # regex inside check_segment then requires the pm command to be at the START
  # of that unit, which prevents false positives on text like
  # `git commit -m "... npm install x ..."`.
  DELIM=$'\x01'
  normalize_shell_separators() {
    local input="$1"

    # Bash's global substitutions process the whole payload in native code.
    # Split two-character operators first to avoid turning them into two delimiters.
    NORMALIZED="${input//&&/$DELIM}"
    NORMALIZED="${NORMALIZED//||/$DELIM}"
    NORMALIZED="${NORMALIZED//;/$DELIM}"
    NORMALIZED="${NORMALIZED//|/$DELIM}"
  }
  normalize_shell_separators "$CMD"
  local -a legacy_units=()
  local legacy_unit
  while IFS= read -r -d "$DELIM" legacy_unit; do
    legacy_units+=("$legacy_unit")
  done < <(printf '%s%s' "$NORMALIZED" "$DELIM")
  for seg in ${legacy_units[@]+"${legacy_units[@]}"}; do
    check_segment "$seg"
  done

}

analyze_command "$CMD" 0
legacy_unquoted_pass

exit 0
