---
id: hq-sub-agent-summary-verify-via-grep
title: Verify sub-agent structural claims about large files via direct grep
scope: global
trigger: When a sub-agent (Explore, Task, general-purpose) reports the presence or absence of entries in a file larger than the Read token cap (~25K tokens), before acting on that claim
when: subagent || subagents || sub-agent || sub-agents
on: [UserPromptSubmit, AssistantIntent]
enforcement: soft
public: true
version: 1
created: 2026-04-18
updated: 2026-04-18
source: session-learning
---

## Rule

Never trust a sub-agent's summary of a large config file (>25K Read-token cap) without direct grep verification in the parent session. Before designing, editing, or reporting based on the sub-agent's structural claims, run an exact grep for the entries the agent named — including punctuation and escaping. Example verification patterns:

```bash
# Sub-agent claims Bash(git:*), Bash(mkdir:*), Bash(rm:*) exist in allow[]:
grep -nE '"Bash\(git:\*\)"|"Bash\(mkdir:\*\)"|"Bash\(rm:\*\)"' .claude/settings.local.json

# Sub-agent claims a tool block is missing:
grep -c '"Edit(workspace/threads/' .claude/settings.local.json
```

If the grep result contradicts the sub-agent's claim, discard the summary entirely and reread the relevant region of the file with `Read offset/limit` in the parent session before proceeding.

## Rationale

Read-too-large errors truncate context silently for sub-agents. An Explore agent, confronted with a settings file that exceeded its Read budget, reported that `Bash(git:*)`, `Bash(mkdir:*)`, `Bash(rm:*)` were already present in HQ's `permissions.allow` array. Direct grep from the parent session showed none of those entries existed — the agent had inferred their presence from narrower patterns it *could* read, or filled in shape from prior context.

Designing around a wrong structural claim wastes tokens and produces incorrect edits. Grep is ~100 tokens and definitive; an agent summary of a truncated file is hundreds of tokens and potentially hallucinated. Always prefer the exact check.

Composes with `hq-glob-scoped-path` and `hq-no-glob-discovery` (both about using exact tools over broad searches) — same principle at a different layer.
