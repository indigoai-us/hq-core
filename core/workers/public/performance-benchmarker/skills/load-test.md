# Load Test

Run k6 load test against a URL or API endpoint.

## Inputs

- `url`: Base URL or API endpoint to load test
- `profile`: Load profile — `smoke` (10 VUs, 1m), `normal` (50 VUs, 5m), `stress` (200 VUs, 10m), `custom`
- `thresholds`: Custom pass/fail thresholds (default: p95 < 500ms, error rate < 1%)

## Prerequisites

k6 must be installed: `brew install k6`

## Process

1. Generate k6 test script for the target URL/profile
2. Run k6 with JSON output
3. Parse results: response times (p50/p95/p99), error rate, throughput, VU concurrency
4. Compare against thresholds
5. Identify bottlenecks (slow endpoints, error spikes at load)

## Output

- Load test report to `workspace/reports/performance/{date}-{target}-load-test.md`
- Response time distribution (p50/p95/p99)
- Error rate curve over time
- Throughput (req/s) at each stage
- Pass/fail against thresholds
