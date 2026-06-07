---
id: hq-docker-in-docker-path-translation
title: Docker-in-Docker bind mounts require host-side path translation
scope: global
trigger: when spawning sibling containers via Docker socket from inside a container
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

## Rationale

hq-cloud deployment (2026-03-25): host container wrote IPC request files to `/data/ipc/` (container-internal), then passed `-v /data/ipc/:/ipc/` to agent containers. Docker daemon on EC2 looked for `/data/ipc/` on the EC2 filesystem (not inside the container), found nothing, mounted an empty directory. Agent containers saw empty `/ipc/` and failed with "IPC request not found". Fixed by adding `HOST_DATA_DIR=/mnt/hq-cloud-data` and using it for all bind-mount source paths.
