---
id: prd-json-validation-post-task
title: Validate PRD JSON after sub-agent story writes
scope: command
trigger: run-project, execute-task
enforcement: hard
created: 2026-03-26
---

## Rule

After any sub-agent writes to prd.json (setting `passes`, adding `notes`, updating `files`), validate the JSON is parseable before proceeding to the next story. Use: `python3 -c "import json; json.load(open('prd.json'))"`.

If validation fails, fix the JSON (typically a missing closing `}` on the last-modified story object) before continuing.

