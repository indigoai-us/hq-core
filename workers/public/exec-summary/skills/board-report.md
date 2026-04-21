# Board Report

Generate a company board-level summary covering multiple projects/initiatives.

## Inputs

- `company`: Company slug (for project/report discovery)
- `period`: Reporting period (e.g. "March 2026", "Q1 2026")
- `focus_areas`: Optional — specific areas to highlight

## Process

1. Discover all projects for company: `companies/{company}/projects/*/prd.json`
2. Read project status, completion rates, blockers
3. Read any reports from the period: `workspace/reports/`
4. Synthesize across projects into single board report
5. Apply SCQA format per section, overall 325-475 words per section
6. Include key metrics dashboard table

## Output

- Board report to `workspace/reports/executive/{date}-{company}-board-report.md`
- Project status summary table
- Key metrics (velocity, completion rate, blockers)
- Strategic recommendations with owners and timelines
