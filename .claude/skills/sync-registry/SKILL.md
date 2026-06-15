---
name: sync-registry
description: Rebuild a company resource registry index.
allowed-tools: Bash, Read
---

# /sync-registry

Regenerate a company's resource-registry index (`registry.yaml`) from its `resources/*.yaml` files.

## Usage

`/sync-registry [company-slug]` — slug optional; falls back to cwd / handoff context when omitted.

## Workflow

```bash
COMPANY="${1:-$(jq -r '.active.slug // empty' workspace/threads/handoff.json 2>/dev/null)}"
[ -z "$COMPANY" ] && echo "no company resolved" && exit 1
cd "companies/$COMPANY/registry" && bash scripts/generate-index.sh
```

Writes the regenerated `registry.yaml` and exits. See `companies/{co}/registry/scripts/generate-index.sh` for the index shape.
