#!/usr/bin/env bash
# leak-scan runner — invoked by .github/workflows/pr-checks.yml
#
# Modes (mechanical — no LLM):
#   denylist          fail if any denylist key appears in PR-changed files
#                     (outside of documented exceptions). Body-wide; ports
#                     HQ core/scripts/verify-promotion-clean.sh logic.
#   policy-rationale  fail if a policies/**/*.md file's ## Rationale section
#                     references non-public context (heuristic regex list).
#                     Additional to denylist, NOT a replacement.
#   slugs             fail if a PR-changed file contains a private tenant slug
#                     from manifest-snapshot.yaml outside allowlist.yaml.
#   users-path        fail if any tracked policy/script body contains a
#                     literal /Users/... absolute path. Tripwire: rule
#                     hq-promote-hq-core-users-path-tripwire.
#   provenance        fail if any core/policies/*.md contains a literal
#                     "## Provenance" section header (must be stripped on
#                     promote). Rule: promote-hq-core.md Phase-4 push step.
#   vendor-public-ok  fail if any policy with applies_to: <non-empty> lacks
#                     vendor_public_ok: true. Rule:
#                     hq-cmd-promote-hq-core-vendor-scoped-policies-default-private.
#   public-frontmatter
#                     fail if any changed core/policies/*.md lacks
#                     public: true (or skip-promotion: true) frontmatter.
#                     Rule: hq-promote-pipeline-public-filter-needs-ci-revalidation.
#   commands-skills-tripwire
#                     fail if PR diff touches .claude/commands/ or
#                     .claude/skills/ AND PR is not labeled "manual-copy".
#                     Rule: hq-promote-hq-core-skills-commands-manual-copy.
#   core-yaml-locked  fail if core/core.yaml changes hqVersion without label
#                     "version-bump"; path-only metadata edits are allowed.
#   core-yaml-version-monotonic
#                     fail if core/core.yaml hqVersion did not strictly
#                     increase vs. origin/<base_ref>. Enforced ONLY on
#                     indigoai-us/hq-core PRs (the workflow gates by repo).
#                     Counterpart to the promote-side stamp that bumps the
#                     value into the PR tree.
#   special-case-files
#                     fail if CHANGELOG.md, MIGRATION.md, or .claude/CLAUDE.md
#                     changed without label "special-case-confirmed".
#   denylist-drift    fail if .leak-scan/denylist.yaml `companies:` keys
#                     diverge from .leak-scan/manifest-snapshot.yaml slugs.
#                     Rule: hq-cmd-promote-hq-core-denylist-source-from-manifest.
#   settings-local-not-ignored
#                     fail if `.claude/settings.local.json` is matched by any
#                     .gitignore rule. Tripwire: a future edit must not
#                     accidentally re-ignore the file.
#
# Exit codes: 0 = clean, 1 = leak/violation found, 2 = script error.
#
# Label-gated modes consult $PR_LABELS (newline-separated) which the workflow
# populates from `gh pr view --json labels`.

set -euo pipefail

mode="${1:-}"
if [[ -z "$mode" ]]; then
  echo "Usage: $0 <denylist|policy-rationale|slugs|users-path|provenance|vendor-public-ok|public-frontmatter|commands-skills-tripwire|core-yaml-locked|core-yaml-version-monotonic|special-case-files|denylist-drift|settings-local-not-ignored>" >&2
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# Determine changed files. In a PR context, GITHUB_BASE_REF is set to the
# target branch (e.g. "main"). Fall back to "main" locally.
base_ref="${GITHUB_BASE_REF:-main}"
git fetch origin "$base_ref" --depth=1 >/dev/null 2>&1 || true

if git rev-parse --verify "origin/$base_ref" >/dev/null 2>&1; then
  if git merge-base "origin/$base_ref" HEAD >/dev/null 2>&1; then
    changed="$(git diff --name-only "origin/$base_ref"...HEAD 2>/dev/null || true)"
  else
    changed="$(git diff --name-only "origin/$base_ref" HEAD 2>/dev/null || true)"
  fi
else
  changed="$(git diff --name-only HEAD~1...HEAD 2>/dev/null || true)"
fi

files=()
while IFS= read -r f; do
  [[ -n "$f" ]] && files+=("$f")
done <<< "$changed"

