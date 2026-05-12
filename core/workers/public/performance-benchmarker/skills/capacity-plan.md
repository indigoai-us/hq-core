# Capacity Plan

Estimate infrastructure capacity needs based on load test results and growth projections.

## Inputs

- `load_test_report`: Path to load test results
- `current_traffic`: Current daily/monthly traffic numbers
- `growth_rate`: Expected growth rate (e.g. "2x in 6 months")
- `infrastructure`: Current infra description (Lambda, ECS, RDS, etc.)

## Process

1. Analyze load test results for saturation points
2. Map current traffic to infrastructure utilization
3. Project capacity needs at growth rate milestones (3mo, 6mo, 12mo)
4. Identify scaling bottlenecks (DB connections, memory, CPU, network)
5. Recommend scaling strategy (vertical, horizontal, auto-scaling rules)
6. Estimate cost impact of scaling

## Output

- Capacity planning report to `workspace/reports/performance/{date}-{target}-capacity-plan.md`
- Current utilization vs capacity ceiling
- Growth projection table (3/6/12 month)
- Scaling recommendations with cost estimates
- Risk assessment (what breaks first under load)
