---
id: hq-jq-slurpfile-not-argjson-for-large-aggregates
title: Use `jq --slurpfile` (not `--argjson`) for large JSON aggregates
scope: global
trigger: When passing large JSON aggregates (scan results, file-system listings, multi-item batches) to `jq` from shell scripts
enforcement: soft
public: true
version: 1
created: 2026-04-22
updated: 2026-04-22
source: session-learning
---

## Rule

NEVER: Pass large aggregates to `jq --argjson` on the command line. macOS `ARG_MAX` (~256KB) blows up on real-filesystem scans with:

```
execve: Argument list too long
```

Use `--slurpfile` instead — it reads from a file descriptor and sidesteps the exec-arg limit:

```bash
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf '%s' "$big_json" > "$tmp/data.json"
jq --slurpfile data "$tmp/data.json" '.[0] | ...' input.json
```

Note `--slurpfile` wraps the file contents in an outer array (hence `$data[0]`).

## Rationale

Discovered while building `.claude/skills/import-claude/scan.sh`. Fixture tests passed with small inputs, but real filesystem scans produced ~400KB JSON blobs that exceeded `ARG_MAX`. The failure mode is a shell error, not a `jq` error — easy to misdiagnose as a jq filter bug. `--slurpfile` reads via an open file descriptor, so there's no arg-list pressure regardless of input size. Pair with `mktemp -d` + `trap rm -rf` for automatic cleanup.
