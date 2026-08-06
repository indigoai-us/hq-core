# Web Vitals Audit

Measure Core Web Vitals and Lighthouse scores for a URL.

## Inputs

- `url`: URL to audit (production or preview)
- `pages`: Comma-separated paths to test (default: homepage + 2-3 key pages)
- `runs`: Number of Lighthouse runs per page (default: 3, report median)

## Process

1. Run Lighthouse CLI `runs` times per page
2. Extract CWV metrics (LCP, INP, CLS, FCP, TTFB)
3. Extract Lighthouse category scores
4. Compare against thresholds (Good / Needs Improvement / Poor)
5. Identify top performance bottlenecks
6. Generate optimization recommendations with expected impact

## Output

- Web Vitals report to `workspace/reports/performance/{date}-{target}-web-vitals.md`
- Per-page CWV table with ratings
- Lighthouse score summary
- Ranked optimization recommendations
