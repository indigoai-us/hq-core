---
id: post-bridge-media-workflow
title: Post-Bridge media must use 2-step upload, PATCH for post-creation updates
scope: command
trigger: social-publisher, /post, Post-Bridge API
enforcement: hard
created: 2026-03-31
---

## Rule

When scheduling posts in Post-Bridge, images cannot be added inline. Use the 2-step flow:
1. `POST /v1/media/create-upload-url` → get `media_id` + `upload_url`
2. `PUT` binary to `upload_url`
3. `PATCH /v1/posts/{id}` with `{"media":["media_id"]}`

PATCH works on scheduled posts for updating caption and media. PUT does not exist. De-duplicate uploads when multiple posts share the same image file.

