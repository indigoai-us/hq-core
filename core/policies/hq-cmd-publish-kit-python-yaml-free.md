---
id: hq-cmd-publish-kit-python-yaml-free
title: Publish-Kit Python Helpers Must Be yaml-Module-Free
scope: command
trigger: /publish-kit scrub helpers that parse denylist YAML
enforcement: soft
public: true
version: 1
created: 2026-04-16
updated: 2026-04-16
source: session-learning
---

## Rule

Any Python helper invoked by `/publish-kit` (denylist scrub, policy strip, verification) MUST NOT `import yaml`. macOS system Python 3 ships without the PyYAML module and `pip install` is not a prerequisite for running the pipeline. Instead, hand-parse the narrow slice of YAML that the helper actually needs using `re` + string splits.

- The denylist file (`.claude/scrub-denylist.yaml`) is structurally simple: top-level keys (`companies:`, `products:`, `persons:`, `domains:`, `repos:`, `exceptions:`), each mapping to a flat list of mapping entries with known keys.
- A 30-line regex-based parser covers it without any third-party dependency.
- If a future helper genuinely needs full YAML semantics, isolate that helper behind an explicit dependency check (`python3 -c 'import yaml' || { echo "install PyYAML"; exit 1; }`) so the failure is loud and actionable — don't let an `ImportError` halt the pipeline mid-release.

## Rationale

`/publish-kit` runs from the main driver session, not a provisioned CI environment. Adding a hidden `pip install pyyaml` prerequisite surprises the operator and breaks the pipeline's promise of "runs anywhere Python 3 exists." Hand-parsing the small structured input is cheap; a dependency gate is the next-cheapest option; silent `ImportError` is the worst.
