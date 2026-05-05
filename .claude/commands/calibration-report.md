---
description: Calibration report — how accurate are my time estimates by category?
allowed-tools: Bash, Read
argument-hint: "[--category X] [--since YYYY-MM-DD] [--abandon-stale]"
visibility: public
---

# /calibration-report - Estimate Accuracy by Category

Read `workspace/estimate-log/log.jsonl` and summarize how well the assistant's estimates match actuals. Output a table per category showing median ratio, sample size, and a suggested inflation multiplier.

**Input:** $ARGUMENTS

Optional flags:
- `--category <name>` — restrict to one category (`release`, `pr`, `build`, ...)
- `--since YYYY-MM-DD` — only include entries with `timestamp >= date`
- `--abandon-stale` — mark `pending` entries older than 30 days as `abandoned`
- `--show-misses` — print the top 5 worst misses with surrounding text

## Steps

1. **Read the log**
   ```bash
   LOG=workspace/estimate-log/log.jsonl
   [ -s "$LOG" ] || { echo "No estimates logged yet."; exit 0; }
   ```

2. **Apply filters**
   ```bash
   FILTERED=$(jq -c --arg cat "$CATEGORY" --arg since "$SINCE" '
     select(
       (($cat == "" or .category == $cat))
       and (($since == "" or .timestamp >= $since))
     )
   ' "$LOG")
   ```

3. **Compute stats per category** (only `kind=="estimate"` AND `status=="completed"`)

   For each category:
   - `n` — count
   - `median_ratio` — median of `actual / expected`
   - `p25` / `p75` — quartiles
   - `over_count` — entries where `ratio > 1.2`
   - `under_count` — entries where `ratio < 0.8`
   - `on_count` — entries within ±20%
   - `suggested_multiplier` — `round(median_ratio * 4) / 4` (rounded to 0.25)

   Use `jq` + simple awk math. For median, sort then pick middle.

4. **Render report**
   ```
   ESTIMATE CALIBRATION REPORT
   ===========================
   Window: <since> to <now>  |  Total entries: <n>  |  Completed: <c>  |  Pending: <p>

   Category    n   median_ratio   p25-p75      verdict-mix       suggest-multiply-by
   --------    --  ------------   ----------   ---------------   --------------------
   release     5   0.40           0.30-0.50    1on/0over/4under  0.5x  (you over-estimate by 2x)
   build       3   2.40           1.80-3.00    0on/3over/0under  2.5x  (you under-estimate by 2.5x)
   infra       4   1.10           0.90-1.30    3on/1over/0under  1.0x  (well calibrated)
   pr          2   0.55           0.50-0.60    0on/0over/2under  0.5x  (you over-estimate by 2x)
   ...
   ```

5. **Show pending count + stale flagging**
   ```
   Pending: 3 entries
   Stale (>30d, no /finish-estimate): 1
     est_abc1234   "..."   estimated 14 days ago
   Run /calibration-report --abandon-stale to clear them.
   ```

6. **(Optional) `--show-misses`** — print top 5 worst misses (`completed` entries with highest `|log(ratio)|`):
   ```
   Worst misses:
   1. est_xyz   release    expected 60 min, actual 5 min   12.0x over
      "going to take ~1 hr for the npm release of hq-cloud@5.7.1"
   2. ...
   ```

7. **Recommendation block**
   Highlight categories with `n >= 3` and `|log(median_ratio)| > log(1.5)` — those are systematically wrong. Recommend the agent inflate future estimates in those categories by `suggested_multiplier`.

## Implementation note

Pure jq + awk + bash. No Python, no installs. Keep it < 100 lines.

For median in awk:
```awk
{ a[NR] = $1 } END {
  asort(a)
  if (NR % 2) print a[(NR+1)/2]
  else print (a[NR/2] + a[NR/2+1]) / 2
}
```

(GNU awk has `asort`; BSD awk on macOS does too as of recent versions. Fall back to `sort -n | awk` if needed.)

## Notes

- This report is read-only by default. Only `--abandon-stale` mutates the log.
- Suggested multipliers should be applied loosely — if the median says `2.5x` but `n=3`, treat it as a rough heuristic, not a precise correction.
- The agent should consult this report (or read `log.jsonl` directly) when generating a new estimate in a high-bias category, and explicitly inflate.
