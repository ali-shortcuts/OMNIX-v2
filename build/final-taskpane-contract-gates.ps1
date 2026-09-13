# OMNIX final task-pane evidence anti-drift contract.
# Structural/parser checks only; real Office execution remains a separate mandatory runtime gate.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]

function Read-Repo([string]$relative) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failures.Add("Missing: $relative")
        return ''
    }
    return Get-Content -LiteralPath $path -Raw
}

function Need([string]$relative, [string]$needle, [string]$reason) {
    $text = Read-Repo $relative
    if (-not $text.Contains($needle)) {
        $failures.Add("${relative}: missing '$needle' — $reason")
    }
}

function Forbid([string]$relative, [string]$needle, [string]$reason) {
    $text = Read-Repo $relative
    if ($text.Contains($needle)) {
        $failures.Add("${relative}: forbidden '$needle' — $reason")
    }
}

function Parse-Ps([string]$relative) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failures.Add("Missing: $relative")
        return
    }
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    foreach ($parseError in @($errors)) {
        $failures.Add("${relative}: parser error — $($parseError.Message)")
    }
}

$guard = 'tools/final-production-taskpane-guard.ps1'
$entry = 'tools/final-production-gate.ps1'
$e2e = 'tools/full-office-e2e.ps1'

Parse-Ps $guard
Need $guard "'OFFICE-E2E-REAL-001'" 'guard must reject unrelated/legacy report types.'
Need $guard 'EvidenceSchema -lt 5' 'schema 5 is the first Office E2E schema carrying task-pane lifecycle evidence.'
Need $guard "'TASKPANE-LIFECYCLE-REAL-001'" 'real task-pane lifecycle TestId must be mandatory.'
Need $guard 'InstalledHostCount -ne 3' 'Excel, Word and PowerPoint must all be proven.'
Need $guard 'TwoRoundsPerHostRequired' 'close/reopen stale-state detection must remain mandatory.'
Need $guard 'TaskPaneLifecycle' 'aggregated task-pane lifecycle evidence must be consumed.'
Forbid $guard 'Restart-Computer' 'guard must remain read-only and never restart Windows.'
Forbid $guard 'Disable-NetAdapter' 'guard must never change network state.'
Forbid $guard 'reg.exe' 'guard must never mutate registry state.'

Parse-Ps $entry
Need $entry 'final-production-taskpane-guard.ps1' 'canonical final entrypoint must invoke the task-pane evidence guard.'
Need $entry '& $guard -OfficeE2EReport $OfficeE2EReport' 'guard must validate the exact Office E2E report passed to final production.'
Need $entry 'if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}' 'failed task-pane guard must stop before the production core.'
Need $entry 'final-production-core.ps1' 'canonical wrapper must still delegate to the full production core after guard PASS.'
Forbid $entry 'AllowDevelopmentSignature' 'canonical production entrypoint must expose no development-signature bypass.'

Parse-Ps $e2e
Need $e2e 'EvidenceSchema = 5' 'Office E2E must emit lifecycle-aware schema 5 evidence.'
Need $e2e 'taskpane-lifecycle-real-acceptance.ps1' 'full Office E2E must execute the real task-pane lifecycle acceptance.'
Need $e2e 'TaskPaneLifecycle = [ordered]@{' 'full Office E2E must aggregate task-pane lifecycle evidence.'

if ($failures.Count -gt 0) {
    Write-Host 'OMNIX FINAL TASK-PANE CONTRACT: FAIL' -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host 'OMNIX FINAL TASK-PANE CONTRACT: PASS'
Write-Host 'Canonical production entrypoint fail-closes on schema-5 TASKPANE-LIFECYCLE-REAL-001 evidence before broader final aggregation.'
exit 0
