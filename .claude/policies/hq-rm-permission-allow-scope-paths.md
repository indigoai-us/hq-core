---
id: hq-rm-permission-allow-scope-paths
title: Never broadly allow `Bash(rm:*)` — scope rm permissions to explicit path prefixes
scope: global
trigger: When adding `rm`, `rm -f`, `rm -rf`, or any delete-family entry to `.claude/settings.json` or `.claude/settings.local.json` permission allow/ask lists
enforcement: hard
tier: 1
public: true
version: 1
created: 2026-04-20
updated: 2026-04-20
source: session-learning
---

## Rule

Never add `Bash(rm:*)`, `Bash(rm -rf:*)`, or any unrestricted `rm` wildcard to the `permissions.allow` list in `.claude/settings.json` or `.claude/settings.local.json`.

Always scope `rm` allows to a specific path prefix that matches the exact shape the caller will invoke:

```jsonc
// GOOD — scoped to a known prefix, rm -rf with arbitrary path still prompts
"Bash(rm /tmp/handoff-*)",
"Bash(rm -f /tmp/handoff-*)",
"Bash(rm -rf workspace/.context-warnings/*)",

// BAD — allows rm -rf against the entire filesystem without prompting
"Bash(rm:*)",
"Bash(rm -rf:*)",
```

When a skill needs to delete multiple path shapes (e.g. `/tmp/handoff-prompt-*` and `/tmp/handoff-stderr-*`), list each shape separately rather than collapsing to `Bash(rm:*)`.

## Rationale

Claude Code permission rules are literal command-prefix matchers (see `hq-permission-rules-literal-subcommand-prefixes`). A broad `Bash(rm:*)` entry matches *every* `rm` invocation — including `rm -rf ~`, `rm -rf repos/`, `rm -rf companies/`. The ask gate that would otherwise catch a destructive command is bypassed silently.

Scoping by path prefix preserves the ask gate for any `rm` that doesn't match the known-safe shape. The cost is listing 1–3 explicit entries per skill instead of one wildcard. That cost is trivial compared to the blast radius of a single errant `rm -rf` slipping through.

Composes with `hq-settings-local-for-personal-allows` (which file to edit) and `hq-jq-atomic-edits-large-json-configs` (how to add entries safely to large settings files).
