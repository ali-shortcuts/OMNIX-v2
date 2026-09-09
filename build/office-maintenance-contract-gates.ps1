# OMNIX automatic Office registration maintenance anti-drift contract.
# Structural only. Real Office automatic registration remains a real-machine release gate.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]

function Read-Repo([string]$relative) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failures.Add("Missing required file: $relative")
        return ''
    }
    Get-Content -LiteralPath $path -Raw
}
function Need([string]$relative,[string]$needle,[string]$why) {
    $text = Read-Repo $relative
    if (-not $text.Contains($needle)) { $failures.Add("${relative}: missing '$needle' — $why") }
}
function ForbidRegex([string]$relative,[string]$pattern,[string]$why) {
    $text = Read-Repo $relative
    if ($text -match $pattern) { $failures.Add("${relative}: forbidden pattern '$pattern' — $why") }
}
function Parse-Ps([string]$relative) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $failures.Add("Missing: $relative"); return }
    $tok=$null; $err=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tok,[ref]$err)
    foreach ($e in @($err)) { $failures.Add("${relative}: parser error — $($e.Message)") }
}

$maint = 'build/office-registration-maintenance.ps1'
$task = 'build/install-maintenance-task.ps1'
$installer = 'installer/installer.iss'
$package = 'build/package.ps1'

Parse-Ps $maint
Parse-Ps $task

# Supported Office detection/registration scope.
Need $maint "@('16.0','15.0')" 'maintenance detection must stay within the tested Office 2013+ compatibility generations.'
Need $maint "Name='Excel'" 'Excel detection is required.'
Need $maint "Name='Word'" 'Word detection is required.'
Need $maint "Name='PowerPoint'" 'PowerPoint detection is required.'
Need $maint 'HKCU:\Software\Microsoft\Office\$HostName\Addins\OMNIX' 'VSTO registration must use the Microsoft-documented versionless per-user Office Addins path.'
Need $maint 'Get-LegacyRegistrationPaths' 'old incorrect versioned OMNIX registration must be cleaned safely.'
Need $maint "'LoadBehavior' -Value 3" 'automatic supported VSTO load registration must be repaired.'
Need $maint "New-ItemProperty -LiteralPath `$path -Name 'Manifest'" 'registration must point at the installed signed VSTO manifest.'
Need $maint 'OMNIX.Core.dll is missing' 'maintenance must fail closed if the installed OMNIX payload is incomplete.'
Need $maint 'AuditOnly' 'a read-only diagnostic mode must remain available.'
Need $maint 'never' 'maintenance safety boundary must stay explicit.'
Need $maint 'Trust Center' 'maintenance must explicitly state that Trust Center is untouched.'
Need $maint 'New-Object System.Uri -ArgumentList $path' 'manifest URI construction must remain Windows PowerShell 5.1 compatible.'

# No Office security/recovery manipulation or arbitrary persistence.
ForbidRegex $maint '(?i)New-ItemProperty[^\r\n]*(DisabledItems|CrashingAddinList|DoNotDisableAddinList)' 'maintenance may not modify shared Office recovery state.'
ForbidRegex $maint '(?i)Remove-Item[^\r\n]*Resiliency' 'maintenance may not delete Office Resiliency.'
ForbidRegex $maint '(?i)HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run' 'do not replace the transparent scheduled task with a Run-key persistence mechanism.'
ForbidRegex $maint '(?i)Start-Process[^\r\n]*(EXCEL|WINWORD|POWERPNT)' 'background maintenance must not launch Office.'

# Transparent current-user scheduled task, limited privilege only.
Need $task "'OMNIX Office Registration Maintenance'" 'maintenance task needs a stable visible name.'
Need $task 'New-ScheduledTaskTrigger -AtLogOn' 'future Office installs should be detected at user sign-in.'
Need $task '-RunLevel Limited' 'maintenance must never request highest/elevated privileges.'
Need $task '-LogonType Interactive' 'task must remain scoped to the installing interactive user.'
Need $task 'Unregister-ScheduledTask' 'uninstall must be able to remove the maintenance task.'
ForbidRegex $task '(?i)-RunLevel\s+Highest' 'maintenance may not elevate.'
ForbidRegex $task '(?i)(-UserId\s+["'']?(NT AUTHORITY\\SYSTEM|SYSTEM)["'']?|New-ScheduledTaskPrincipal[^\r\n]*SYSTEM)' 'maintenance may not configure the scheduled task to run as SYSTEM.'
ForbidRegex $task '(?i)Register-ScheduledTask[^\r\n]*-Password' 'maintenance must not store a user password.'

# Installer/package integration must be explicit and uninstall-clean.
Need $package 'office-registration-maintenance.ps1' 'maintenance scanner must be packaged.'
Need $package 'install-maintenance-task.ps1' 'maintenance task helper must be packaged.'
Need $installer 'CanonicalRegAddinsFmt' 'installer must use the canonical versionless Office Addins path.'
Need $installer 'Software\Microsoft\Office\%0:s\Addins\OMNIX' 'canonical per-user VSTO path must be encoded directly in installer.'
Need $installer 'LegacyRegAddinsFmt' 'installer must remove old incorrect versioned OMNIX registration.'
Need $installer 'InstallMaintenanceTask' 'installer must attempt transparent background maintenance registration.'
Need $installer 'RunRegistrationMaintenance' 'installer must immediately re-scan/verify current Office hosts.'
Need $installer 'RemoveMaintenanceTask' 'uninstall/reinstall must clean the OMNIX maintenance task.'
Need $installer 'Rescan Office Integration' 'user needs a visible manual repair path if policy blocks the task.'
Need $installer 'current-user' 'installer must disclose current-user background maintenance scope.'
Need $installer 'Office Resiliency state preserved unchanged' 'automatic integration may not bypass Office recovery/security state.'

# Real acceptance stays compatible with Windows PowerShell 5.1 / .NET Framework.
$real = 'tools/office-maintenance-real-acceptance.ps1'
Parse-Ps $real
Need $real 'Get-Sha256Hex' 'real acceptance needs framework-compatible hashing.'
ForbidRegex $real '\[Convert\]::ToHexString|SHA256\]::HashData' '.NET Core-only hashing APIs must not enter Windows PowerShell 5.1 acceptance.'

if ($failures.Count -gt 0) {
    Write-Host 'OMNIX OFFICE-MAINTENANCE CONTRACT: FAIL' -ForegroundColor Red
    foreach ($f in $failures) { Write-Host " - $f" -ForegroundColor Red }
    exit 1
}
Write-Host 'OMNIX OFFICE-MAINTENANCE CONTRACT: PASS'
Write-Host 'Automatic supported-host registration remains per-user, limited, transparent and Office-security-preserving.'
exit 0
