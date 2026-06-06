---
id: hq-post-parallel-build-verify
title: Build and Typecheck After Parallel Agent Execution
scope: global
trigger: after any parallel/concurrent agent execution that edits code (swarm, sub-agents, worktrees)
when: parallel || subagent || sub-agent || sub-agents
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
version: 1
created: 2026-04-02
updated: 2026-04-02
source: session-learning
public: true
---

## Rule

1. **After parallel agents complete, ALWAYS run the project's build and typecheck before reporting success.** This is not optional — parallel agents cannot see each other's changes, so cross-agent integration errors are expected, not exceptional.
2. **Run a comprehensive grep for all removed or renamed identifiers** to verify no stale references remain. Sub-agents consistently miss files outside their assigned scope (schema files, component props, infra configs, re-exports).
3. **Verify import paths in all files created by sub-agents.** Sub-agents get relative import paths wrong when creating files in unfamiliar directory structures (e.g., `../../hooks/` instead of `../hooks/`). Run `bun check` / `tsc --noEmit` / equivalent to catch broken imports before proceeding.
4. **Check for cross-agent file conflicts.** If multiple agents edited the same file, read the final state and verify: no duplicate entries, no merge artifacts, consistent formatting, no lost edits.
5. **If build or typecheck fails, fix all errors before proceeding.** Do not leave broken builds for the user to discover. The orchestrator owns the integration — individual agents own their scope.

## Rationale

Sub-agents miss files outside their assigned scope (schema files, component props, infrastructure configs). They get relative import paths wrong. Multiple agents editing the same file without coordination causes formatting breaks and duplicate entries. Integration deprecation removed a constant but `@deprecated` JSDoc still included it in the union type, causing cascading TS errors. A build verification pass after parallel execution catches all of these before they compound.

## Related

- `hq-verify-shared-files-after-parallel-agents` — complementary file-level conflict check (this policy adds the build/typecheck requirement)
- `swarm-post-execution-review` — command-scoped soft enforcement for swarm review
