#!/usr/bin/env bash

set -uo pipefail

log_error() {
  printf 'auto-acl-share-suggestion: %s\n' "$*" >&2
}

is_hq_root() {
  [ -n "${1:-}" ] && [ -d "$1/core" ] && [ -d "$1/.claude" ]
}

walk_up_to_hq_root() {
  local dir="${1:-}"
  while [ -n "$dir" ]; do
    if is_hq_root "$dir"; then
      printf '%s\n' "$dir"
      return 0
    fi
    [ "$dir" = "/" ] && break
    dir="$(dirname "$dir")"
  done
  return 1
}

resolve_hq_root() {
  local script_dir root
  if is_hq_root "${CLAUDE_PROJECT_DIR:-}"; then
    printf '%s\n' "$CLAUDE_PROJECT_DIR"
    return 0
  fi
  if root="$(walk_up_to_hq_root "$PWD")"; then
    printf '%s\n' "$root"
    return 0
  fi
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  if root="$(walk_up_to_hq_root "$script_dir")"; then
    printf '%s\n' "$root"
    return 0
  fi
  return 1
}

main() {
  local input session_id hq_root helper pending reminder

  input="$(cat 2>/dev/null || echo '{}')"
  session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
  [ -n "$session_id" ] || exit 0

  hq_root="$(resolve_hq_root)" || {
    log_error "unable to resolve HQ root"
    exit 0
  }

  helper="$hq_root/core/scripts/share-suggestion-state.sh"
  [ -f "$helper" ] || exit 0

  pending="$("$helper" peek "$session_id" || true)"
  [ -n "$pending" ] || exit 0

  # jq, not python3: this hook already hard-depends on jq for session_id above,
  # while python3 is absent on many Windows machines (and the Store alias stub
  # there passes `command -v` then fails every call). `nes` reproduces Python's
  # truthiness for the `or` chains below — jq's `//` only falls through on null
  # and false, so an empty-string field would otherwise win over its fallback.
  reminder="$(
    printf '%s' "$pending" | jq -r '
      def nes(v): if (v | type) == "string" and (v | length) > 0 then v else null end;
      def truthy(v): (v != null) and (v != false) and (v != "") and (v != 0)
        and (v != []) and (v != {});
      if (type != "object") or (length == 0) or truthy(.shown_at) then empty
      else
        . as $p
        | (if (.artifact | type) == "object" then .artifact else {} end) as $a
        | (if (.candidate_hints | type) == "object" then .candidate_hints else {} end) as $h
        | (if (.recipients | type) == "array" then .recipients else [] end) as $r
        | (if ($h.local_people | type) == "array" then $h.local_people else [] end) as $lp
        | (if ($r | length) > 0 then $r else $lp end) as $people
        | [ $people[0:3][]
            | select(type == "object")
            | (nes(.name) // nes(.id))
            | select(. != null) ] as $names
        | (if ($names | length) > 0 then ($names | join(", "))
           else "no exact recipients yet" end) as $rtext
        | (nes($a.fingerprint) // "") as $fp
        | (nes($a.path) // nes($a.label) // $fp[0:12]) as $aref
        | (nes($p.recommended_surface) // nes($a.surface) // "vault") as $surface
        | (nes($p.suggested_permission) // nes($a.permission) // "read") as $perm
        | [ "<hq-share-suggestion>",
            "A share suggestion is pending.",
            "Artifact: \($aref)",
            "Fingerprint: \($fp)",
            "Recommended surface: \($surface)",
            "Top candidate recipients: \($rtext)",
            "Suggested permission: \($perm)",
            "Next turn: ask exactly one structured decision with these options:",
            "- Approve (recommended)",
            "- Edit recipients",
            "- Not now",
            "- Never suggest this again",
            "If approved, execute only with existing primitives: use `hq files share --permission read` for vault artifacts, or deploy access-policy/access-mode for deploy surfaces.",
            "Do not persist any resulting capability URL.",
            "</hq-share-suggestion>" ]
        | join("\n")
      end' 2>/dev/null || true
  )"

  [ -n "$reminder" ] || exit 0
  printf '%s\n' "$reminder"
  "$helper" mark-shown "$session_id" >/dev/null || true
}

main "$@" || {
  log_error "internal error"
  exit 0
}
exit 0
