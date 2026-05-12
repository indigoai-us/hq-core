# Summarize

Generate SCQA executive summary from any report, dataset, or project status.

## Inputs

- `source`: Path to source report(s) or data
- `audience`: Who reads this (e.g. "CEO", "engineering lead", "board")
- `subject`: What this summary is about

## Process

1. Read all source materials
2. Extract key findings with quantified data points
3. Assess business impact (revenue, risk, opportunity, timeline)
4. Draft recommendations with priority/owner/timeline/expected result
5. Compress to 325-475 words using SCQA format
6. Self-check against quality gate

## Output

- Executive summary to `workspace/reports/executive/{date}-{subject}-exec-summary.md`
- SCQA format, 325-475 words, all findings quantified
