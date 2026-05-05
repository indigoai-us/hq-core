---
id: hq-jq-argjson-validate-json-or-default
title: Validate JSON before passing to `jq --argjson` (wrap with `ensure_json_array`)
scope: global
trigger: When assembling JSON programmatically in a shell script and passing it into `jq --argjson`
enforcement: soft
public: true
version: 1
created: 2026-04-22
updated: 2026-04-22
source: session-learning
---

## Rule

ALWAYS: `jq --argjson` requires valid JSON — empty strings cause `invalid JSON text passed to --argjson`. Wrap any JSON assembled from a helper function that might return empty with an `ensure_json_array()` helper that validates via `jq empty` and returns `[]` on invalid input:

```bash
ensure_json_array() {
  local v="$1"
  if [ -z "$v" ] || ! printf '%s' "$v" | jq empty >/dev/null 2>&1; then
    printf '%s' '[]'
  else
    printf '%s' "$v"
  fi
}

# Usage
results=$(ensure_json_array "$(scan_for_artifacts)")
jq --argjson r "$results" '. + {found: $r}' config.json
```

## Rationale

Discovered while building `.claude/skills/import-claude/scan.sh`. A helper that returns zero results produced an empty string rather than `[]`, crashing `jq --argjson` with a cryptic parse error. The fix surfaces invalid-JSON conditions early and gives downstream jq filters a consistent shape to work with (always an array, never undefined). `jq empty` is the canonical validation primitive — it exits 0 on valid JSON and non-zero otherwise without producing output.
