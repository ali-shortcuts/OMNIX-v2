# OMNIX final-production task-pane lifecycle evidence guard.
#
# This guard is intentionally separate from final-production-core.ps1 so the canonical entrypoint
# can reject stale/legacy OFFICE-E2E evidence before any broader production aggregation is trusted.
# It performs read-only validation only: no install, Office launch, restart, network, registry or
# security-setting changes are made here.

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$OfficeE2EReport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$message) {
    Write-Host ("OMNIX FINAL TASK-PANE GUARD: FAIL - " + $message) -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $OfficeE2EReport -PathType Leaf)) {
    Fail "Office E2E report not found: $OfficeE2EReport"
}

try {
    $office = Get-Content -LiteralPath $OfficeE2EReport -Raw | ConvertFrom-Json
}
catch {
    Fail "Office E2E report is not valid JSON: $($_.Exception.Message)"
}

if ([string]$office.TestId -ne 'OFFICE-E2E-REAL-001') {
    Fail 'Unexpected Office E2E TestId.'
}
if ([int]$office.EvidenceSchema -lt 5) {
    Fail 'Office E2E evidence schema is too old; task-pane lifecycle evidence requires schema 5 or newer.'
}
if (-not [bool]$office.OverallPass) {
    Fail 'Office E2E OverallPass is false.'
}
if ($null -eq $office.TaskPaneLifecycle) {
    Fail 'TaskPaneLifecycle evidence is missing from Office E2E.'
}

$taskPane = $office.TaskPaneLifecycle
if ([string]$taskPane.TestId -ne 'TASKPANE-LIFECYCLE-REAL-001') {
    Fail 'Unexpected TaskPaneLifecycle TestId.'
}
if ([int]$taskPane.ExitCode -ne 0) {
    Fail "TaskPaneLifecycle acceptance exited with code $([int]$taskPane.ExitCode)."
}
if (-not [bool]$taskPane.OverallPass) {
    Fail 'TaskPaneLifecycle OverallPass is false.'
}
if ([int]$taskPane.InstalledHostCount -ne 3) {
    Fail "TaskPaneLifecycle did not prove exactly Excel + Word + PowerPoint; InstalledHostCount=$([int]$taskPane.InstalledHostCount)."
}
if (-not [bool]$taskPane.TwoRoundsPerHostRequired) {
    Fail 'TaskPaneLifecycle did not require two close/reopen rounds per Office host.'
}

Write-Host 'OMNIX FINAL TASK-PANE GUARD: PASS'
Write-Host 'Schema 5 Office E2E contains passing TASKPANE-LIFECYCLE-REAL-001 evidence for Excel, Word and PowerPoint.'
exit 0
