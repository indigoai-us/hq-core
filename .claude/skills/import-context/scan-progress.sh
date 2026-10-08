#!/usr/bin/env bash
# /import-context scanner: streaming progress events (--progress-json).
#
# Sourced by scan.sh only when --progress-json is passed. Prints JSON Lines on
# stdout (one event object per line, "v":1) while the scan runs, so an app can
# render a knowledge tree that grows as sources, companies and projects are
# found. Contract: progress-json.md in this directory.
#
# Invariants (guarded by core/scripts/tests/import-context-progress-json.test.sh):
#   - report.json is byte-identical with and without the flag. Nothing here
#     writes to DISCOVERY_LOG or touches the arrays scan.sh builds the report
#     from; this code only reads the filesystem and keeps its own state under
#     $PJ_DIR (inside scan.sh's temp dir, removed on exit and on TERM/INT).
#   - Events carry names and counts only. No file contents, prompts, message
#     text or secrets, and no absolute paths. Project and company names are
#     directory basenames, validated git remote org/repo names, or HQ manifest
#     names. Remote URLs are reduced to host/org/name; userinfo, query strings
#     and fragments are dropped, and a remote whose org or name still holds
#     @ : ? # % " or whitespace is treated as no remote. A quoted config
#     value (url = "...") is unquoted first. Session working
#     directories are read (the "cwd" field only) to group sessions into
#     projects, and are never emitted.
#   - Output order is deterministic for a given machine state. Lists are
#     sorted with LC_ALL=C, and count events fire at fixed milestones
#     (1, 2, 5, 10, 20, 50, ...) instead of wall-clock intervals.
#   - File lists are NUL-delimited end to end. Paths containing a tab or a
#     newline are skipped, never split.
#   - Local only. No network access; git remotes are read from .git/config
#     files without running git.
#
# Bash 3.2 compatible (stock macOS): no associative arrays, no EPOCHREALTIME.

PJ_DIR=""
PJ_SOURCES=""
PJ_LAST_SRC=""
PJ_LAST_KEY=""
PJ_LAST_VAL=""
PJ_SKIP_DIRS=""      # newline-joined, fixed small set: never a project root
PJ_TOTAL_SESSIONS=0
PJ_N=0

# ──────────────────────── JSON emitters ────────────────────────
pj_str() { # JSON string literal for $1 (control characters dropped)
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/ }"
  s="${s//$'\r'/ }"
  s="${s//$'\t'/ }"
  s="${s//[[:cntrl:]]/}"
  printf '"%s"' "$s"
}

pj_emit() { printf '%s\n' "$1"; }

pj_event_source() { # <id> <status> [counts-json] [message]
  local line
  line="{\"v\":1,\"type\":\"source\",\"id\":$(pj_str "$1"),\"status\":$(pj_str "$2")"
  [[ -n "${3:-}" ]] && line="$line,\"counts\":$3"
  [[ -n "${4:-}" ]] && line="$line,\"message\":$(pj_str "$4")"
  pj_emit "$line}"
}

pj_event_count() { # <source> <key> <value>
  pj_emit "{\"v\":1,\"type\":\"count\",\"source\":$(pj_str "$1"),\"key\":$(pj_str "$2"),\"value\":$3}"
  PJ_LAST_SRC="$1"; PJ_LAST_KEY="$2"; PJ_LAST_VAL="$3"
}

# Emit the final value for a key unless it was the last count already sent.
pj_event_count_final() { # <source> <key> <value>
  if [[ "$PJ_LAST_SRC" == "$1" && "$PJ_LAST_KEY" == "$2" && "$PJ_LAST_VAL" == "$3" ]]; then
    return 0
  fi
  pj_event_count "$1" "$2" "$3"
}

pj_event_error() { # <source> <message>
  pj_emit "{\"v\":1,\"type\":\"error\",\"source\":$(pj_str "$1"),\"message\":$(pj_str "$2")}"
}

pj_event_company() { # <id> <name> <basis>
  pj_emit "{\"v\":1,\"type\":\"company\",\"id\":$(pj_str "$1"),\"name\":$(pj_str "$2"),\"basis\":$(pj_str "$3")}"
}

