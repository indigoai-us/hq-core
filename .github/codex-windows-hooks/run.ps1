# Real-Codex check that HQ's hooks guard tool calls on Windows.
#
# Starts Codex (app-server) with the HQ root as a trusted project and a local
# fake Responses API that asks for one shell command, so Codex itself runs the
# commandWindows strings in .codex/config.toml through the session shell. Then
# checks what Codex sent back as the tool result:
#   core-deny     `git commit` in the HQ root is denied and makes no commit.
#   company-deny  a company-scoped PreToolUse hook's deny reaches Codex.
#   allow         a harmless command runs.
# Exits 1 when any case fails.
#
# Env: CWH_HQ (HQ root, a git repo with a commit), CWH_CODEX (codex.exe),
# CWH_OUT (evidence dir).
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$HQ = $env:CWH_HQ; $codex = $env:CWH_CODEX; $OUT = $env:CWH_OUT
foreach ($v in @('CWH_HQ', 'CWH_CODEX', 'CWH_OUT')) {
  if (-not [Environment]::GetEnvironmentVariable($v)) { throw "$v is not set" }
}
New-Item -ItemType Directory -Force $OUT | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding $false
$company = 'probe-co'

# Company-scoped PreToolUse hook, dispatched by HQ's master hook for a session
# bound to the company. LF endings, since Git Bash runs it.
$hookDir = Join-Path $HQ "companies\$company\hooks\PreToolUse"
New-Item -ItemType Directory -Force $hookDir | Out-Null
$hook = @'
#!/bin/bash
input="$(cat)"
cmd="${HQ_HOOK_COMMAND:-}"
[ -n "$cmd" ] || cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null | tr -d '\r')"
case "$cmd" in
  *deny-probe*) echo "BLOCKED: deny-probe company guard (companies/probe-co)" >&2; exit 2 ;;
esac
exit 0
'@
[IO.File]::WriteAllText((Join-Path $hookDir '50-deny-probe.sh'), $hook.Replace("`r`n", "`n"), $utf8)

$cases = @(
  @{ name = 'core-deny'; command = 'git commit --allow-empty -m hq-probe'; expect = 'deny'; match = 'BLOCKED|block-hq-root-git-mutation' },
  @{ name = 'company-deny'; command = 'echo deny-probe'; expect = 'deny'; match = 'deny-probe company guard' },
  @{ name = 'allow'; command = 'echo fixture-allow'; expect = 'allow'; match = 'fixture-allow' }
)

$node = (Get-Command node.exe).Source
$failed = 0
$rows = New-Object System.Collections.ArrayList
foreach ($c in $cases) {
  $outJson = Join-Path $OUT "$($c.name).codex.json"
  $codexHome = Join-Path $OUT "codex-home-$($c.name)"
  $before = [int](& git -C $HQ rev-list --count HEAD)
  $env:CWH_COMPANY = $company
  $sw = [Diagnostics.Stopwatch]::StartNew()
  & $node (Join-Path $here 'codex-host.mjs') $codex $HQ $c.name $c.command $outJson $codexHome
  $hostExit = $LASTEXITCODE
  $sw.Stop()
  Remove-Item Env:CWH_COMPANY
  $after = [int](& git -C $HQ rev-list --count HEAD)
  $h = $null
  if (Test-Path $outJson) { $h = Get-Content $outJson -Raw | ConvertFrom-Json }
  $fco = if ($h) { [string]$h.functionCallOutput } else { '' }
  $why = @()
  if (-not $h) { $why += 'no host result' }
  elseif ($h.error) { $why += "host error: $($h.error)" }
  if ($fco -notmatch $c.match) { $why += "tool output does not match /$($c.match)/" }
  if ($c.expect -eq 'deny' -and $after -ne $before) { $why += "commit count changed $before -> $after" }
  $pass = $why.Count -eq 0
  if (-not $pass) { $failed++ }
  [void]$rows.Add([pscustomobject]@{ case = $c.name; expect = $c.expect; pass = $pass; ms = $sw.ElapsedMilliseconds; turnStatus = $h.turnStatus; hooksListed = @($h.hooksListed).Count; commitsBefore = $before; commitsAfter = $after; toolOutput = $fco; reasons = ($why -join '; ') })
  Write-Host ("[{0}] {1}: expect {2}, {3} ms, hooks listed {4}" -f $(if ($pass) { 'PASS' } else { 'FAIL' }), $c.name, $c.expect, $sw.ElapsedMilliseconds, @($h.hooksListed).Count)
  Write-Host "  tool output seen by the model: $fco"
  if (-not $pass) {
    Write-Host "  reasons: $($why -join '; ')"
    if ($h) { Write-Host "  codex stderr tail: $($h.codexStderrTail)" }
    Write-Host "  host exit: $hostExit"
  }
}

$rows | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OUT 'results.json') -Encoding utf8
if ($env:GITHUB_STEP_SUMMARY) {
  $md = @('| case | expect | pass | ms | tool output |', '|---|---|---|---:|---|')
  foreach ($r in $rows) {
    $t = [string]$r.toolOutput -replace '\r?\n', ' ' -replace '\|', '/'
    if ($t.Length -gt 160) { $t = $t.Substring(0, 160) }
    $md += "| $($r.case) | $($r.expect) | $($r.pass) | $($r.ms) | $t |"
  }
  $md -join "`n" | Add-Content $env:GITHUB_STEP_SUMMARY
}
Write-Host "cases: $($rows.Count) failed: $failed"
if ($failed -gt 0) { exit 1 }
exit 0
