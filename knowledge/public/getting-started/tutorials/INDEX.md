# Tutorials

Interactive lessons run via `/tutorial`. No static lesson files — the command reads from *Build Your Own AGI* and HQ reference files at runtime, adapting to the user's actual HQ state.

Ordering follows user feedback: **principles and daily workflow first**, orchestration and worker authoring last. Most users won't need `/run-project` until they've lived in HQ for a while.

## Topics

| # | Slug | Book Ch | Focus | What You Learn |
|---|------|---------|-------|----------------|
| 1 | `principles` | 3 | Foundations | Plan mode, fresh context, back pressure — the Ralph *mindset* |
| 2 | `hq` | 4 | Foundations | Daily workflow (`/startwork` → work → `/handoff`) + folder orientation |
| 3 | `knowledge` | 6 | Daily practice | Hot vs cold channels, qmd search, knowledge gardens |
| 4 | `session-hygiene` | 8 | Daily practice | `/checkpoint`, `/handoff`, thread files, context degradation |
| 5 | `context-management` | 4+8 | Daily practice | Context Diet, token optimization, 60%/75% advisories |
| 6 | `projects` | 7 | Daily practice | PRDs, `/idea` → `/plan`, acceptance criteria as back pressure |
| 7 | `scaling` | 9 | Daily practice | Parallel sessions, company isolation via manifest.yaml |
| 8 | `ralph-loop` | 3+7 | Advanced | `/run-project` orchestration — principles in action (mechanics) |
| 9 | `workers` | 5 | Advanced | `/newworker`, worker.yaml, `/learn` training, skills |

**Ordering discipline:** Topics 1 (`principles`) and 8 (`ralph-loop`) both draw from Ch 3 but split cleanly — Topic 1 is mindset, Topic 8 is `/run-project` mechanics. Topic 1 never mentions orchestration; Topic 8 assumes the principles are internalized.

## Usage

```
/tutorial                    # Show topic menu with recommendation
/tutorial principles         # Jump to specific topic
/tutorial hq                 # Slug aliases work too (workflow, daily, folder)
/tutorial ralph-loop         # Orchestration mechanics (Topic 8, not principles)
```

**Recommended starting point by HQ maturity:**
- FRESH (no workers/projects) → `principles`
- ACTIVE (has workers/projects) → `session-hygiene`
- ADVANCED (3+ companies) → `ralph-loop`

## Related

- `quick-start-guide.md` — Conceptual overview (read, not interactive)
- `learning-path.md` — Full 11-module self-paced progression
- `cheatsheet.md` — Daily reference card
- Book: configure `{your-book-site}` in `agents-profile.md` if you have a companion book
