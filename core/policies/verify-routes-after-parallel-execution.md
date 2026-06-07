---
id: verify-routes-after-parallel-execution
title: Verify nav routes exist after parallel story execution
scope: command
trigger: /run-project, /execute-task
when: /run-project || /execute-task
on: [UserPromptSubmit]
enforcement: soft
public: true
---

## Rule

After parallel story execution completes, grep nav components for route hrefs and verify each has a corresponding `page.tsx`. Parallel agents add nav links in one story but may skip creating the page route in their story scope.

## Rationale

{product}-{your-project}-v3: US-002 added 7 nav links, later stories were supposed to create the pages. 5/7 were created but `/competitive` and `/content-perf` were missed — the stories created API routes and lib code but not the page components. Codex flagged this but incorrectly assumed "resolved by later stories."

## How to apply

In post-execution verification (before PR), run: `grep -oP 'href: "[^"]*"' src/components/ui/nav.tsx | while read href; do path="src/app${href}/page.tsx"; [ -f "$path" ] || echo "MISSING: $path"; done`
