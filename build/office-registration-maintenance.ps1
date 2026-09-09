# OMNIX Office registration maintenance
#
# User-authorized, per-user maintenance for supported desktop Office hosts (Office 2013+).
# It scans only Excel/Word/PowerPoint installation evidence and repairs ONLY OMNIX-owned HKCU
# VSTO registration when the corresponding host is actually installed. It never clears Office
# Resiliency/DisabledItems, never changes Trust Center, never launches Office, never elevates,
# and never touches documents or provider credentials.

[CmdletBinding()]
param(
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\OMNIX",
    [string]$OutputPath = "$env:LOCALAPPDATA\OMNIX\logs\office-registration-maintenance.json",
    [switch]$AuditOnly,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SupportedVersions = @('16.0','15.0')
$Hosts = @(
    [pscustomobject]@{ Name='Excel'; Exe='EXCEL.EXE' },
    [pscustomobject]@{ Name='Word'; Exe='WINWORD.EXE' },
    [pscustomobject]@{ Name='PowerPoint'; Exe='POWERPNT.EXE' }
)

function Open-Hklm([Microsoft.Win32.RegistryView]$View) {
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $View)
}

function Get-HklmString([string]$SubKey, [string]$ValueName) {
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64,[Microsoft.Win32.RegistryView]::Registry32)) {
        $base = $null; $key = $null
        try {
            $base = Open-Hklm $view
            $key = $base.OpenSubKey($SubKey, $false)
            if ($null -ne $key) {
                $value = [string]$key.GetValue($ValueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim('"') }
            }
        } catch { }
        finally {
            if ($null -ne $key) { $key.Dispose() }
            if ($null -ne $base) { $base.Dispose() }
        }
    }
    return $null
}

function Get-HkcuString([string]$SubKey, [string]$ValueName) {
    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey, $false)
        if ($null -eq $key) { return $null }
        $value = [string]$key.GetValue($ValueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ([string]::IsNullOrWhiteSpace($value)) { return $null }
        return $value.Trim('"')
    } catch { return $null }
    finally { if ($null -ne $key) { $key.Dispose() } }
}

function Get-KnownOfficeExePaths([string]$Version, [string]$Exe) {
    $folder = if ($Version -eq '16.0') { 'Office16' } else { 'Office15' }
    $paths = @()
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $paths += (Join-Path $root ("Microsoft Office\root\$folder\$Exe"))
        $paths += (Join-Path $root ("Microsoft Office\$folder\$Exe"))
    }
    return $paths
}

function Get-InstallRootExe([string]$Version, $OfficeHost) {
    $sub = "SOFTWARE\Microsoft\Office\$Version\$($OfficeHost.Name)\InstallRoot"
    $root = Get-HklmString $sub 'Path'
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Get-HkcuString ("Software\Microsoft\Office\$Version\$($OfficeHost.Name)\InstallRoot") 'Path'
    }
    if ([string]::IsNullOrWhiteSpace($root)) { return $null }
    return (Join-Path ([Environment]::ExpandEnvironmentVariables($root)) $OfficeHost.Exe)
}

function Test-OfficeHostInstalled([string]$Version, $OfficeHost) {
    # Prefer executable-backed evidence. Stale Office registry keys are intentionally not enough
    # to create a new OMNIX Addins key for a host/version that is no longer installed.
    $installRootExe = Get-InstallRootExe $Version $OfficeHost
    if (-not [string]::IsNullOrWhiteSpace($installRootExe) -and (Test-Path -LiteralPath $installRootExe -PathType Leaf)) {
        return $true
    }

    foreach ($candidate in Get-KnownOfficeExePaths $Version $OfficeHost.Exe) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $true }
    }

    # App Paths is useful for Click-to-Run. Bind it to the detected major generation so an Office16
    # App Path cannot accidentally make us register a phantom Office15 host.
    $appPath = Get-HklmString ("SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$($OfficeHost.Exe)") ''
    if (-not [string]::IsNullOrWhiteSpace($appPath) -and (Test-Path -LiteralPath $appPath -PathType Leaf)) {
        $client = Get-HklmString 'SOFTWARE\Microsoft\Office\ClickToRun\Configuration' 'ClientVersionToReport'
        if ($Version -eq '16.0' -and $client -match '^16\.') { return $true }
        if ($Version -eq '15.0' -and $client -match '^15\.') { return $true }
    }
    return $false
}

function Get-ManifestUri([string]$HostName) {
    $path = Join-Path $InstallDir ("OMNIX.$HostName.vsto")
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required VSTO deployment manifest is missing: OMNIX.$HostName.vsto"
    }
    # Keep this compatible with Windows PowerShell 5.1/.NET Framework used on consumer Office PCs.
    $uri = New-Object System.Uri -ArgumentList $path
    return ($uri.AbsoluteUri + '|vstolocal')
}

