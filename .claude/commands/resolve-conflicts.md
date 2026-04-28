---
description: Walk through HQ Sync conflicts and resolve them interactively (keep local | take cloud | discard).
---

# /resolve-conflicts

Interactive conflict resolution for HQ Sync. When two machines (or two users) edit the same file and sync detects divergence, both versions land on disk: the *original path* keeps the local version, and a `.conflict-<timestamp>-<machine>.<ext>` file holds the cloud's version. This command walks the user through each pending conflict and applies their decision.

## What you do

### Step 1 — Locate and read the index

Read `~/HQ/.hq-conflicts/index.json`. The exact HQ folder path comes from `~/.hq/menubar.json` `hqPath` (and falls back per the resolve-hq-folder discovery chain). If the file doesn't exist OR the `conflicts` array is empty, tell the user "No conflicts pending — your local copy is in sync with the cloud" and stop.

The index schema:

```json
{
  "version": 1,
  "conflicts": [
    {
      "id": "...",
      "originalPath": "knowledge/notes.md",
      "conflictPath": "knowledge/notes.md.conflict-2026-04-27T22-05-14Z-abc123.md",
      "detectedAt": "2026-04-27T22:05:14Z",
      "side": "pull" | "push",
      "machineId": "abc123",
      "localHash": "...",
      "remoteHash": "...",
      "remoteVersionId": "...",
      "lastKnownVersionId": "..."
    }
  ]
}
```

### Step 2 — Summarize the queue

Tell the user how many conflicts are pending, grouped by top-level folder. Example:

```
3 conflicts pending:
  knowledge/  (2 files)
  projects/foo/  (1 file)

Walking through them oldest-first.
```

### Step 3 — Walk each conflict (oldest detectedAt first)

For each entry:

1. Read both files (Read on `originalPath` and `conflictPath`, both relative to HQ folder).
2. Show the user a short preview: file path, sizes of both versions, and a unified diff (use `Bash` with `diff -u <local> <cloud>` if both are reasonable size, otherwise just first 30 lines of each).
3. Ask: which version to keep?
   - **`l` / `local`** — keep the local copy at `originalPath`. Delete the conflict file. (Cloud's version is discarded — it's still in S3 versioning history if recovery is ever needed.)
   - **`c` / `cloud`** — overwrite local with the cloud copy. Use Bash `mv <conflictPath> <originalPath>` to atomically replace.
   - **`m` / `merge`** — open both files for the user to manually merge. Use Bash `code -d <local> <cloud>` (VS Code diff) or fall back to `open <local> <cloud>`. Wait for the user to confirm they're done with the merge, then ask again (or accept that they've manually resolved → delete the conflict file).
   - **`s` / `skip`** — leave both files in place, move to next conflict. Index entry stays.
   - **`q` / `quit`** — stop walking, exit.

4. After applying the resolution (except skip/quit/merge-pending), remove the index entry. Re-write `~/HQ/.hq-conflicts/index.json` atomically (write to `.tmp`, then rename).

### Step 4 — Final summary

Tell the user how many conflicts were resolved this session, how many were skipped, and what's left:

```
Resolved 2 conflicts (1 kept local, 1 took cloud).
1 conflict skipped — run `/resolve-conflicts` again to revisit.
```

If there are still pending conflicts, suggest the user re-run sync afterwards so the resolved files propagate to the cloud cleanly.

## Edge cases

- **`conflictPath` doesn't exist on disk but is in the index**: the file was probably already deleted/resolved manually. Remove the index entry and continue.
- **`originalPath` doesn't exist**: the user deleted the local file. Treat the conflict file as the only remaining copy — ask "the original file is gone; keep the cloud version (move to original) or discard?"
- **Index file is corrupt JSON**: tell the user, don't attempt repair. Suggest checking `~/HQ/.hq-conflicts/index.json` manually or restoring from a backup.
- **Binary files (image, PDF)**: don't attempt diff. Just show file sizes + offer to open both in their default app via `open`.
- **No editor available for merge**: fall back to `open` (default app) for both files.

## Don't

- Don't try to do 3-way merges automatically — that's a future enhancement that requires the journal-version blob. Just show the two versions and let the user pick.
- Don't propagate or upload conflict files. They're local-only by design (`.hqignore` blocks them).
- Don't touch the journal directly — let the next sync update the journal with the resolved file's new hash.
- Don't skip the atomic write of the index. Always tmp-then-rename so a crash doesn't leave a corrupt index.

## After resolution

After the user has resolved conflicts, suggest they hit Sync in the menubar. The runner will pick up the resolved file (now with a new local hash that differs from journal) and push it cleanly. If a *new* conflict happens in the meantime (someone else pushed again), they'll see a new entry in the index.