# Helper: yaml_keys <file> <top_level_key>
# Extracts keys (bare tokens before ":") under a given top-level section.
yaml_keys() {
  local yaml="$1"; local section="$2"
  awk -v sec="$section" '
    $0 ~ "^"sec":"      { in_sec=1; next }
    in_sec && /^[a-zA-Z]/ { in_sec=0 }
    in_sec && /^  [^ #]/ {
      sub(/:.*$/, "")
      gsub(/^  /, "")
      gsub(/^"|"$/, "")
      if (length($0) > 0) print
    }
  ' "$yaml"
}

# Helper: has_label <label>
# Accepts PR_LABELS separated by real newlines OR literal '\n' (GitHub Actions
# `join(..., '\n')` produces a literal backslash-n, not a true newline).
has_label() {
  local needle="$1"
  [[ -z "${PR_LABELS:-}" ]] && return 1
  local normalized="${PR_LABELS//\\n/$'\n'}"
  while IFS= read -r l; do
    [[ "$l" == "$needle" ]] && return 0
  done <<< "$normalized"
  return 1
}

# Helper: read_frontmatter_value <file> <key>
# Echoes the value of a top-level YAML key in the front-matter block, or empty.
read_frontmatter_value() {
  local f="$1"; local key="$2"
  awk -v k="$key" '
    BEGIN { fm=0; depth=0 }
    /^---[[:space:]]*$/ {
      if (fm == 0) { fm=1; next } else { exit }
    }
    fm && $0 ~ "^"k":" {
      sub("^"k":[[:space:]]*", "")
      gsub(/^"|"$/, "")
      gsub(/^'\''|'\''$/, "")
      print
      exit
    }
  ' "$f"
}

