---
id: run-project-file-locks-stale
title: Orchestrator completion leaves .file-locks.json modified
scope: command
command: run-project
trigger: /run-project {slug} completes (all stories shipped) and the orchestrator exits
enforcement: soft
version: 1
created: 2026-04-10
updated: 2026-04-10
---

## Rule

When `scripts/run-project.sh` finishes a project with all stories passing, the target repo's `.file-locks.json` is often left in a **modified-but-empty** state — the working tree shows it as `M` even though every `checkedOutBy` entry has been released. This is a stale-lock artifact from the final story's cleanup path.

**This is non-blocking but messy.** It creates one of two problems:

1. The next session sees `.file-locks.json` in `git status --porcelain` and either commits noise or has to decide whether to revert. Committing noise pollutes repo history with `chore: release US-XXX file locks` style entries that aren't doing real work.
2. The orchestrator's next cold start reads a dirty lock file and has to either trust it (risk) or reset it (losing in-progress locks from a concurrent session).

**Mitigation:**

- After an orchestrator completion, the "landing" / "clean working tree" story (e.g. `US-L01`) should unconditionally do:
  ```bash
  git checkout -- .file-locks.json 2>/dev/null || true
  ```
  to revert to the committed baseline.
- Do **not** commit `.file-locks.json` release diffs as part of the feature branch — they are not part of the shipped work.
- If you need to inspect what the stale file looked like, diff it against `HEAD:.file-locks.json` before reverting.

**Fix at source:** `scripts/run-project.sh` final cleanup should `git checkout -- .file-locks.json` on completion if the file is tracked, or delete it if it isn't. Need to confirm which state the repo expects.

## Related

- `.claude/policies/run-project-progress-txt-no-commit-misleading.md` — sibling `progress.txt` artifact leak
- `.claude/policies/run-project-dry-run-branch-leak.md` — sibling orchestrator cleanup gap
- `scripts/run-project.sh` — orchestrator final cleanup path
