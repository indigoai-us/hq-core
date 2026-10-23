---
id: hq-docker-in-docker-path-translation
title: Docker-in-Docker bind mounts require host-side path translation
when: docker
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
version: 1
created: 2026-03-25
updated: 2026-03-25
source: back-pressure-failure
public: true
---

## Rule

When a container spawns sibling containers via the mounted Docker socket (`/var/run/docker.sock`), bind-mount source paths must use the **outer host filesystem paths**, NOT the container-internal paths.

Example: if the host container maps `/mnt/data` → `/data`, and the container writes to `/data/ipc/`, the sibling container mount must use `-v /mnt/data/ipc/:/ipc/` (the EC2 path), NOT `-v /data/ipc/:/ipc/` (the container path).

Use a separate env var (e.g., `HOST_DATA_DIR`) to carry the outer host path. Container code reads/writes via `DATA_DIR` (its internal mount) but constructs bind-mount args using `HOST_DATA_DIR`.
