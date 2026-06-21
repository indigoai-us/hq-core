---
name: track-estimate
description: Manually log a time estimate.
allowed-tools: Bash, Read, Edit
---

# /track-estimate - Manual Estimate Capture

Append a time estimate to `workspace/estimate-log/log.jsonl`. Use this when:
- The auto-capture hook missed something (vague phrasing, deeply nested in a code block, etc.)
- You want to attach a structured `task` description to a freshly-captured estimate
- The estimate is being made conversationally before any assistant message has logged it

**Input:** $ARGUMENTS

The argument should be a free-form phrase containing both a task description and a duration. Examples:
- `"port resolve-conflicts skill to hq-core-staging" "1-2h"`
- `"npm release of hq-cloud@5.7.1, including verification" "30m"`
- `"AppBar Tauri build + sign + notarize" "10-30m"`

## Steps

1. **Parse arguments**
   - Extract the duration token (`30m`, `1-2h`, `2 days`, `~5min`, etc.)
   - Treat everything else as the task description
   - Fall back to interactive prompts if either is missing

2. **Normalize duration**
   Use the same logic as `parse-estimates.pl`:
   - `m` / `min` / `minutes` → minutes (1×)
   - `h` / `hr` / `hours` → minutes (60×)
   - `d` / `day` / `days` → minutes (480× — 8-hour workday)
   - `s` / `sec` → minutes (1/60×)
   - Ranges like `1-2h`: `min_minutes=60, max_minutes=120, expected_minutes=90`

3. **Categorize**
   Run the same keyword classifier from `parse-estimates.pl` against the task description. If unclear, ask the user to confirm or pick from: `release`, `pr`, `build`, `deploy`, `tauri`, `infra`, `script`, `refactor`, `docs`, `debug`, `cli`, `unknown`.

4. **Generate ID**
   `est_<sha1(session_id + iso_ts + task)[0..10]>` — same format as auto-capture.

5. **Append entry to log**
   ```bash
   cat >> workspace/estimate-log/log.jsonl <<EOF
   {"id":"est_...","timestamp":"...","session_id":"manual","message_uuid":"manual-<short>","offset":0,"raw":"<duration token>","kind":"estimate","min_minutes":...,"max_minutes":...,"expected_minutes":...,"category":"...","surrounding":"<task>","status":"pending","task":"<task>"}
   EOF
   ```

   Field order should match canonical (alphabetical) so it sorts identically to auto-capture entries.

6. **Report**
   ```
   Tracked: <task>
   ID: est_...
   Estimate: <human-readable> (<expected_minutes> min, range <min>-<max>)
   Category: <category>

   When done, run: /finish-estimate <id> <actual-duration>
   ```

## Notes

- This command is the escape hatch for the auto-capture hook. Most estimates should land via the Stop hook automatically; this is for the cases the hook misses.
- The `session_id` is set to `"manual"` to distinguish manual entries from auto-captured ones in `/calibration-report`.
- If the user provides only a duration with no task, prompt for the task — never log an estimate without context.

## See also

- `/finish-estimate` — close it with the actual time
- `/calibration-report` — see estimate accuracy
