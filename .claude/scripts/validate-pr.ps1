<#
.SYNOPSIS
    Validate PR changes before merge

.DESCRIPTION
    Runs automated tests to ensure PR quality:
    - File existence (for PRD-based changes)
    - Syntax validation (YAML, JSON, scripts)
    - Worker registry consistency
    - Cross-reference integrity

.PARAMETER Project
    Optional: Project name to validate (checks PRD files exist)

.EXAMPLE
    .\validate-pr.ps1
    .\validate-pr.ps1 -Project project-context-manager
#>

param(
    [string]$Project,
    [string]$HqPath = "C:/my-hq"
)

$ErrorActionPreference = "Continue"
$passed = 0
$failed = 0

function Test-Check {
    param([string]$Name, [scriptblock]$Test)

    try {
        $result = & $Test
        if ($result) {
            Write-Host "  PASS: $Name" -ForegroundColor Green
            $script:passed++
        } else {
            Write-Host "  FAIL: $Name" -ForegroundColor Red
            $script:failed++
        }
    } catch {
        Write-Host "  FAIL: $Name - $_" -ForegroundColor Red
        $script:failed++
    }
}

Write-Host ""
Write-Host "=== HQ PR Validation ===" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# 1. Script Syntax Validation
# ============================================================================
Write-Host "Script Syntax:" -ForegroundColor Yellow

# PowerShell scripts
Get-ChildItem "$HqPath/.claude/scripts/*.ps1" | ForEach-Object {
    Test-Check $_.Name {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errors)
        $errors.Count -eq 0
    }
}

# Bash scripts (if bash available)
$bashAvailable = Get-Command bash -ErrorAction SilentlyContinue
if ($bashAvailable) {
    Get-ChildItem "$HqPath/.claude/scripts/*.sh" | ForEach-Object {
        Test-Check $_.Name {
            $result = bash -n $_.FullName 2>&1
            $LASTEXITCODE -eq 0
        }
    }
}

# ============================================================================
# 2. YAML Validation
# ============================================================================
Write-Host ""
Write-Host "YAML Syntax:" -ForegroundColor Yellow

$pythonAvailable = Get-Command python -ErrorAction SilentlyContinue
if ($pythonAvailable) {
    # Worker files
    Get-ChildItem "$HqPath/workers" -Recurse -Filter "*.yaml" | ForEach-Object {
        $relativePath = $_.FullName.Replace("$HqPath/", "").Replace("\", "/")
        Test-Check $relativePath {
            $result = python -c "import yaml; yaml.safe_load(open(r'$($_.FullName)'))" 2>&1
            $LASTEXITCODE -eq 0
        }
    }

    # Knowledge YAML files
    Get-ChildItem "$HqPath/knowledge" -Recurse -Filter "*.yaml" | ForEach-Object {
        $relativePath = $_.FullName.Replace("$HqPath/", "").Replace("\", "/")
        Test-Check $relativePath {
            $result = python -c "import yaml; yaml.safe_load(open(r'$($_.FullName)'))" 2>&1
            $LASTEXITCODE -eq 0
        }
    }
} else {
    Write-Host "  SKIP: Python not available for YAML validation" -ForegroundColor Gray
}

# ============================================================================
# 3. JSON Validation
# ============================================================================
Write-Host ""
Write-Host "JSON Syntax:" -ForegroundColor Yellow

if ($pythonAvailable) {
    # PRD files
    Get-ChildItem "$HqPath/projects" -Recurse -Filter "*.json" | ForEach-Object {
        $relativePath = $_.FullName.Replace("$HqPath/", "").Replace("\", "/")
        Test-Check $relativePath {
            $result = python -c "import json; json.load(open(r'$($_.FullName)'))" 2>&1
            $LASTEXITCODE -eq 0
        }
    }

    # Settings files
    Get-ChildItem "$HqPath/settings" -Recurse -Filter "*.json" -ErrorAction SilentlyContinue | ForEach-Object {
        $relativePath = $_.FullName.Replace("$HqPath/", "").Replace("\", "/")
        Test-Check $relativePath {
            $result = python -c "import json; json.load(open(r'$($_.FullName)'))" 2>&1
            $LASTEXITCODE -eq 0
        }
    }
} else {
    Write-Host "  SKIP: Python not available for JSON validation" -ForegroundColor Gray
}

# ============================================================================
# 4. Worker Registry Consistency
# ============================================================================
Write-Host ""
Write-Host "Worker Registry:" -ForegroundColor Yellow

$registryPath = "$HqPath/workers/registry.yaml"
if (Test-Path $registryPath) {
    $registryContent = Get-Content $registryPath -Raw

    # Check dev-team workers exist
    $devTeamWorkers = Get-ChildItem "$HqPath/workers/dev-team" -Directory -ErrorAction SilentlyContinue
    foreach ($worker in $devTeamWorkers) {
        $workerYaml = Join-Path $worker.FullName "worker.yaml"
        Test-Check "dev-team/$($worker.Name) has worker.yaml" {
            Test-Path $workerYaml
        }

        # Check if registered
        Test-Check "dev-team/$($worker.Name) in registry" {
            $registryContent -match $worker.Name
        }
    }
}

# ============================================================================
# 5. PRD File Existence (if project specified)
# ============================================================================
if ($Project) {
    Write-Host ""
    Write-Host "PRD Files ($Project):" -ForegroundColor Yellow

    $prdPath = "$HqPath/projects/$Project/prd.json"
    if (Test-Path $prdPath) {
        $prd = Get-Content $prdPath -Raw | ConvertFrom-Json

        $allFiles = @()
        foreach ($feature in $prd.features) {
            if ($feature.files) {
                $allFiles += $feature.files
            }
        }

        $uniqueFiles = $allFiles | Sort-Object -Unique
        foreach ($file in $uniqueFiles) {
            $fullPath = Join-Path $HqPath $file
            Test-Check $file {
                Test-Path $fullPath
            }
        }
    } else {
        Write-Host "  SKIP: PRD not found at $prdPath" -ForegroundColor Gray
    }
}

# ============================================================================
# 6. Command File Structure
# ============================================================================
Write-Host ""
Write-Host "Command Files:" -ForegroundColor Yellow

Get-ChildItem "$HqPath/.claude/commands/*.md" | ForEach-Object {
    Test-Check "$($_.Name) has frontmatter" {
        $content = Get-Content $_.FullName -Raw
        # Command files should have YAML frontmatter (--- ... ---)
        $content -match "^---[\s\S]*?---"
    }

    Test-Check "$($_.Name) has description" {
        $content = Get-Content $_.FullName -Raw
        $content -match "description:"
    }
}

# ============================================================================
# Summary
# ============================================================================
Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "Passed: $passed" -ForegroundColor Green
Write-Host "Failed: $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Gray" })
Write-Host ""

if ($failed -gt 0) {
    Write-Host "VALIDATION FAILED" -ForegroundColor Red
    exit 1
} else {
    Write-Host "VALIDATION PASSED" -ForegroundColor Green
    exit 0
}
