# Collect Test Metrics
# Scans for agent-results.json files across projects and appends to test-coverage.jsonl

param(
    [string]$HqRoot = "C:/my-hq"
)

$metricsFile = Join-Path $HqRoot "workspace/metrics/test-coverage.jsonl"

# Known test result locations (add more as projects grow)
$testResultPaths = @(
    @{ Project = "hq-installer"; Path = "installer/tests/e2e/agent-results.json" }
    # Add more projects here:
    # @{ Project = "protofit"; Path = "apps/protofit/tests/e2e/agent-results.json" }
)

foreach ($entry in $testResultPaths) {
    $resultsPath = Join-Path $HqRoot $entry.Path

    if (Test-Path $resultsPath) {
        $results = Get-Content $resultsPath -Raw | ConvertFrom-Json

        # Create metrics entry
        $metric = @{
            ts = $results.meta.timestamp
            project = $entry.Project
            suite = "e2e"
            total = $results.summary.total
            passed = $results.summary.passed
            failed = $results.summary.failed
            skipped = $results.summary.skipped
            flaky = $results.summary.flaky
            duration_ms = [math]::Round($results.summary.duration)
            source = $entry.Path
        }

        # Check if this exact timestamp already exists
        $existingLines = @()
        if (Test-Path $metricsFile) {
            $existingLines = Get-Content $metricsFile | Where-Object { $_ -match $metric.ts }
        }

        if ($existingLines.Count -eq 0) {
            $json = $metric | ConvertTo-Json -Compress
            Add-Content -Path $metricsFile -Value $json
            Write-Host "Added test metrics for $($entry.Project) at $($metric.ts)"
        } else {
            Write-Host "Metrics for $($entry.Project) at $($metric.ts) already recorded"
        }
    } else {
        Write-Host "No results found at $resultsPath"
    }
}

Write-Host ""
Write-Host "Test metrics updated: $metricsFile"
