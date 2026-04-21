---
id: verify-routes-after-parallel-execution
title: Verify nav routes exist after parallel story execution
scope: command
trigger: /run-project, /execute-task
enforcement: soft
---

## Rule

After parallel story execution completes, grep nav components for route hrefs and verify each has a corresponding `page.tsx`. Parallel agents add nav links in one story but may skip creating the page route in their story scope.

## How to apply

In post-execution verification (before PR), run: `grep -oP 'href: "[^"]*"' src/components/ui/nav.tsx | while read href; do path="src/app${href}/page.tsx"; [ -f "$path" ] || echo "MISSING: $path"; done`
