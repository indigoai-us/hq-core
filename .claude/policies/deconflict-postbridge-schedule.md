---
id: deconflict-postbridge-schedule
title: Always check existing Post-Bridge schedule before batch scheduling
scope: command
trigger: social-publisher, schedule-batch, post
enforcement: hard
created: 2026-03-31
---

## Rule

Before scheduling a batch of posts via Post-Bridge:
1. Query `GET /v1/posts?status=scheduled&limit=100` (paginate if >100) to get ALL existing scheduled posts
2. Map existing posts by date and account ID to identify occupied time slots
3. Schedule new posts only in free slots — avoid same-account same-hour collisions
4. Curious Minds posts go to BOTH accounts (34528 + 34531) every 3 days — account for this when scheduling X-only or LinkedIn-only posts

