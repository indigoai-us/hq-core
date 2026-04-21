<#
.SYNOPSIS
    Validate PRD files for e2eTests presence and schema compliance

.DESCRIPTION
    Checks PRD files against the schema defined in knowledge/hq-core/prd-schema.md:
    - JSON syntax validation
    - Required fields presence (name, description, branchName, userStories, metadata)
    - e2eTests array presence for EVERY user story (REQUIRED)
    - Story ID format (US-XXX)
    - Branch name format (feature/*)
    - Dependencies reference existing stories

.PARAMETER Project
    Optional: Specific project to validate. If not specified, validates all PRDs.

.PARAMETER HqPath
    Optional: Path to HQ root. Defaults to C:/my-hq

.EXAMPLE
    .\validate-prd.ps1
    .\validate-prd.ps1 -Project my-project
    .\validate-prd.ps1 -HqPath "D:/my-hq"
#>

param(
    [string]$Project,
    [string]$HqPath = "C:/my-hq"
)

$ErrorActionPreference = "Continue"
$passed = 0
$failed = 0
$warnings = 0

function Test-Check {
    param(
        [string]$Name,
        [scriptblock]$Test,
        [switch]$IsWarning
    )

    try {
        $result = & $Test
        if ($result) {
            Write-Host "  PASS: $Name" -ForegroundColor Green
            $script:passed++
        } else {
            if ($IsWarning) {
                Write-Host "  WARN: $Name" -ForegroundColor Yellow
                $script:warnings++
            } else {
                Write-Host "  FAIL: $Name" -ForegroundColor Red
                $script:failed++
            }
        }
    } catch {
        if ($IsWarning) {
            Write-Host "  WARN: $Name - $_" -ForegroundColor Yellow
            $script:warnings++
        } else {
            Write-Host "  FAIL: $Name - $_" -ForegroundColor Red
            $script:failed++
        }
    }
}

Write-Host ""
Write-Host "=== PRD Validation ===" -ForegroundColor Cyan
Write-Host "Schema: knowledge/hq-core/prd-schema.md" -ForegroundColor Gray
Write-Host ""

# Find PRD files to validate
if ($Project) {
    $prdFiles = @(Get-Item "$HqPath/projects/$Project/prd.json" -ErrorAction SilentlyContinue)
    if ($prdFiles.Count -eq 0) {
        Write-Host "ERROR: PRD not found at projects/$Project/prd.json" -ForegroundColor Red
        exit 1
    }
} else {
    $prdFiles = Get-ChildItem "$HqPath/projects" -Recurse -Filter "prd.json" -ErrorAction SilentlyContinue
    if ($prdFiles.Count -eq 0) {
        Write-Host "No PRD files found in projects/" -ForegroundColor Yellow
        exit 0
    }
}

Write-Host "Found $($prdFiles.Count) PRD file(s) to validate" -ForegroundColor Gray
Write-Host ""

foreach ($prdFile in $prdFiles) {
    $relativePath = $prdFile.FullName.Replace("$HqPath/", "").Replace("\", "/")
    Write-Host "Validating: $relativePath" -ForegroundColor Yellow

    # ============================================================================
    # 1. JSON Syntax
    # ============================================================================
    $prd = $null
    Test-Check "JSON syntax" {
        try {
            $script:prd = Get-Content $prdFile.FullName -Raw | ConvertFrom-Json
            $true
        } catch {
            $false
        }
    }

    if (-not $prd) {
        Write-Host "  Skipping remaining checks due to JSON parse error" -ForegroundColor Gray
        continue
    }

    # ============================================================================
    # 2. Required Root Fields
    # ============================================================================
    Test-Check "Has 'name' field" { $null -ne $prd.name -and $prd.name -ne "" }
    Test-Check "Has 'description' field" { $null -ne $prd.description -and $prd.description -ne "" }
    Test-Check "Has 'branchName' field" { $null -ne $prd.branchName -and $prd.branchName -ne "" }
    Test-Check "Has 'userStories' array" { $null -ne $prd.userStories -and $prd.userStories.Count -gt 0 }
    Test-Check "Has 'metadata' object" { $null -ne $prd.metadata }

    # ============================================================================
    # 3. Branch Name Format
    # ============================================================================
    Test-Check "branchName starts with 'feature/'" {
        $prd.branchName -match "^feature/"
    }

    # ============================================================================
    # 4. Metadata Fields
    # ============================================================================
    if ($prd.metadata) {
        Test-Check "metadata.createdAt present" { $null -ne $prd.metadata.createdAt }
        Test-Check "metadata.baseBranch present" { $null -ne $prd.metadata.baseBranch }
        Test-Check "metadata.goal present" { $null -ne $prd.metadata.goal }
        Test-Check "metadata.successCriteria present" { $null -ne $prd.metadata.successCriteria }
    }

    # ============================================================================
    # 5. User Story Validation
    # ============================================================================
    $storyIds = @()

    foreach ($story in $prd.userStories) {
        $storyId = $story.id
        if (-not $storyId) { $storyId = "UNKNOWN" }
        $storyIds += $storyId

        # ID format
        Test-Check "$storyId - ID format matches US-XXX" {
            $story.id -match "^US-\d{3}$"
        }

        # Required fields
        Test-Check "$storyId - Has title" { $null -ne $story.title -and $story.title -ne "" }
        Test-Check "$storyId - Has description" { $null -ne $story.description -and $story.description -ne "" }
        Test-Check "$storyId - Has acceptanceCriteria" {
            $null -ne $story.acceptanceCriteria -and $story.acceptanceCriteria.Count -gt 0
        }
        Test-Check "$storyId - Has priority" { $null -ne $story.priority }
        Test-Check "$storyId - Has passes field" { $null -ne $story.passes }

        # ============================================================================
        # E2E TESTS - CRITICAL REQUIREMENT
        # ============================================================================
        Test-Check "$storyId - Has e2eTests array (REQUIRED)" {
            $null -ne $story.e2eTests
        }

        if ($null -ne $story.e2eTests) {
            Test-Check "$storyId - e2eTests is not empty (REQUIRED)" {
                $story.e2eTests.Count -gt 0
            }

            # Warn if e2eTests seem too vague
            foreach ($test in $story.e2eTests) {
                if ($test -match "^(works|good|correct|properly)$") {
                    Test-Check "$storyId - e2eTest '$test' is specific enough" -IsWarning { $false }
                }
            }
        }

        # Dependencies check
        if ($story.dependsOn -and $story.dependsOn.Count -gt 0) {
            foreach ($dep in $story.dependsOn) {
                Test-Check "$storyId - Dependency '$dep' exists" {
                    $prd.userStories | Where-Object { $_.id -eq $dep } | Measure-Object | Select-Object -ExpandProperty Count
                }
            }
        }
    }

    # Check for duplicate IDs
    $duplicates = $storyIds | Group-Object | Where-Object { $_.Count -gt 1 }
    if ($duplicates) {
        foreach ($dup in $duplicates) {
            Test-Check "No duplicate story ID: $($dup.Name)" { $false }
        }
    }

    Write-Host ""
}

# ============================================================================
# Summary
# ============================================================================
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "Passed:   $passed" -ForegroundColor Green
Write-Host "Failed:   $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Gray" })
Write-Host "Warnings: $warnings" -ForegroundColor $(if ($warnings -gt 0) { "Yellow" } else { "Gray" })
Write-Host ""

if ($failed -gt 0) {
    Write-Host "VALIDATION FAILED" -ForegroundColor Red
    Write-Host ""
    Write-Host "Common fixes:" -ForegroundColor Gray
    Write-Host "  - Add e2eTests array to each user story" -ForegroundColor Gray
    Write-Host "  - Use US-XXX format for story IDs" -ForegroundColor Gray
    Write-Host "  - Ensure branchName starts with 'feature/'" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Schema reference: knowledge/hq-core/prd-schema.md" -ForegroundColor Gray
    exit 1
} elseif ($warnings -gt 0) {
    Write-Host "VALIDATION PASSED WITH WARNINGS" -ForegroundColor Yellow
    exit 0
} else {
    Write-Host "VALIDATION PASSED" -ForegroundColor Green
    exit 0
}
