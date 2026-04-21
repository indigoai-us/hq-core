---
id: run-project-name-matches-dir
title: run-project.sh project name must match directory name
scope: command
trigger: /run-project
enforcement: hard
created: "2026-04-02"
---

## Rule

When invoking `scripts/run-project.sh` or `/run-project`, the project argument must exactly match the directory name under `companies/*/projects/{name}/`. Do not append `-prd` or other suffixes. The script resolves PRDs by scanning `companies/*/projects/$PROJECT/prd.json` literally.

