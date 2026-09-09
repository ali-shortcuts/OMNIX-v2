# Installs/removes the transparent per-user OMNIX Office registration maintenance task.
# The task runs at interactive user logon with LIMITED privileges and exits immediately after
# scanning/repairing OMNIX-owned registration for supported installed Office hosts.

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InstallDir,
    [switch]$Remove,
    [string]$ReportPath = "$env:LOCALAPPDATA\OMNIX\logs\office-maintenance-task.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$taskName = 'OMNIX Office Registration Maintenance'
$scriptPath = Join-Path $InstallDir 'office-registration-maintenance.ps1'
$report = [ordered]@{
    TestId = 'OFFICE-MAINTENANCE-TASK-001'
    EvidenceSchema = 1
    TimestampUtc = [DateTime]::UtcNow.ToString('o')
    TaskName = $taskName
    RequestedAction = if ($Remove) { 'Remove' } else { 'InstallOrRepair' }
    Registered = $false
    RunLevel = 'Limited'
    Trigger = 'AtLogOnCurrentUser'
    Pass = $false
    Error = $null
}

try {
    Import-Module ScheduledTasks -ErrorAction Stop

    if ($Remove) {
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        }
        $report.Registered = $false
        $report.Pass = ($null -eq (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue))
    }
    else {
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            throw "Maintenance script missing: $scriptPath"
        }

        $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $args = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' +
                $scriptPath + '" -InstallDir "' + $InstallDir + '" -Quiet'
        $action = New-ScheduledTaskAction -Execute $exe -Argument $args

        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
        $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal `
            -Settings $settings -Description 'OMNIX checks supported Excel/Word/PowerPoint registration for the current user after sign-in. No elevation, Trust Center or Office Resiliency changes.' -Force | Out-Null

        $created = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $report.Registered = ($null -ne $created)
        $report.Pass = $report.Registered
    }
}
catch {
    $report.Error = $_.Exception.Message
    $report.Pass = $false
}

try {
    $dir = Split-Path -Parent $ReportPath
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
} catch { }

$report | ConvertTo-Json -Depth 6
if (-not $report.Pass) { exit 1 }
exit 0
