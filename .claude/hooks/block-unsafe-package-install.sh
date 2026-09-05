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

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/core/scripts/hook-lib.sh"

extract() {
  printf '%s' "$STDIN_JSON" | hq_json_get "$1"
}

TOOL_NAME="$(extract tool_name)"
[ "$TOOL_NAME" = "Bash" ] || exit 0

CMD="$(extract tool_input.command)"
[ -z "$CMD" ] && exit 0

# Honor explicit bypass — audit it.
if [ "${HQ_ALLOW_UNSAFE_INSTALL:-0}" = "1" ]; then
  HQ_ROOT="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
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

# Detect whether the command (or env) supplies the release-age gate.
has_release_age_in_cmd() {
  printf '%s' "$1" | grep -Eq -- '--config\.minimumReleaseAge=|--config\.minimum-release-age='
}

has_release_age_in_env() {
  [ -n "${npm_config_minimum_release_age:-}" ] || [ -n "${NPM_CONFIG_MINIMUM_RELEASE_AGE:-}" ]
}

has_release_age_in_repo() {
  # Walk up to 6 levels looking for a .npmrc with minimum-release-age or
  # a pnpm-workspace.yaml with minimumReleaseAge.
  local dir
  dir="$(pwd)"
  for _ in 1 2 3 4 5 6; do
    if [ -f "$dir/.npmrc" ] && grep -Eq '^[[:space:]]*minimum-release-age[[:space:]]*=' "$dir/.npmrc" 2>/dev/null; then
      return 0
    fi
    if [ -f "$dir/pnpm-workspace.yaml" ] && grep -Eq '^[[:space:]]*minimumReleaseAge[[:space:]]*:' "$dir/pnpm-workspace.yaml" 2>/dev/null; then
      return 0
    fi
    [ "$dir" = "/" ] && break
    dir="$(dirname "$dir")"
  done
  return 1
}

gate_configured() {
  has_release_age_in_cmd "$1" && return 0
  has_release_age_in_env && return 0
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
  printf '%s' "${out# }"
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
ALLOW_FILE="${HQ_ROOT:-${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}/core/scripts/install-deps.allow"

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

check_segment() {
  local seg="$1"
  # Strip ALL leading whitespace (spaces, tabs, newlines).
  seg="${seg#"${seg%%[![:space:]]*}"}"

  # Strip a leading env-assignment prefix (FOO=bar BAR=baz pm install ...).
  while [[ "$seg" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]] ]]; do
    seg="${seg#* }"
  done

  # Match: <pm> <subcmd> <rest>
  # pm in {npm, yarn, bun, pnpm}; sub in {install, i, add, ci}.
  # NOTE: no `$` end anchor — `rest` may span multiple lines (heredocs); we
  # only care that the segment STARTS with the pm command.
  local pm="" sub="" rest=""
  if [[ "$seg" =~ ^(npm|yarn|bun|pnpm)[[:space:]]+(install|i|add|ci)([[:space:]]+(.*))? ]]; then
    pm="${BASH_REMATCH[1]}"
    sub="${BASH_REMATCH[2]}"
    rest="${BASH_REMATCH[4]:-}"
    # `rest` may include trailing content from later lines (heredoc body, etc.) —
    # we only need the FIRST line for positional-arg detection.
    rest="${rest%%$'\n'*}"
    # Redirections are shell plumbing, never package arguments. Strip them once
    # here so every token loop below (hydration detection, trusted-scope check,
    # allow-list check) sees the same package-only argument list.
    rest="$(strip_redirection_tokens "$rest")"
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
  if [ "$saw_pkg" = "1" ] && [ "$all_trusted" = "1" ]; then
    return 0
  fi

  # Sanctioned HQ CLI deps: global install, every pkg pinned + allow-listed.
  if allowed_global_install "$rest"; then
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

# False-positive guards before splitting:
#
#   (1) Heredoc present (`<<` or `<<-`) — body is text, not a fresh shell
#       invocation. Skip the whole check.
#   (2) Command starts with a "text-wrapping" command — these accept long
#       string args (commit messages, scripts, JSON, etc.) that often contain
#       shell metacharacters (&&, |, ;) inside quotes. Naive operator
#       splitting would FP on text like `echo "... npm install x ..."`.
#       Wrappers: echo, printf, cat, git commit/tag/stash, gh pr/issue/release,
#       bash -c, sh -c, python -c, python3 -c, node -e, ruby -e, perl -e,
#       osascript, awk, sed (when given a script body).
#
# If a real install command is chained AFTER one of these (e.g.
# `git commit -m "..." && npm install x`), we WILL miss it — but the cost
# of a chained miss is low (the user can re-invoke) compared to the FP rate
# of blocking every commit message that mentions npm.

if [[ "$CMD" == *"<<"* ]]; then
  exit 0
fi

# First non-whitespace token of the command (after env-assignment strip).
FIRST="$CMD"
FIRST="${FIRST#"${FIRST%%[![:space:]]*}"}"
while [[ "$FIRST" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]] ]]; do
  FIRST="${FIRST#* }"
done
# Take the first two tokens to recognize "git commit", "gh pr create", etc.
FIRST_TWO="$(printf '%s' "$FIRST" | awk '{print $1, $2}')"
FIRST_THREE="$(printf '%s' "$FIRST" | awk '{print $1, $2, $3}')"
FIRST_ONE="$(printf '%s' "$FIRST" | awk '{print $1}')"

case "$FIRST_ONE" in
  echo|printf|cat|osascript|awk|sed) exit 0 ;;
esac
case "$FIRST_TWO" in
  "git commit"|"git tag"|"git stash"|"bash -c"|"sh -c"|"zsh -c"|"python -c"|"python3 -c"|"node -e"|"ruby -e"|"perl -e") exit 0 ;;
esac
case "$FIRST_THREE" in
  "gh pr create"|"gh pr edit"|"gh issue create"|"gh issue edit"|"gh release create") exit 0 ;;
esac

# Split on shell operators (&& / || / ; / |) ONLY — never on newlines, since
# newlines inside heredocs / quoted message bodies are not shell-command
# boundaries. Each operator-separated chunk is one shell "command unit"; the
# regex inside check_segment then requires the pm command to be at the START
# of that unit, which prevents false positives on text like
# `git commit -m "... npm install x ..."`.
DELIM=$'\x01'
NORMALIZED=$(printf '%s' "$CMD" | sed -E "s/[[:space:]]*(&&|\\|\\||;|\\|)[[:space:]]*/${DELIM}/g")
remaining="$NORMALIZED"
while [ -n "$remaining" ]; do
  if [[ "$remaining" == *"${DELIM}"* ]]; then
    seg="${remaining%%${DELIM}*}"
    remaining="${remaining#*${DELIM}}"
  else
    seg="$remaining"
    remaining=""
  fi
  check_segment "$seg"
done

exit 0
