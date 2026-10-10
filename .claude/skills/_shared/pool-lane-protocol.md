# Shared lane admission and lifecycle protocol

This file keeps its historic path and section anchors for links from other
skills. hq-cli owns lane admission, reuse, state, questions, inboxes, and
capacity. The operation-by-operation migration table is in
`.claude/skills/_shared/lane-dispatch-protocol.md`. Callers do not maintain a
second pool.

## 1. Namespaces — who claims what

Every worker lane has the caller's session or lane as its senior. Story and
project attribution come from `--company`, `--project`, and `--story`. Do not
invent conduct-specific worker namespaces; reuse and attribution are handled by
the lane registry.

## 2. Claim

`hq lanes create` is the claim and admission operation. A successful response
returns the lane id. A capacity or admission refusal is a queued task; retry on
the next dispatch tick. Do not create an auxiliary pool or machine cap.

### Loop-mode lanes and the enqueue-on-assign rule

Use `hq lanes create --loop` for phase queues. hq-cli owns the queue, admission,
and resume behavior. Preserve the story and phase in each envelope.

### Stalled loop lanes: one in-place restart, then a decision item

Inspect `hq lanes show <lane> --json` and the lane envelope before recovery.
Use `hq lanes resume` or `hq lanes message` to continue the existing worker
thread. Escalate a durable blocker through the caller's decision path; do not
silently create a duplicate lane.

## 2a. Recycling is a pool operation, not a process one

There is no caller-managed recycle operation. Use `hq lanes stop` for a queued
or running lane that must end, or `hq lanes interrupt` to preserve its provider
session for later resume.

## 3. Validate ownership — before dispatch, on every path

Resolve company, project, story, worker, and senior before lane creation. Keep
company credentials and briefs within the bound company. Do not resume a lane
owned by a different senior or redirect it to a different story without
explicit attribution flags.

## 4. Mark the lane running — before anything blocks in it

The lane registry owns state transitions. Read `state`, `last_line`, `pr`,
`inbox_pending`, `elapsed_s`, and `exit` from `hq lanes list --json`; do not
persist a parallel running/idle flag.

## 5. Dispatch — spawn, resume, or the honest fallback

Create worker lanes with `hq lanes create --worker <worker> --brief-file
<path> --senior <session-or-lane-ref> --json`. Repeating create for the same
worker under the same senior continues its prior lane thread. Send a follow-up
to a live lane with `hq lanes message <lane> --text <instruction>`. Never fall
back to a detached workflow runner or an in-session subagent.

## 6. Release the lane, and record what it did

The lane registry records completion. Read the lane's envelope, changed files,
commit, and checks before reporting. Do not remove state as a substitute for
verification. A `done` envelope does not replace a senior review.

## 7. Nesting budget

This migration uses worker lanes only. Keep the invoking session or lane as the
senior; do not add manager layers, senior lanes, keep-alive leads, or nested
worker dispatch.