pj_event_project() { # <id> <name> <company or -> <basis>
  local co="null"
  [[ "$3" != "-" ]] && co="$(pj_str "$3")"
  pj_emit "{\"v\":1,\"type\":\"project\",\"id\":$(pj_str "$1"),\"name\":$(pj_str "$2"),\"company\":$co,\"basis\":$(pj_str "$4")}"
}

# ──────────────────────── helpers ────────────────────────
pj_has_tab_or_nl() { case "$1" in *$'\t'*|*$'\n'*|*$'\r'*) return 0 ;; esac; return 1; }

pj_is_skip_dir() { # <dir>; PJ_SKIP_DIRS is a fixed set of ~20 entries
  case $'\n'"$PJ_SKIP_DIRS"$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
  esac
  return 1
}

# Stream NUL-delimited find output, emitting count events at fixed milestones
# (1, 2, 5, 10, 20, 50, ...). Writes every path, NUL-terminated and sorted, to
# <listfile>. Sets PJ_N to the total. The find args must end in -print0.
pj_walk() { # <source> <key> <listfile> <errfile> <find args...>
  local src="$1" key="$2" list="$3" errf="$4" item n=0 m=1 idx=0 mult=1
  shift 4
  exec 7>"$list"
  while IFS= read -r -d '' item; do
    printf '%s\0' "$item" >&7
    n=$((n + 1))
    if [[ $n -eq $m ]]; then
      pj_event_count "$src" "$key" "$n"
      idx=$((idx + 1))
      case $((idx % 3)) in
        0) mult=$((mult * 10)); m=$mult ;;
        1) m=$((2 * mult)) ;;
        2) m=$((5 * mult)) ;;
      esac
    fi
  done < <(find "$@" 2>"$errf")
  exec 7>&-
  LC_ALL=C sort -z -o "$list" "$list"
  PJ_N=$n
}

# A remote path segment is usable only when it holds no credential or URL
# syntax and no whitespace.
pj_remote_part_ok() {
  [[ -n "$1" ]] || return 1
  case "$1" in
    *[@:?#%\"[:space:]]*|.|..) return 1 ;;
  esac
  return 0
}

# Read a git checkout's remote without running git. Sets PJ_RKEY (lowercased
# host/path, empty when there is no usable remote), PJ_RORG and PJ_RNAME.
pj_git_remote() { # <repo root>
  local root="$1" g="$1/.git" cfg="" line gd cd url="" first="" in_origin=0 key val
  PJ_RKEY=""; PJ_RORG=""; PJ_RNAME=""
  if [[ -d "$g" ]]; then
    cfg="$g/config"
  elif [[ -f "$g" ]]; then
    IFS= read -r line < "$g" || true
    gd="${line#gitdir: }"
    [[ "$gd" == /* ]] || gd="$root/$gd"
    if [[ -f "$gd/commondir" ]]; then
      IFS= read -r cd < "$gd/commondir" || true
      [[ "$cd" == /* ]] || cd="$gd/$cd"
      cfg="$cd/config"
    else
      cfg="$gd/config"
    fi
  fi
  [[ -n "$cfg" && -r "$cfg" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      '[remote "origin"]'*) in_origin=1; continue ;;
      '['*) in_origin=0; continue ;;
    esac
    case "$line" in
      url*=*)
        key="${line%%=*}"; key="${key%"${key##*[![:space:]]}"}"
        [[ "$key" == "url" ]] || continue
        val="${line#*=}"; val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
        # git config allows a quoted value: url = "https://host/org/repo.git"
        if [[ ${#val} -ge 2 && "$val" == \"*\" ]]; then val="${val#\"}"; val="${val%\"}"; fi
        if [[ $in_origin -eq 1 ]]; then url="$val"; break; fi
        [[ -z "$first" ]] && first="$val"
        ;;
    esac
  done < "$cfg"
  [[ -z "$url" ]] && url="$first"
  [[ -n "$url" ]] || return 0

  # Drop query strings and fragments before anything else (tokens live there).
  url="${url%%\?*}"; url="${url%%#*}"

  local host="" path="" rest
  case "$url" in
    file:*|/*|.*) return 0 ;;
    *://*)
      rest="${url#*://}"
      # Userinfo may itself contain "/" (u:p/q@host/...): the host starts
      # after the last "@".
      case "$rest" in *@*) rest="${rest##*@}" ;; esac
      host="${rest%%/*}"; path="${rest#*/}"
      [[ "$path" == "$rest" ]] && path=""
      host="${host%%:*}"
      ;;
    *:*)
      rest="${url##*@}"
      host="${rest%%:*}"; path="${rest#*:}"
      ;;
    *) return 0 ;;
  esac
  path="${path%/}"; path="${path%.git}"; path="${path#/}"
  case "$host" in
    ''|*[!A-Za-z0-9.-]*) return 0 ;;
  esac
  [[ "$path" == */* ]] || return 0
  case "$path" in *[@:?#%\"[:space:]]*|*//*) return 0 ;; esac
  local org="${path%%/*}" name="${path##*/}"
  pj_remote_part_ok "$org" || return 0
  pj_remote_part_ok "$name" || return 0
  PJ_RORG="$org"
  PJ_RNAME="$name"
  PJ_RKEY="$(printf '%s/%s' "$host" "$path" | tr '[:upper:]' '[:lower:]')"
}

