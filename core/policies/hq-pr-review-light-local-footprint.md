---
id: hq-pr-review-light-local-footprint
title: Local PR reviews reuse one cached checkout per repo, run only affected checks, and clean up
when: (review || reviewer || conductor) && (pr || pull || clone || checkout || /tmp || install || vitest || tsc || suite)
on: [UserPromptSubmit, AssistantIntent, PreToolUse]
enforcement: hard
tier: 1
version: 1
created: 2026-10-22
updated: 2026-10-22
source: owner-directive
public: true
tags: [review, conductor, performance, disk]
---

## Rule

When you review someone else's pull request locally (`/review` on a PR, a
reviewer rota, a conductor's review duty), the review stays thorough and the
machine footprint stays small. Use `core/scripts/review-checkout.sh`.

1. **One cached checkout per repo.** Run
   `bash core/scripts/review-checkout.sh prepare --repo OWNER/NAME --pr N`.
   It keeps a single checkout at `workspace/review-cache/<owner>__<name>`,
   fetches `pull/N/head` into it and checks it out. Never `git clone` a new
   copy per PR or per PR head, and never put review checkouts in `/tmp`.
   One review owns the checkout from `prepare` until its `cleanup`. While it
   does, `prepare` for another PR of that repo exits 73 and names the active
   PR. Wait for that review to finish, or run its `cleanup` if it was
   abandoned. Do not work around the refusal with a fresh clone.
2. **Install only when a lockfile changed.** `prepare` prints
   `install=needed|skip|none`. Install only on `needed`, through `heavy`, then
   run `review-checkout.sh installed --repo OWNER/NAME`.
3. **Run only what the diff touches.** `review-checkout.sh affected --repo
   OWNER/NAME` lists the touched packages and test files. Run those tests,
   that package's type check and lint (for example `vitest related`, the
   package's own `test` script, the script's own `.test.sh`). Do not run a
   repo's full suite locally.
4. **Full suites come from CI.** Read the PR's GitHub checks
   (`gh pr checks N -R OWNER/NAME`). If CI has not run, or is red for a reason
   the diff could cause, say so in the review instead of re-running the whole
   suite on this machine.
5. **One heavy run at a time.** Wrap every install, build, type check and test
   run in `bash core/scripts/review-checkout.sh heavy -- <command>`. It holds
   one lock per HQ, so reviews never run heavy commands in parallel. Queue the
   next review behind it.
6. **Clean up after posting.** When the review is posted, run
   `review-checkout.sh cleanup --repo OWNER/NAME --pr N`. It deletes the
   per-review scratch directory and PR ref, releases the checkout for the
   next review, and keeps the cached checkout.
   Delete any other log or probe file the review made. Review notes worth
   keeping go to `workspace/reports/reviews/`, not `/tmp`.

`review-checkout.sh stray` lists leftover per-PR clones under `/tmp`
(`rv-*`, `rev-*`, `review-*`, `pr-*`) with their sizes. It deletes nothing;
remove the ones your own reviews created.

This covers checking out a PR for review. The `hq-core-review` audit script
keeps its own private worktree and cleans it up on exit; it needs no change.

## Why

On 2026-10-22 one conductor's review duty had left 81 full repo clones in
`/tmp` (23 created in two hours, some 1.6 to 2 GB with `node_modules`) and
ran a full install, the full test suite and `tsc` for every PR head, several
at once. macOS `fseventsd` sat near 100% CPU with 9 to 10 GB of memory and the
load average reached 51, which slowed the whole Mac and every HQ session.
Regression test: `core/scripts/tests/review-checkout.test.sh`.