function Get-RegistrationState([string]$Version, [string]$HostName, [string]$ExpectedManifest) {
    $path = "HKCU:\Software\Microsoft\Office\$Version\$HostName\Addins\OMNIX"
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        return [pscustomobject]@{ Exists=$false; Correct=$false; LoadBehavior=$null; Manifest=$null }
    }
    $item = Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
    $load = if ($null -ne $item) { $item.LoadBehavior } else { $null }
    $manifest = if ($null -ne $item) { [string]$item.Manifest } else { $null }
    $correct = ($load -eq 3 -and [string]::Equals($manifest, $ExpectedManifest, [StringComparison]::OrdinalIgnoreCase))
    return [pscustomobject]@{ Exists=$true; Correct=$correct; LoadBehavior=$load; Manifest=$manifest }
}

function Ensure-Registration([string]$Version, [string]$HostName, [string]$Manifest) {
    $path = "HKCU:\Software\Microsoft\Office\$Version\$HostName\Addins\OMNIX"
    New-Item -Path $path -Force | Out-Null
    New-ItemProperty -LiteralPath $path -Name 'Description' -Value 'OMNIX AI Office' -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $path -Name 'FriendlyName' -Value 'OMNIX' -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $path -Name 'LoadBehavior' -Value 3 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -LiteralPath $path -Name 'Manifest' -Value $Manifest -PropertyType String -Force | Out-Null
}

$report = [ordered]@{
    TestId = 'OFFICE-REGISTRATION-MAINTENANCE-001'
    EvidenceSchema = 2
    TimestampUtc = [DateTime]::UtcNow.ToString('o')
    AuditOnly = [bool]$AuditOnly
    SupportedVersions = $SupportedVersions
    InstalledHostCount = 0
    UniqueInstalledHostCount = 0
    CorrectBeforeCount = 0
    RepairedCount = 0
    CorrectAfterCount = 0
    Failures = @()
    Results = @()
    Safety = 'Executable-backed detection; per-user OMNIX-owned HKCU Addins keys only; no Office Resiliency/Trust Center/document/network/provider-secret changes.'
    OverallPass = $false
}

$failures = @()
$rows = @()

try {
    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'OMNIX.Core.dll') -PathType Leaf)) {
        throw 'OMNIX.Core.dll is missing from the configured installation directory.'
    }

    foreach ($version in $SupportedVersions) {
        foreach ($officeHost in $Hosts) {
            $installed = Test-OfficeHostInstalled $version $officeHost
            if (-not $installed) { continue }

            $report.InstalledHostCount++
            try {
                $manifest = Get-ManifestUri $officeHost.Name
                $before = Get-RegistrationState $version $officeHost.Name $manifest
                if ($before.Correct) { $report.CorrectBeforeCount++ }
                $changed = $false

                if (-not $before.Correct -and -not $AuditOnly) {
                    Ensure-Registration $version $officeHost.Name $manifest
                    $changed = $true
                    $report.RepairedCount++
                }

                $after = Get-RegistrationState $version $officeHost.Name $manifest
                $pass = if ($AuditOnly) { $true } else { [bool]$after.Correct }
                if ($after.Correct) { $report.CorrectAfterCount++ }
                if (-not $pass) { $failures += "$version/$($officeHost.Name) OMNIX registration is not correct after maintenance." }

                $rows += [pscustomobject]@{
                    Version=$version
                    Host=$officeHost.Name
                    Installed=$true
                    CorrectBefore=[bool]$before.Correct
                    Changed=[bool]$changed
                    CorrectAfter=[bool]$after.Correct
                    Pass=[bool]$pass
                }
            }
            catch {
                $failures += "$version/$($officeHost.Name): $($_.Exception.Message)"
                $rows += [pscustomobject]@{
                    Version=$version; Host=$officeHost.Name; Installed=$true; CorrectBefore=$false;
                    Changed=$false; CorrectAfter=$false; Pass=$false
                }
            }
        }
    }
}
catch {
    $failures += $_.Exception.Message
}

$report.UniqueInstalledHostCount = @($rows | Select-Object -ExpandProperty Host -Unique).Count
$report.Results = $rows
$report.Failures = $failures
$report.OverallPass = ($failures.Count -eq 0)

try {
    $dir = Split-Path -Parent $OutputPath
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
} catch { }

if (-not $Quiet) { $report | ConvertTo-Json -Depth 8 }
if (-not $report.OverallPass) { exit 1 }
exit 0
