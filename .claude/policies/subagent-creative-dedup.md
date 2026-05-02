---
id: subagent-creative-dedup
title: Dedup pass needed after sub-agent creative batch generation
scope: global
trigger: batch content generation with sub-agents
enforcement: soft
public: true
---

## Rule

When using parallel sub-agents to generate creative content (social posts, marketing copy, reformatted text), always run a dedup pass on the combined output. Sub-agents receiving both a "definition" and "body text" for reformatting will repeat the definition inside the body ~11% of the time. Check for any substantial line (>40 chars) appearing more than once per entry and remove duplicates.

## Rationale

Simple dedup script fixed all 12.
