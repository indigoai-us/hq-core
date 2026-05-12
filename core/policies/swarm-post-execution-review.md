---
id: swarm-post-execution-review
title: "Swarm execution requires post-execution integration review + P1 fix PRD"
scope: command
trigger: "/run-project swarm, parallel agent execution, batch orchestration"
enforcement: soft
version: 1
created: 2026-03-26
public: true
---

## Rule

After swarm/parallel execution of 5+ stories, ALWAYS:
1. Run `pnpm tauri dev` (or equivalent boot command) to verify the app starts
2. Run independent code reviews (Codex or manual) on each story
3. Produce a consolidated P1 triage report grouping issues by category (security, broken features, UX)
4. Create a follow-up PRD for P1 fixes with cross-integration e2e tests per story
5. The P1 fix PRD's final story should be a cross-integration verification gate

Swarm agents work in isolation and don't test cross-feature interactions. Expect ~60-80% of features to have structural P1 bugs after swarm execution. The highest-leverage fix is usually a single shared dependency (e.g., isTauri() detection) that unblocks many downstream features.

## Rationale

Most features existed in code but didn't work end-to-end. Config schema errors blocked app startup entirely. Without post-execution review, shipped code would have been non-functional.