# Append a project row for <root>. Identity (key) is the git remote
# host/org/name when usable, else the directory. Duplicates by key are
# resolved in the rule pass, which keeps the first-emitted row.
# projects.tsv: id  name  company  basis  root  key  org  emitted_company
pj_add_project() { # <root> <basis>
  local root="$1" name key org=""
  pj_has_tab_or_nl "$root" && return 0
  if [[ -e "$root/.git" ]]; then pj_git_remote "$root"; else PJ_RKEY=""; fi
  if [[ -n "$PJ_RKEY" ]]; then
    key="git:$PJ_RKEY"; name="$PJ_RNAME"; org="$PJ_RORG"
  else
    key="path:$root"; name="${root##*/}"
  fi
  printf '?\t%s\t-\t%s\t%s\t%s\t%s\t!\n' \
    "${name:--}" "$2" "$root" "$key" "${org:--}" >> "$PJ_DIR/projects.tsv"
}

# ──────────────────────── company rule pass ────────────────────────
# Deterministic, rule-based company assignment for projects that have none.
# Precedence: HQ company path or HQ repo remote > git remote org (matched to
# an HQ company when possible) > siblings in the same work folder > a new
# folder company when 2+ projects share a non-generic parent folder.
#
# Project ids: "p_" + 12 hex of a fixed-salt hash of the project identity,
# computed here in awk so every machine uses the same function (no md5/sha
# tool differences). The identity is the git remote host/org/name when there
# is a usable remote (stable across machines and clone locations), else the
# directory path relative to $HOME ("~/code/x"), else the absolute path for
# folders outside $HOME. Two polynomial hashes modulo primes below 2^44, all
# arithmetic exact in doubles.
# shellcheck disable=SC2016 # awk program text, not shell expansions
pj_assign_awk='
function slug(s) { s = tolower(s); gsub(/[^a-z0-9]+/, "-", s); gsub(/^-+|-+$/, "", s); return s }
function dirn(p) { sub(/\/[^\/]*$/, "", p); return p }
function base(p) { sub(/^.*\//, "", p); return p }
function generic(n,   l) {
  l = tolower(n)
  # Machine-generated folder names (UUIDs, hashes) are never companies.
  return (l in GEN) || substr(n, 1, 1) == "." || l ~ /^[0-9a-f-]+$/ && length(l) >= 12
}
function pid(key,   s, i, n, c, a, b) {
  s = key
  if (substr(s, 1, 5) == "path:") {
    s = substr(s, 6)
    if (index(s, home "/") == 1) s = "~/" substr(s, length(home) + 2)
    s = "path:" s
  }
  s = "hq-import-scan-v1|" s
  a = 0; b = 0; n = length(s)
  for (i = 1; i <= n; i++) {
    c = ORD[substr(s, i, 1)] + 0
    a = (a * 257 + c + 1) % 17592186044399
    b = (b * 263 + c + 7) % 17592186044299
  }
  return sprintf("p_%06x%06x", a % 16777216, b % 16777216)
}
function new_company(id, name, basis) {
  if (id == "" || (id in CO)) return
  CO[id] = name; NEWCO[++nnew] = id; NEWNAME[id] = name; NEWBASIS[id] = basis
}
BEGIN {
  FS = OFS = "\t"
  split("src code dev work projects project repos repo github gitlab bitbucket git documents desktop downloads private public personal archive archives tmp temp sandbox playground experiments forks clones workspace worktrees home users library applications", g, " ")
  for (k in g) GEN[g[k]] = 1
  for (k = 1; k < 256; k++) ORD[sprintf("%c", k)] = k
}
FILENAME == cofile  { CO[$1] = $2; next }
FILENAME == hqfile  { HQNAME[$1] = $2; if ($3 != "-") HQORG[tolower($3)] = $1; HQSLUG[slug($2)] = $1; HQSLUG[$1] = $1; HQRAW[$4] = $1; next }
FILENAME == keyfile { HQKEY[$1] = $2; next }
FILENAME == parfile { PAR[$0] = 1; next }
{
  if ($6 in SEEN) next
  SEEN[$6] = 1
  n++; ID[n] = ($1 == "?") ? pid($6) : $1
  NAME[n] = $2; COMP[n] = $3; BASIS[n] = $4; ROOT[n] = $5; KEY[n] = $6; ORG[n] = $7; EMIT[n] = $8
}
END {
  hqc = hq "/companies/"
  # Pass 1: HQ company folder, HQ repo remote, remote org.
  for (i = 1; i <= n; i++) {
    if (COMP[i] != "-") continue
    if (index(ROOT[i], hqc) == 1) {
      rest = substr(ROOT[i], length(hqc) + 1); sub(/\/.*$/, "", rest)
      if (rest in HQRAW) { COMP[i] = HQRAW[rest]; continue }
    }
    if (KEY[i] in HQKEY) { COMP[i] = HQKEY[KEY[i]]; continue }
    if (ORG[i] != "-") {
      o = tolower(ORG[i]); s = slug(ORG[i])
      if (o in HQORG) { COMP[i] = HQORG[o]; continue }
      if (s in HQSLUG) { COMP[i] = HQSLUG[s]; continue }
      if (s != "") { new_company(s, ORG[i], "repo-org"); COMP[i] = s; continue }
    }
  }
  # Pass 2: work-folder grouping for projects still without a company.
  for (i = 1; i <= n; i++) {
    d = dirn(ROOT[i]); DIR[i] = d; CNT[d]++
    if (COMP[i] != "-") { if (!(d in SIB)) SIB[d] = COMP[i]; else if (SIB[d] != COMP[i]) SIB[d] = "*" }
  }
  for (i = 1; i <= n; i++) {
    if (COMP[i] != "-") continue
    d = DIR[i]; b = base(d)
    if (d == "" || d == home || (d in PAR) || d == hq || index(home "/", d "/") == 1 || generic(b)) continue
    if (index(d, hq "/") == 1) continue
    if ((d in SIB) && SIB[d] != "*") { COMP[i] = SIB[d]; continue }
    if (!(d in SIB) && CNT[d] >= 2) {
      s = slug(b)
      if (s == "") continue
      if (s in HQSLUG) { COMP[i] = HQSLUG[s]; continue }
      if (!(s in CO)) new_company(s, b, "folder")
      COMP[i] = s
    }
  }
  for (k = 1; k <= nnew; k++) {
    id = NEWCO[k]; print id, NEWNAME[id], NEWBASIS[id] > outco
  }
  for (i = 1; i <= n; i++) {
    changed = (EMIT[i] == "!" || EMIT[i] != COMP[i]) ? 1 : 0
    print ID[i], NAME[i], COMP[i], BASIS[i], ROOT[i], KEY[i], ORG[i], COMP[i], changed > outpr
  }
}
'

# Run the rule pass and emit new companies, then new or re-assigned projects.
pj_assign_and_emit() {
  local d="$PJ_DIR"
  : > "$d/new-companies.tsv"; : > "$d/projects.next"
  [[ -s "$d/projects.tsv" ]] || return 0
  # Already-emitted rows first (they win key collisions), then by root.
  LC_ALL=C awk -F '\t' '{ print (($8 == "!") ? 1 : 0) "\t" $0 }' "$d/projects.tsv" \
    | LC_ALL=C sort -t $'\t' -k1,1n -k6,6 -k7,7 | cut -f2- > "$d/projects.sorted"
  LC_ALL=C awk -v cofile="$d/companies.tsv" -v hqfile="$d/hqco.tsv" -v keyfile="$d/hqkeys.tsv" \
    -v parfile="$d/parents.txt" -v outco="$d/new-companies.tsv" -v outpr="$d/projects.next" \
    -v home="$HOME" -v hq="$HQ_ROOT" "$pj_assign_awk" \
    "$d/companies.tsv" "$d/hqco.tsv" "$d/hqkeys.tsv" "$d/parents.txt" "$d/projects.sorted"

  local id name basis co
  if [[ -s "$d/new-companies.tsv" ]]; then
    LC_ALL=C sort -t $'\t' -k1,1 -o "$d/new-companies.tsv" "$d/new-companies.tsv"
    while IFS=$'\t' read -r id name basis; do
      printf '%s\t%s\t%s\n' "$id" "$name" "$basis" >> "$d/companies.tsv"
      pj_event_company "$id" "$name" "$basis"
    done < "$d/new-companies.tsv"
  fi

  # Emit changed rows in (name, id) order; then persist the table.
  while IFS=$'\t' read -r id name co basis _ _ _ _ _; do
    pj_event_project "$id" "$name" "$co" "$basis"
  done < <(LC_ALL=C awk -F '\t' '$9 == 1' "$d/projects.next" | LC_ALL=C sort -t $'\t' -k2,2 -k1,1)
  cut -f1-8 "$d/projects.next" > "$d/projects.tsv"
}

# ──────────────────────── sources ────────────────────────
pj_has_source() {
  case $'\n'"$PJ_SOURCES"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; esac
  return 1
}

# HQ manifest companies. Ids are slugs of the manifest keys (first key wins
# when two keys share a slug); keys starting with "_" are templates, not
# companies. Only manifest companies are HQ companies: other folders under
# companies/ (templates, cloud-uid caches, test residue) are ignored.
# shellcheck disable=SC2016 # awk program text, not shell expansions
pj_manifest_awk='
function slug(s) { s = tolower(s); gsub(/[^a-z0-9]+/, "-", s); gsub(/^-+|-+$/, "", s); return s }
function clean(v) { sub(/[ \t]+#.*$/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v); gsub(/^["\047]|["\047]$/, "", v); gsub(/\t/, " ", v); return v }
function flush() {
  if (key != "" && sl != "" && !(sl in SEEN)) {
    SEEN[sl] = 1
    print "C\t" sl "\t" (name == "" ? key : name) "\t" (org == "" ? "-" : org) "\t" key
    for (k = 1; k <= nr; k++) print "R\t" sl "\t" REPO[k]
  }
  key = ""; sl = ""; nr = 0
}
function add_repo(v) { v = clean(v); if (v != "") REPO[++nr] = v }
/^companies:[ \t]*$/ { inco = 1; next }
inco && /^[^ \t#]/ { flush(); inco = 0; next }
!inco { next }
/^  [^ \t#][^:]*:[ \t]*$/ {
  flush(); key = $0; sub(/^  /, "", key); sub(/:[ \t]*$/, "", key); key = clean(key)
  sl = (substr(key, 1, 1) == "_") ? "" : slug(key); name = ""; org = ""; inrepos = 0; next
}
key == "" { next }
/^    name:/ { v = $0; sub(/^    name:/, "", v); name = clean(v); inrepos = 0; next }
/^    github_org:/ { v = $0; sub(/^    github_org:/, "", v); org = clean(v); inrepos = 0; next }
/^    repos:/ {
  v = $0; sub(/^    repos:/, "", v); v = clean(v); inrepos = 1
  if (v ~ /^\[/) { gsub(/[\[\]]/, "", v); m = split(v, a, ","); for (j = 1; j <= m; j++) add_repo(a[j]); inrepos = 0 }
  next
}
inrepos && /^[ ]+- / { v = $0; sub(/^ *- /, "", v); add_repo(v); next }
/^    [A-Za-z_]/ { inrepos = 0 }
END { flush() }
'

pj_source_hq() {
  local manifest="$HQ_ROOT/companies/manifest.yaml"
  pj_event_source hq scanning
  : > "$PJ_DIR/hq.raw"
  if [[ -r "$manifest" ]]; then
    LC_ALL=C awk "$pj_manifest_awk" "$manifest" > "$PJ_DIR/hq.raw" 2>/dev/null || {
      pj_event_error hq "The HQ company list could not be read."
      : > "$PJ_DIR/hq.raw"
    }
  fi
  local tag slug name org key r n=0
  while IFS=$'\t' read -r tag slug name org key; do
    case "$tag" in
      C)
        printf '%s\t%s\t%s\t%s\n' "$slug" "$name" "$org" "$key" >> "$PJ_DIR/hqco.tsv"
        printf '%s\t%s\t%s\n' "$slug" "$name" "hq-company" >> "$PJ_DIR/companies.tsv"
        pj_event_company "$slug" "$name" "hq-company"
        n=$((n + 1))
        pj_event_count hq companies "$n"
        ;;
      R)
        r="$name"
        [[ "$r" == /* ]] || r="$HQ_ROOT/$r"
        [[ -e "$r/.git" ]] || continue
        pj_git_remote "$r"
        [[ -n "$PJ_RKEY" ]] && printf 'git:%s\t%s\n' "$PJ_RKEY" "$slug" >> "$PJ_DIR/hqkeys.tsv"
        ;;
    esac
  done < "$PJ_DIR/hq.raw"
  pj_event_count_final hq companies "$n"
  pj_event_source hq "done" "{\"companies\":$n}"
}

pj_source_repos() {
  local roots=() p
  for p in "${PARENTS[@]}"; do
    case "$p" in "$HOME"/.*) continue ;; esac
    roots+=("$p")
  done
  pj_event_source repos scanning
  local n=0
  if [[ ${#roots[@]} -gt 0 ]]; then
    local prune=( -name '.*' ) b
    for b in "${PRUNE_BASENAMES[@]}"; do
      [[ "$b" == ".git" ]] && continue
      prune+=( -o -name "$b" )
    done
    for p in "${PRUNE_ABS_PATHS[@]}"; do prune+=( -o -path "$p" ); done
    pj_walk repos repos "$PJ_DIR/repos.raw" "$PJ_DIR/repos.err" \
      "${roots[@]}" -mindepth 1 -maxdepth 6 \
      '(' -name .git -print0 -prune ')' -o '(' '(' "${prune[@]}" ')' -prune ')'
    if [[ -s "$PJ_DIR/repos.err" ]]; then
      pj_event_error repos "Some folders could not be read while looking for code repositories."
    fi
    local g
    exec 7>"$PJ_DIR/repos.roots"
    while IFS= read -r -d '' g; do
      [[ -n "$g" ]] && printf '%s\0' "${g%/.git}" >&7
    done < "$PJ_DIR/repos.raw"
    exec 7>&-
    LC_ALL=C sort -z -u -o "$PJ_DIR/repos.roots" "$PJ_DIR/repos.roots"
    while IFS= read -r -d '' p; do
      [[ -n "$p" ]] || continue
      n=$((n + 1))
      pj_add_project "$p" repo
    done < "$PJ_DIR/repos.roots"
  fi
  pj_event_count_final repos repos "$n"
  pj_assign_and_emit
  pj_event_source repos "done" "{\"repos\":$n}"
}

# Map one session working directory to a project root, or return 1 to skip.
# Sets PJ_ROOT.
pj_cwd_root() { # <cwd>
  local c="$1" rel d
  PJ_ROOT=""
  case "$c" in
    */.claude/worktrees/*) c="${c%%/.claude/worktrees/*}" ;;
    */.codex/worktrees/*)  c="${c%%/.codex/worktrees/*}" ;;
    */.worktrees/*)        c="${c%%/.worktrees/*}" ;;
  esac
  c="${c%/}"
  [[ -n "$c" && "$c" == /* ]] || return 1
  case "$c" in
    "$HOME"/*|"$HQ_ROOT"|"$HQ_ROOT"/*) ;;
    /tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/folders/*|/private/var/*) return 1 ;;
  esac
  if [[ "$c" == "$HQ_ROOT" || "$c" == "$HQ_ROOT"/* ]]; then
    rel="${c#"$HQ_ROOT"}"; rel="${rel#/}"
    case "$rel" in
      companies/*/projects/*)
        d="${rel#companies/}"; local co="${d%%/*}"; d="${d#*/projects/}"; d="${d%%/*}"
        PJ_ROOT="$HQ_ROOT/companies/$co/projects/$d" ;;
      repos/*/*)
        d="${rel#repos/}"; local vis="${d%%/*}"; d="${d#*/}"; d="${d%%/*}"
        PJ_ROOT="$HQ_ROOT/repos/$vis/$d" ;;
      workspace/worktrees/*)
        d="${rel#workspace/worktrees/}"; d="${d%%/*}"
        PJ_ROOT="$HQ_ROOT/workspace/worktrees/$d" ;;
      *) return 1 ;;
    esac
    return 0
  fi
  # Dot-folders and app data (e.g. the Claude app's scratch workspaces under
  # ~/Library/Application Support) are not projects.
  case "$c" in "$HOME"/.*|"$HOME"/Library/*|"$HOME"/AppData/*) return 1 ;; esac
  if pj_is_skip_dir "$c"; then return 1; fi
  case "$HOME/" in "$c"/*) return 1 ;; esac
  # Nearest enclosing git checkout, without walking above $HOME.
  d="$c"
  while [[ -n "$d" && "$d" != "/" && "$d" != "$HOME" ]]; do
    if pj_is_skip_dir "$d"; then break; fi
    if [[ -e "$d/.git" ]]; then PJ_ROOT="$d"; return 0; fi
    d="${d%/*}"
  done
  PJ_ROOT="$c"
  return 0
}

pj_source_sessions() { # <source id> <store dir> <file glob> <project basis or ->
  local src="$1" store="$2" glob="$3" basis="$4"
  pj_event_source "$src" scanning
  pj_walk "$src" sessions "$PJ_DIR/$src.files" "$PJ_DIR/$src.err" "$store" -type f -name "$glob" -print0
  local n="$PJ_N"
  pj_event_count_final "$src" sessions "$n"
  if [[ -s "$PJ_DIR/$src.err" ]]; then
    pj_event_error "$src" "Some session folders could not be read, so the session count may be low."
  fi
  PJ_TOTAL_SESSIONS=$((PJ_TOTAL_SESSIONS + n))
  if [[ "$basis" != "-" && "$n" -gt 0 ]]; then
    # Only the first "cwd" value of each session file is read, never message
    # content. grep -h drops file names, so the list stays NUL-safe.
    xargs -0 grep -m1 -o -h -e '"cwd":"[^"\\]*"' < "$PJ_DIR/$src.files" 2>"$PJ_DIR/$src.cwd.err" \
      | LC_ALL=C awk '{ v = substr($0, 8); sub(/"$/, "", v); if (v != "") print v }' \
      | LC_ALL=C sort -u > "$PJ_DIR/$src.cwds" || true
    local c
    while IFS= read -r c; do
      [[ -n "$c" ]] || continue
      pj_cwd_root "$c" || continue
      pj_is_skip_dir "$PJ_ROOT" && continue
      pj_add_project "$PJ_ROOT" "$basis"
    done < "$PJ_DIR/$src.cwds"
    pj_assign_and_emit
  fi
  pj_event_source "$src" "done" "{\"sessions\":$n}"
}

pj_source_claude_ai() {
  pj_event_source claude-ai scanning
  local cj="$CLAUDE_EXPORT" n
  [[ -d "$cj" ]] && cj="$cj/conversations.json"
  if [[ -f "$cj" ]] && n="$(jq 'length' "$cj" 2>/dev/null)" && [[ "$n" =~ ^[0-9]+$ ]]; then
    pj_event_count claude-ai sessions "$n"
    PJ_TOTAL_SESSIONS=$((PJ_TOTAL_SESSIONS + n))
    pj_event_source claude-ai "done" "{\"sessions\":$n}"
  else
    pj_event_source claude-ai error "" "The claude.ai export could not be read. Check that it is an unzipped export folder or its conversations.json file."
  fi
}

# ──────────────────────── entry points (called from scan.sh main) ─────────
pj_begin() { # <state dir>
  PJ_DIR="$1"
  mkdir -p "$PJ_DIR"
  : > "$PJ_DIR/companies.tsv"; : > "$PJ_DIR/projects.tsv"
  : > "$PJ_DIR/hqco.tsv"; : > "$PJ_DIR/hqkeys.tsv"

  local p
  PJ_SKIP_DIRS="/"$'\n'"$HOME"$'\n'"$HQ_ROOT"
  for p in "${DEFAULT_PARENTS[@]}" "${PARENTS[@]:-}" "$HOME/Desktop" "$HOME/Downloads" "$HOME/Library"; do
    [[ -n "$p" ]] && PJ_SKIP_DIRS="$PJ_SKIP_DIRS"$'\n'"$p"
  done
  printf '%s\n' "$PJ_SKIP_DIRS" > "$PJ_DIR/parents.txt"

  # Sources present on this machine, in processing order.
  local srcs="" json="" id label
  srcs="hq"
  [[ ${#PARENTS[@]} -gt 0 ]] && srcs="$srcs"$'\n'"repos"
  [[ -d "$HOME/.claude/projects" ]] && srcs="$srcs"$'\n'"claude-code"
  [[ -d "$HOME/.codex/sessions" ]] && srcs="$srcs"$'\n'"codex"
  [[ -d "$HOME/.grok/sessions" ]] && srcs="$srcs"$'\n'"grok"
  [[ -n "$CLAUDE_EXPORT" ]] && srcs="$srcs"$'\n'"claude-ai"
  srcs="$srcs"$'\n'"artifacts"
  PJ_SOURCES="$srcs"
  while IFS= read -r id; do
    case "$id" in
      hq) label="HQ companies" ;;
      repos) label="Code repositories" ;;
      claude-code) label="Claude Code" ;;
      codex) label="Codex" ;;
      grok) label="Grok" ;;
      claude-ai) label="claude.ai export" ;;
      artifacts) label="Skills and settings" ;;
    esac
    [[ -n "$json" ]] && json="$json,"
    json="$json{\"id\":$(pj_str "$id"),\"label\":$(pj_str "$label")}"
  done <<< "$srcs"
  pj_emit "{\"v\":1,\"type\":\"start\",\"sources\":[$json]}"
}

pj_run_sources() {
  pj_source_hq
  pj_has_source repos       && pj_source_repos
  pj_has_source claude-code && pj_source_sessions claude-code "$HOME/.claude/projects" '*.jsonl' claude-code-cwd
  pj_has_source codex       && pj_source_sessions codex "$HOME/.codex/sessions" '*.jsonl' codex-cwd
  pj_has_source grok        && pj_source_sessions grok "$HOME/.grok/sessions" 'updates.jsonl' -
  pj_has_source claude-ai   && pj_source_claude_ai
  pj_event_source artifacts scanning
  return 0
}

pj_finish() { # <report.json> <absolute report path>
  local report="$1" out="$2" k v counts=""
  for k in skills commands hooks agents policies plans claude_md settings_fragments mcp_servers; do
    v="$(jq -r --arg k "$k" '.counts[$k] // 0' "$report")"
    pj_event_count artifacts "$k" "$v"
    [[ -n "$counts" ]] && counts="$counts,"
    counts="$counts\"$k\":$v"
  done
  if [[ "$(jq -r '.discovery.ok' "$report")" != "true" ]]; then
    pj_event_error artifacts "Some folders could not be read, so these counts may be low."
  fi
  pj_event_source artifacts "done" "{$counts}"
  local nco npr
  nco="$(grep -c '' "$PJ_DIR/companies.tsv" || true)"
  npr="$(grep -c '' "$PJ_DIR/projects.tsv" || true)"
  pj_emit "{\"v\":1,\"type\":\"done\",\"report\":$(pj_str "$out"),\"summary\":{\"companies\":${nco:-0},\"projects\":${npr:-0},\"sessions\":$PJ_TOTAL_SESSIONS}}"
}