case "$mode" in
  denylist)
    deny_file=".leak-scan/denylist.yaml"
    if [[ ! -f "$deny_file" ]]; then
      echo "::error::$deny_file missing" >&2; exit 2
    fi

    patterns=()
    for section in companies persons domains products operational; do
      while IFS= read -r key; do
        [[ -n "$key" ]] && patterns+=("$key")
      done < <(yaml_keys "$deny_file" "$section")
    done

    exceptions=()
    while IFS= read -r key; do
      [[ -n "$key" ]] && exceptions+=("$key")
    done < <(yaml_keys "$deny_file" "exceptions")

    leaks=0
    for f in "${files[@]}"; do
      [[ -z "$f" ]] && continue
      [[ ! -f "$f" ]] && continue
      [[ "$f" == "$deny_file" ]] && continue
      [[ "$f" == "CONTRIBUTING.md" ]] && continue
      [[ "$f" == .leak-scan/manifest-snapshot.yaml ]] && continue
      [[ "$f" == */_digest.md ]] && continue

      for pat in "${patterns[@]}"; do
        while IFS= read -r hit; do
          [[ -z "$hit" ]] && continue
          skip=0
          for ex in "${exceptions[@]}"; do
            if grep -Fq "$ex" <<< "$hit"; then skip=1; break; fi
          done
          if [[ $skip -eq 0 ]]; then
            echo "::error file=$f::denylist hit for '$pat': $hit"
            leaks=$((leaks + 1))
          fi
        done < <(grep -nE "(^|[^A-Za-z0-9_-])${pat}([^A-Za-z0-9_-]|$)" "$f" || true)
      done
    done

    if [[ $leaks -gt 0 ]]; then
      echo "denylist-scan: $leaks leak(s) found" >&2
      exit 1
    fi
    echo "denylist-scan: clean"
    ;;

  policy-rationale)
    patterns=(
      "internal incident"
      "post-mortem"
      "customer complaint"
      "paying customer"
      "legal counsel"
      "confidential"
      "NDA"
      "private repo"
    )

    leaks=0
    for f in "${files[@]}"; do
      [[ -z "$f" ]] && continue
      [[ ! -f "$f" ]] && continue
      [[ "$f" != *policies/*.md ]] && continue

      rationale="$(awk '
        /^## Rationale/ {in_sec=1; next}
        /^## / && in_sec {in_sec=0}
        in_sec {print}
      ' "$f")"

      for pat in "${patterns[@]}"; do
        if grep -Fwiq "$pat" <<< "$rationale"; then
          echo "::error file=$f::policy-rationale contains suspicious phrase '$pat'"
          leaks=$((leaks + 1))
        fi
      done
    done

    if [[ $leaks -gt 0 ]]; then
      echo "policy-rationale-scan: $leaks issue(s) found" >&2
      exit 1
    fi
    echo "policy-rationale-scan: clean"
    ;;

  slugs)
    allow_file=".leak-scan/allowlist.yaml"
    snap_file=".leak-scan/manifest-snapshot.yaml"
    if [[ ! -f "$allow_file" ]]; then
      echo "::error::$allow_file missing" >&2; exit 2
    fi
    if [[ ! -f "$snap_file" ]]; then
      echo "::error::$snap_file missing" >&2; exit 2
    fi

    allowed=()
    while IFS= read -r line; do
      s="$(sed -E 's/^[[:space:]]*-[[:space:]]*//' <<< "$line" | tr -d '"' | awk '{print $1}')"
      [[ -n "$s" ]] && allowed+=("$s")
    done < <(awk '
      /^allowed:/ { in_sec=1; next }
      in_sec && /^[a-zA-Z]/ { in_sec=0 }
      in_sec && /^  - / { print }
    ' "$allow_file")

    is_allowed() {
      local candidate="$1"
      for a in "${allowed[@]}"; do
        [[ "$candidate" == "$a" ]] && return 0
      done
      return 1
    }

    snap_slugs="$(awk '/^slugs:/{f=1;next} f && /^- /{print $2} f && /^[a-zA-Z]/ && !/^- /{f=0}' "$snap_file" | sort -u)"
    snap_public="$(awk '/^public_slugs:/{f=1;next} f && /^- /{print $2} f && /^[a-zA-Z]/ && !/^- /{f=0}' "$snap_file" | sort -u)"
    private_slugs=()
    while IFS= read -r slug; do
      [[ -z "$slug" ]] && continue
      if grep -Fxq "$slug" <<< "$snap_public"; then
        continue
      fi
      if is_allowed "$slug"; then
        continue
      fi
      private_slugs+=("$slug")
    done <<< "$snap_slugs"

    leaks=0
    for f in "${files[@]}"; do
      [[ -z "$f" ]] && continue
      [[ ! -f "$f" ]] && continue
      [[ "$f" == .leak-scan/* ]] && continue

      for slug in "${private_slugs[@]}"; do
        while IFS= read -r hit; do
          [[ -z "$hit" ]] && continue
          echo "::error file=$f::private tenant slug '$slug' leaked: $hit"
          leaks=$((leaks + 1))
        done < <(grep -nE "(^|[^A-Za-z0-9_-])${slug}([^A-Za-z0-9_-]|$)" "$f" || true)
      done
    done

    if [[ $leaks -gt 0 ]]; then
      echo "slug-scan: $leaks private slug(s) found" >&2
      exit 1
    fi
    echo "slug-scan: clean"
    ;;

  users-path)
    # Tripwire: any /Users/<name> path in promotable surfaces leaks the
    # original author's home dir. Hard rule from
    # hq-promote-hq-core-users-path-tripwire — block, never warn.
    leaks=0
    surfaces=(.claude scripts core/scripts core/knowledge/public)
    for s in "${surfaces[@]}"; do
      [[ -e "$s" ]] || continue
      while IFS= read -r hit; do
        [[ -z "$hit" ]] && continue
        echo "::error::$hit"
        leaks=$((leaks + 1))
      done < <(grep -RnE '/Users/[a-z][a-zA-Z0-9._-]*' "$s" 2>/dev/null \
        | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' \
        | grep -v '_digest.md' || true)
    done
    if [[ $leaks -gt 0 ]]; then
      echo "users-path: $leaks /Users/ leak(s) found" >&2
      exit 1
    fi
    echo "users-path: clean"
    ;;

  provenance)
    # Promote step strips '## Provenance' before push. If it survived to
    # staging, the Phase-4 strip skipped or someone hand-edited.
    leaks=0
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      [[ ! -f "$f" ]] && continue
      if grep -q '^## Provenance' "$f"; then
        echo "::error file=$f::policy contains '## Provenance' section (must be stripped on promote)"
        leaks=$((leaks + 1))
      fi
    done < <(find core/policies -maxdepth 2 -type f -name '*.md' 2>/dev/null || true)
    if [[ $leaks -gt 0 ]]; then
      echo "provenance: $leaks file(s) with Provenance" >&2
      exit 1
    fi
    echo "provenance: clean"
    ;;

  vendor-public-ok)
    # Vendor-scoped policies (applies_to: [<non-empty>]) are PRIVATE by
    # default — must opt in with vendor_public_ok: true.
    leaks=0
    for f in "${files[@]}"; do
      [[ -z "$f" ]] && continue
      [[ ! -f "$f" ]] && continue
      [[ "$f" != core/policies/*.md ]] && continue
      [[ "$f" == */_digest.md ]] && continue

      applies_to="$(read_frontmatter_value "$f" "applies_to")"
      [[ -z "$applies_to" || "$applies_to" == "[]" ]] && continue
      # Treat applies_to: hq as "global" (matches HQ convention)
      [[ "$applies_to" == "hq" || "$applies_to" == "[hq]" ]] && continue

      vendor_ok="$(read_frontmatter_value "$f" "vendor_public_ok")"
      if [[ "$vendor_ok" != "true" ]]; then
        echo "::error file=$f::vendor-scoped policy (applies_to: $applies_to) needs 'vendor_public_ok: true' to ship in hq-core"
        leaks=$((leaks + 1))
      fi
    done
    if [[ $leaks -gt 0 ]]; then
      echo "vendor-public-ok: $leaks vendor policy/policies missing opt-in" >&2
      exit 1
    fi
    echo "vendor-public-ok: clean"
    ;;

  public-frontmatter)
    # Re-validate at PR time: every changed policy must declare public: true
    # (or skip-promotion: true to explicitly opt out and trip a separate review).
    leaks=0
    for f in "${files[@]}"; do
      [[ -z "$f" ]] && continue
      [[ ! -f "$f" ]] && continue
      [[ "$f" != core/policies/*.md ]] && continue
      [[ "$f" == */_digest.md ]] && continue

      pub="$(read_frontmatter_value "$f" "public")"
      skip="$(read_frontmatter_value "$f" "skip-promotion")"
      if [[ "$pub" != "true" && "$skip" != "true" ]]; then
        echo "::error file=$f::missing 'public: true' frontmatter (set 'skip-promotion: true' if intentional)"
        leaks=$((leaks + 1))
      fi
    done
    if [[ $leaks -gt 0 ]]; then
      echo "public-frontmatter: $leaks file(s) missing public:true" >&2
      exit 1
    fi
    echo "public-frontmatter: clean"
    ;;

  commands-skills-tripwire)
    # /promote-hq-core deliberately ships only policies. Commands/skills are
    # manual-copy ops; flag any PR that touches them without an explicit label.
    touched=0
    for f in "${files[@]}"; do
      [[ -z "$f" ]] && continue
      if [[ "$f" == .claude/commands/* || "$f" == .claude/skills/* ]]; then
        touched=$((touched + 1))
        echo "::warning file=$f::commands/skills file changed (label 'manual-copy' required)"
      fi
    done
    if [[ $touched -gt 0 ]]; then
      if has_label "manual-copy"; then
        echo "commands-skills-tripwire: $touched file(s) touched, label 'manual-copy' present"
      else
        echo "::error::commands/skills changed without 'manual-copy' label ($touched file(s))" >&2
        exit 1
      fi
    else
      echo "commands-skills-tripwire: clean"
    fi
    ;;

  core-yaml-locked)
    changed_core=0
    for f in "${files[@]}"; do
      [[ "$f" == "core/core.yaml" ]] && changed_core=1
    done
    if [[ $changed_core -eq 1 ]]; then
      version_changed=0
      if git diff -U0 "origin/$base_ref"...HEAD -- core/core.yaml 2>/dev/null \
        | grep -Eq '^[+-]hqVersion:'; then
        version_changed=1
      fi

      if [[ $version_changed -eq 0 ]]; then
        echo "core-yaml-locked: clean (hqVersion unchanged)"
      elif has_label "version-bump"; then
        echo "core-yaml-locked: hqVersion change present, label 'version-bump' applied"
      else
        echo "::error file=core/core.yaml::core/core.yaml hqVersion changed without 'version-bump' label" >&2
        exit 1
      fi
    else
      echo "core-yaml-locked: clean"
    fi
    ;;

  core-yaml-version-monotonic)
    # Every PR to hq-core must strictly increase core/core.yaml.hqVersion.
    # The workflow job gates by repo (only fires on indigoai-us/hq-core), so
    # this script does not need to repeat that check — but we defensively
    # short-circuit if the file is absent (pre-v12 trees) or the base ref
    # cannot be resolved.
    CORE_YAML="core/core.yaml"
    if [[ ! -f "$CORE_YAML" ]]; then
      echo "core-yaml-version-monotonic: skipped ($CORE_YAML missing)"
      exit 0
    fi
    extract_hqv() {
      # $1 = file or '-' for stdin. Echoes the bare hqVersion value, or empty.
      grep -E '^hqVersion:' "$1" 2>/dev/null \
        | head -1 \
        | sed -E 's/^hqVersion:[[:space:]]*"?([0-9A-Za-z.+-]+)"?.*/\1/'
    }
    head_v="$(extract_hqv "$CORE_YAML")"
    if [[ -z "$head_v" ]]; then
      echo "::error file=$CORE_YAML::could not parse hqVersion on HEAD" >&2
      exit 1
    fi
    # Resolve base hqVersion via `git show`. If the base ref is missing or
    # the file did not exist on base (first introduction), accept HEAD as-is.
    if ! git rev-parse --verify "origin/$base_ref" >/dev/null 2>&1; then
      echo "core-yaml-version-monotonic: skipped (origin/$base_ref not fetched)"
      exit 0
    fi
    base_content="$(git show "origin/$base_ref:$CORE_YAML" 2>/dev/null || true)"
    if [[ -z "$base_content" ]]; then
      echo "core-yaml-version-monotonic: pass (no base $CORE_YAML — first introduction; HEAD=$head_v)"
      exit 0
    fi
    base_v="$(printf '%s\n' "$base_content" | grep -E '^hqVersion:' | head -1 \
      | sed -E 's/^hqVersion:[[:space:]]*"?([0-9A-Za-z.+-]+)"?.*/\1/')"
    if [[ -z "$base_v" ]]; then
      echo "::warning::could not parse hqVersion on origin/$base_ref; treating as 0.0.0"
      base_v="0.0.0"
    fi
    if [[ "$head_v" == "$base_v" ]]; then
      echo "::error file=$CORE_YAML::hqVersion unchanged ($head_v) — every PR to hq-core must bump it" >&2
      exit 1
    fi
    # Semver-aware comparator. `sort -V` gets prerelease order wrong
    # (e.g. it ranks `14.2.1-beta.1` ABOVE `14.2.1`, the opposite of
    # semver). Rules: compare x.y.z numerically; if equal, no-prerelease
    # ranks above any prerelease; if both prereleased, fall back to sort -V
    # over the prerelease tail.
    semver_gt() {
      local a="$1" b="$2"
      [[ "$a" == "$b" ]] && return 1
      local a_main="${a%%-*}" a_pre=""
      local b_main="${b%%-*}" b_pre=""
      [[ "$a" == *-* ]] && a_pre="${a#*-}"
      [[ "$b" == *-* ]] && b_pre="${b#*-}"
      local IFS=. ; local ax ay az bx by bz
      read -r ax ay az <<< "$a_main"
      read -r bx by bz <<< "$b_main"
      ax=${ax:-0}; ay=${ay:-0}; az=${az:-0}
      bx=${bx:-0}; by=${by:-0}; bz=${bz:-0}
      if   (( ax > bx )); then return 0
      elif (( ax < bx )); then return 1
      elif (( ay > by )); then return 0
      elif (( ay < by )); then return 1
      elif (( az > bz )); then return 0
      elif (( az < bz )); then return 1
      fi
      # x.y.z equal — prerelease rules
      if [[ -z "$a_pre" && -z "$b_pre" ]]; then return 1; fi
      if [[ -z "$a_pre" ]]; then return 0; fi
      if [[ -z "$b_pre" ]]; then return 1; fi
      local top
      top="$(printf '%s\n%s\n' "$a_pre" "$b_pre" | sort -V | tail -1)"
      [[ "$top" == "$a_pre" && "$a_pre" != "$b_pre" ]]
    }
    if semver_gt "$head_v" "$base_v"; then
      echo "core-yaml-version-monotonic: clean ($base_v → $head_v)"
    else
      echo "::error file=$CORE_YAML::hqVersion went backwards: base=$base_v head=$head_v" >&2
      exit 1
    fi
    ;;

  special-case-files)
    special=(CHANGELOG.md MIGRATION.md .claude/CLAUDE.md)
    touched=()
    for f in "${files[@]}"; do
      for s in "${special[@]}"; do
        [[ "$f" == "$s" ]] && touched+=("$f")
      done
    done
    if [[ ${#touched[@]} -gt 0 ]]; then
      if has_label "special-case-confirmed"; then
        echo "special-case-files: ${#touched[@]} file(s) touched, label 'special-case-confirmed' present (${touched[*]})"
      else
        for t in "${touched[@]}"; do
          echo "::error file=$t::special-case file changed without 'special-case-confirmed' label" >&2
        done
        exit 1
      fi
    else
      echo "special-case-files: clean"
    fi
    ;;

  denylist-drift)
    # Verify .leak-scan/denylist.yaml `companies:` section covers every slug
    # in .leak-scan/manifest-snapshot.yaml. The snapshot is written by HQ
    # /promote-hq-core Phase 4.
    snap=".leak-scan/manifest-snapshot.yaml"
    deny=".leak-scan/denylist.yaml"
    [[ -f "$snap" ]] || { echo "::error::$snap missing — run /promote-hq-core in HQ to write it" >&2; exit 2; }
    [[ -f "$deny" ]] || { echo "::error::$deny missing" >&2; exit 2; }

    snap_slugs="$(awk '/^slugs:/{f=1;next} f && /^- /{print $2} f && /^[a-zA-Z]/ && !/^- /{f=0}' "$snap" | sort -u)"
    snap_public="$(awk '/^public_slugs:/{f=1;next} f && /^- /{print $2} f && /^[a-zA-Z]/ && !/^- /{f=0}' "$snap" | sort -u)"

    deny_companies="$(yaml_keys "$deny" "companies" | sort -u)"

    # Public slugs (e.g. "indigo") MUST NOT appear in denylist.companies.
    # Private slugs MUST appear (or be an explicit exception).
    drift=0
    while IFS= read -r slug; do
      [[ -z "$slug" ]] && continue
      if grep -Fxq "$slug" <<< "$snap_public"; then continue; fi
      if ! grep -Fxq "$slug" <<< "$deny_companies"; then
        echo "::error file=$deny::missing private slug '$slug' (present in manifest snapshot)"
        drift=$((drift + 1))
      fi
    done <<< "$snap_slugs"

    while IFS= read -r slug; do
      [[ -z "$slug" ]] && continue
      if grep -Fxq "$slug" <<< "$snap_public"; then
        echo "::error file=$deny::public slug '$slug' must not appear in denylist.companies"
        drift=$((drift + 1))
      fi
    done <<< "$deny_companies"

    if [[ $drift -gt 0 ]]; then
      echo "denylist-drift: $drift mismatch(es)" >&2
      exit 1
    fi
    echo "denylist-drift: clean"
    ;;

  settings-local-not-ignored)
    # Tripwire: `.claude/settings.local.json` must never be re-added to
    # .gitignore. The file holds per-clone permission deny rules and must
    # ship with every checkout.
    #
    # `git check-ignore -v --no-index` prints the LAST matching rule as
    #   <source>:<linenum>:<pattern>\t<path>
    # and exits 0 on any match (including negations). Parse the pattern:
    # leading `!` = un-ignore (OK); anything else = ignore (FAIL).
    target=".claude/settings.local.json"
    match="$(git check-ignore -v --no-index "$target" 2>/dev/null || true)"
    if [[ -z "$match" ]]; then
      # No rule matched at all — file is tracked by default. OK.
      echo "settings-local-not-ignored: clean (no matching rule)"
    else
      # Strip the trailing "\t<path>" then take the third colon-separated
      # field (the pattern itself). Sources can be paths with no colons
      # other than the linenum separator (e.g. ".gitignore:65:!foo").
      rule="${match%$'\t'*}"
      pattern="${rule#*:*:}"
      if [[ "${pattern:0:1}" == "!" ]]; then
        echo "settings-local-not-ignored: clean (negation rule: $rule)"
      else
        echo "::error file=.gitignore::$target is matched by an ignore rule: $rule" >&2
        echo "settings-local-not-ignored: violation" >&2
        exit 1
      fi
    fi
    ;;

  *)
    echo "Unknown mode: $mode" >&2
    exit 2
    ;;
esac
