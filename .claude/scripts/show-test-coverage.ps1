# Show Test Coverage
# Display test coverage summary with trend tracking and alerts

param(
    [string]$HqRoot = "C:/my-hq",
    [string]$Project = "",
    [int]$Days = 30
)

$metricsFile = Join-Path $HqRoot "workspace/metrics/test-coverage.jsonl"

if (-not (Test-Path $metricsFile)) {
    Write-Host "No test coverage data found at $metricsFile"
    exit 1
}

$cutoffDate = (Get-Date).AddDays(-$Days)
$entries = Get-Content $metricsFile | ForEach-Object {
    $m = $_ | ConvertFrom-Json
    $m | Add-Member -NotePropertyName "timestamp" -NotePropertyValue ([DateTime]$m.ts) -Force
    $m | Add-Member -NotePropertyName "passRate" -NotePropertyValue ([math]::Round(($m.passed / $m.total) * 100, 1)) -Force
    $m
} | Where-Object { $_.timestamp -ge $cutoffDate }

if ($Project) {
    $entries = $entries | Where-Object { $_.project -eq $Project }
}

# Group by project
$projects = $entries | Group-Object project

Write-Host ""
Write-Host "Test Coverage (last $Days days)"
Write-Host ("=" * 55)
Write-Host ""

$totalTests = 0
$totalPassed = 0
$alerts = @()

foreach ($proj in $projects) {
    $projName = $proj.Name
    $runs = $proj.Group | Sort-Object timestamp -Descending

    $latest = $runs[0]
    $latestRate = $latest.passRate
    $avgDuration = [math]::Round(($runs | Measure-Object duration_ms -Average).Average / 1000, 1)

    # Trend (last 5 runs)
    $trend = ""
    $recentRuns = @($runs | Select-Object -First 5)
    foreach ($run in $recentRuns) {
        if ($run.passRate -eq 100) { $trend += "* " }
        elseif ($run.passRate -ge 80) { $trend += "o " }
        else { $trend += "x " }
    }

    $statusIcon = if ($latestRate -eq 100) { "OK" } else { "" }

    Write-Host "$projName"
    Write-Host "  Latest: $($latest.passed)/$($latest.total) tests passing ($latestRate%) $statusIcon"
    Write-Host "  Trend: $trend(last $($recentRuns.Count) runs)"
    Write-Host "  Avg duration: ${avgDuration}s"
    Write-Host ""

    $totalTests += $latest.total
    $totalPassed += $latest.passed

    if ($latestRate -lt 80) {
        $lastPassing = $runs | Where-Object { $_.passRate -ge 80 } | Select-Object -First 1
        $alerts += @{
            Project = $projName
            Rate = $latestRate
            Failed = $latest.failed
            LastPassing = if ($lastPassing) { $lastPassing.ts } else { $null }
        }
    }
}

Write-Host ("-" * 55)
$overallRate = [math]::Round(($totalPassed / $totalTests) * 100, 1)
Write-Host "Total: $totalPassed/$totalTests tests | ${overallRate}% pass rate"
Write-Host ""

if ($alerts.Count -eq 0) {
    Write-Host "No projects below 80% threshold"
} else {
    foreach ($alert in $alerts) {
        Write-Host ""
        Write-Host "WARNING: COVERAGE ALERT: $($alert.Project) at $($alert.Rate)% (below 80% threshold)"
        Write-Host "   Failed tests: $($alert.Failed)"
        if ($alert.LastPassing) {
            Write-Host "   Last passing: $($alert.LastPassing)"
        }
        Write-Host "   Action: Review failures before merging"
    }
}
Write-Host ""
