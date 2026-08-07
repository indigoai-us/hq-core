---
id: hq-write-tool-blocked-on-repos
title: "Write/Edit is blocked on repos/ paths — use a worktree for code, Bash heredoc for knowledge"
when: always
on: [SessionStart]
enforcement: hard
version: 4
created: 2026-05-24
updated: 2026-08-06
source: session-learning
public: true
---

## Rule

Do NOT use the Write or Edit tool for any file under `repos/` — including symlinks that resolve there. A PreToolUse hook blocks:

1. Direct paths like `repos/private/knowledge-{co}/foo.md`
2. Symlinks that resolve into repos/ (e.g. `companies/{co}/knowledge/foo.md` → `repos/private/knowledge-{co}/foo.md`)

**Where this hook lives.** `core/hooks/PreToolUse/10-Edit,Write,MultiEdit--block-repo-edits-use-worktree.sh`, shipped with hq-core. It was contributed by `hq-pack-engineering` between v15.0.0 and the merge that absorbed that pack back into core, so every host now has the block rather than only those who installed the pack. The other hq-core guards (`block-core-writes.sh`, `block-core-writes-bash.sh`, `protect-core.sh`) protect `core/`, `.claude/`, and the charter — not `repos/`.

For **code repos**, you MUST use a git worktree and edit there — that is the intended (and only sanctioned) workflow for code that ships. Never edit repo files in place. Create the worktree with the shipped helper `core/scripts/worktree.sh`:

```bash
bash core/scripts/worktree.sh --name <kebab-slug> --source <repo-path>
# e.g. bash core/scripts/worktree.sh --name signals-codex --source repos/private/hq-pro
```

It cuts a fresh branch under `workspace/worktrees/{repo}/{name}/` off `origin/<default-branch>`, leaving the source repo's working tree and refs untouched. The worktree lives under `workspace/`, not `repos/`, so the Write/Edit block does not apply inside it — edit, commit, and open the PR from there. (`/personal:worktree` wraps the same script.)

For **knowledge repos** (per-company knowledge under `repos/private/knowledge-{co}/` symlinked from `companies/{co}/knowledge/`), worktree discipline is overkill — these are Obsidian-style notes the user edits by hand. Use **Bash with heredoc** to write the file, then commit inside the knowledge repo:

```bash
cat > companies/{co}/knowledge/notes.md <<'EOF'
# Content here
EOF
( cd repos/private/knowledge-{co} && git add notes.md && \
  git -c user.name="..." -c user.email="..." commit -q -m "msg" )
```

**`HQ_BYPASS_REPO_WORKTREE` does not exist and will not be added.** It was once documented here as a Write-tool escape hatch; no shipped hook has ever read it, and that is now a deliberate decision rather than an outstanding task. There is no env-var bypass for this guard. Regression coverage: `core/scripts/tests/block-repo-edits-strict.test.sh` asserts that setting it changes nothing.

**There is exactly one sanctioned worktree location: `workspace/worktrees/`.** Nothing under `repos/` is a valid Edit/Write target — not a plain checkout, not a knowledge tree, and not a git worktree someone created there. The guard deliberately carries no structural exemption for "but this really is a worktree" or "but this really is a knowledge repo": each such check is a hole, and each is spoofable or liable to decay. Anything that needs to write under `repos/` creates its worktree in the sanctioned location instead — `core/scripts/worktree.sh` and the run-project orchestrator both do.

## Rationale

The hook resolves symlinks before its prefix check, so a knowledge symlink path (`companies/{co}/knowledge/...`) is equivalent to its `repos/`-prefixed target and trips the same block. That is correct — the write really does land in `repos/` — but "spin up a worktree" is useless advice for a notes repo with no PR workflow, so the block message routes knowledge writes to the Bash redirect instead of leaving the reader to guess.

The guard stays absolute rather than growing exemptions because the pressure to add them is constant and each one is permanent. The right response to "I keep hitting this" is to remove the reason: the orchestrator now creates its worktrees under `workspace/worktrees/` rather than as siblings inside `repos/`, and the active-run hooks tell you to do the same.

Do not confuse that pack hook with hq-core's own shipped guards, and do not assume symlink resolution or `master-hook.sh` dispatch. hq-core's guards (`block-core-writes.sh`, `block-core-writes-bash.sh`, `protect-core.sh`) are dispatched through `hook-gate.sh`, not `master-hook.sh`, and they normalize paths with `hq_normpath` (`core/scripts/hook-lib.sh`) — a purely **lexical** normalizer that collapses `.` and `..` but resolves no symlinks at all. They also guard `core/`, `.claude/`, and the charter, not `repos/`.

Two distinct paths, by repo kind:
- **Code that ships** → a worktree (`core/scripts/worktree.sh`). The worktree gives you an isolated branch off `origin/main` under `workspace/`, so edits, commits, and the eventual PR never touch the live checkout and never hit the repos/ Write block.
- **Knowledge notes** → Bash heredoc, committed in place. Worktree ceremony is overkill for hand-authored notes.
