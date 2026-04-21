---
id: linear-scan-check-existing-prds
title: Linear scan must check existing PRDs before recommending new ones
scope: command
trigger: /check-linear-voyage, voyage-linear-scan scheduled task
enforcement: hard
applies_to: [linear]
---

## Rule

Before recommending a new PRD from a Linear scan, always check `companies/{product}/projects/` for existing PRDs that cover the same Linear issues. Use `ls companies/{product}/projects/` and read matching `prd.json` files to check `linearIssueId` fields against scan results.

