---
id: dual-codex-review-pattern
title: Run both Claude and gpt-5.4 codex reviews for high-value PRs
scope: command
trigger: /review, codex review, pre-merge review
enforcement: soft
version: 1
created: 2026-03-27
source: session-learning
---

## Rule

For high-value PRs (10+ stories, security-sensitive code, new feature areas), run **both** a Claude-based review and `codex review --base {branch}` (gpt-5.4). They catch complementary issue classes:

- **Claude review**: Security vulnerabilities (auth, cron bypass, SQL injection, hardcoded credentials), logic errors, input validation
- **gpt-5.4 Codex**: End-to-end data flow correctness (data stored vs. expected types, status filter mismatches, incomplete pipeline stages, monitoring gaps)

Running only one reviewer leaves blind spots. Total cost is modest; catching a data-flow P1 before deploy is worth it.

```bash
# Run in parallel
claude -p "Review diff vs origin/main in $(pwd)..." &
codex review --base origin/main &
wait
```

