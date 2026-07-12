---
id: hq-jq-atomic-edits-large-json-configs
title: Use `jq` for atomic structural edits to JSON config files larger than the Read token cap
when: settings.local.json || .mcp.json || package.json
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
public: true
version: 1
created: 2026-04-18
updated: 2026-04-18
source: session-learning
---

## Rule

Use `jq` for atomic structural edits to large JSON config files. The Edit tool requires reading the file first, which fails over the ~25K token cap and prevents surgical in-place changes. `jq` reads, transforms, and writes in a single pass without loading the file into session context.

Standard pattern:

```bash
FILE=.claude/settings.local.json

# 1. Timestamped backup
cp "$FILE" "${FILE}.pre-edit-$(date +%Y%m%d-%H%M%S).bak"

# 2. Atomic transform: filter legacy + append new + set sibling field
jq '
  .permissions.allow |= (
    map(select(startswith("Bash(git ") | not))  # drop narrow legacy shapes
    + ["Bash(git:*)", "Bash(mkdir:*)"]          # append broadened wildcards
  )
  | .permissions.ask = (
      (.permissions.ask // [])
      + ["Bash(git push --force:*)", "Bash(git reset --hard:*)"]
      | unique
    )
' "$FILE" > "${FILE}.tmp"

# 3. Validate before swap
jq empty "${FILE}.tmp" || { echo "invalid JSON, aborting"; exit 1; }

# 4. Compare entry counts pre/post
echo "allow: $(jq '.permissions.allow | length' "$FILE") → $(jq '.permissions.allow | length' "${FILE}.tmp")"
echo "ask:   $(jq '.permissions.ask   | length' "$FILE") → $(jq '.permissions.ask   | length' "${FILE}.tmp")"

# 5. Swap in atomically
mv "${FILE}.tmp" "$FILE"
```

Never concatenate or append to large JSON configs with `>>`, `sed`, or `echo` — they will corrupt structure. Always use `jq` with validation + backup.

## Rationale

Large JSON configs ($>$25K tokens) hit the Read tool's cap, which blocks the Read-then-Edit loop used for surgical changes. Heredoc rewrites and `sed` injections risk silent corruption (trailing commas, unbalanced braces, wrong array level). `jq` is the only tool that composes filter + append + set + validate atomically, and it never loads the file into the assistant's session — keeping context burn at ~200 tokens for the commands instead of 25K+ for the file body.

The explicit backup is load-bearing: Claude Code's `.settings.local.json` is personal-scope and not always in git, so an ad-hoc `.bak` is the only rollback path. The `jq empty` validation catches malformed output before the `mv` makes it visible to the next session. Count comparison (`length` before vs after) surfaces "oops, I dropped 40 entries" before it becomes a mystery bug.

Composes with `hq-settings-local-for-personal-allows` (which file to edit) and `hq-permissions-fan-out-edit-write-multiedit` (what entries to emit) — this policy governs *how* to apply those structural changes safely.
