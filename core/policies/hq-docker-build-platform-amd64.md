---
id: hq-docker-build-platform-amd64
title: Always build Docker images with --platform linux/amd64 for ECS/EC2
when: build || deploy
on: [UserPromptSubmit, AssistantIntent, PreToolUse]
enforcement: soft
version: 1
created: 2026-03-25
updated: 2026-03-25
source: back-pressure-failure
public: true
---

## Rule

ALWAYS use `docker buildx build --platform linux/amd64` when building images for ECS/EC2 deployment. Never use plain `docker build` on Apple Silicon Macs for cloud targets — it produces ARM64 images that fail with "exec format error" on x86_64 instances.

Cross-compilation via QEMU emulation takes 5-10x longer than native builds. Use `--push` flag with buildx to combine build+push in one step. Cached layers make subsequent builds fast (~10s for code-only changes).

## Rationale

hq-cloud deployment session (2026-03-25): host Docker image built on M-series Mac produced ARM64 binary. EC2 instance (t3.medium, x86_64) crashed immediately with `exec format error` on container start. ECS showed healthy container instances but tasks kept failing with exit code 255. Root cause was invisible until SSH-ing to EC2 and checking `docker logs`.
