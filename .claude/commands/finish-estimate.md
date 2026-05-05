---
description: Mark an estimate complete with an actual duration
allowed-tools: Bash, Read, Edit
argument-hint: "<estimate-id|latest> <actual-duration> [notes]"
visibility: public
---

# /finish-estimate - Record Actual Time

Look up an estimate by ID (or grab the most-recent `pending`) and fill in the actual elapsed time, ratio, and verdict.

**Input:** $ARGUMENTS

Examples:
- `latest 10m` — close out the most-recently-logged pending estimate with 10 minutes
- `est_f43cca6aa1 1h` — close out a specific estimate
- `latest 45m "Tauri sign step took longer than expected"` — with a note

## Steps

1. **Parse arguments**
   - First token: estimate ID (`est_*`) or literal `latest`
   - Second token: actual duration in same format as `/track-estimate` (`10m`, `1.5h`, `2d`)
   - Remaining (optional): notes string

2. **Resolve target entry**
   - If `latest`: read `workspace/estimate-log/log.jsonl`, find the most-recent entry with `kind == "estimate"` AND `status == "pending"`. Take its `id`.
   - Else: search for the line where `id == <provided>`.
   - If no match, abort with a clear message.

3. **Normalize actual duration**
   Same parser as `/track-estimate`. Compute `actual_minutes` (single value, not a range — actuals are point measurements).

4. **Compute verdict**
   ```
   ratio = actual_minutes / expected_minutes
   verdict = "under" if ratio < 0.8
           | "on"    if 0.8 <= ratio <= 1.2
           | "over"  if ratio > 1.2
   ```

5. **Rewrite the entry's line in `log.jsonl`**
   - Read the file line by line.
   - For the matched line, parse the JSON, add fields:
     - `actual_minutes`
     - `actual_at` (current ISO timestamp)
     - `ratio`
     - `verdict`
     - `status: "completed"`
     - `notes` if provided
   - Re-emit with canonical (alphabetical) key order.
   - Write back the full file (atomic via temp + rename).

6. **Report**
   ```
   ID: <id>
   Task: <task-or-surrounding-truncated>
   Estimate: <expected> min (range <min>-<max>)
   Actual:   <actual> min
   Ratio:    <ratio> ({factor}x {over/under/on})
   Category: <category>
   ```

   Where `factor`:
   - `over`: `round(ratio, 1)` — e.g. `2.4x over`
   - `under`: `round(1/ratio, 1)` — e.g. `3.0x under`
   - `on`: `±X%` — e.g. `+12%`

## Implementation hint

Use jq for the in-place rewrite. Atomic pattern:

```bash
LOG=workspace/estimate-log/log.jsonl
TMP=$(mktemp)
jq -c --arg id "$ID" --argjson actual "$ACTUAL_MINUTES" --arg ts "$NOW_ISO" --arg verdict "$VERDICT" --argjson ratio "$RATIO" --arg notes "$NOTES" '
  if .id == $id then
    . + {actual_minutes: $actual, actual_at: $ts, ratio: $ratio, verdict: $verdict, status: "completed"}
    + (if $notes != "" then {notes: $notes} else {} end)
  else . end
' "$LOG" > "$TMP" && mv "$TMP" "$LOG"
```

`jq -c` keeps it as JSONL. Field order may shift after the merge; that's fine — the dedup grep doesn't depend on order.

## Notes

- Once `status: "completed"`, an entry won't be re-processed by `latest` — so it's safe to run repeatedly.
- If you mistyped the actual, just run again with the correct value — the rewrite is idempotent.
- Don't worry about precise wall-clock timing. The signal we want is "ratio order of magnitude" (2x, 5x, 0.5x), not minutes-of-minutes precision.
