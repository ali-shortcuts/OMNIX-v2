# OMNIX real-machine acceptance preflight.
#
# Read-only by design. This script does not launch Office, install software, write registry state,
# change networking/firewall/security settings, restart Windows, or read Office documents.
# It validates that the current PowerShell process is running in an interactive desktop session,
# that the required Office hosts are installed, and (optionally) that an already-installed OMNIX
# payload matches its source-bound build identity.

[CmdletBinding()]
param(
    [string]$InstallerPath,
    [string]$ExpectedInstallerSha256,
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\OMNIX",
    [string]$SourceCommit,
    [switch]$RequireInstalledPayload,
    [switch]$AllowRunningOffice,
    [string]$OutputPath = "$env:LOCALAPPDATA\OMNIX\logs\real-machine-preflight.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$bindingScript = Join-Path $scriptDir 'real-evidence-binding.ps1'

$failures = @()
$hostRows = @()
$currentSession = -1
$explorerSameSession = $false
$currentUserIsSystem = $false
$installerSha = $null
$payloadBinding = $null

function Add-Failure([string]$message) {
    $script:failures += $message
}

function Get-HklmString([string]$SubKey, [string]$ValueName) {
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64,[Microsoft.Win32.RegistryView]::Registry32)) {
        $base = $null
        $key = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view)
            $key = $base.OpenSubKey($SubKey,$false)
            if ($null -ne $key) {
                $value = [string]$key.GetValue($ValueName,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    return [Environment]::ExpandEnvironmentVariables($value.Trim('"'))
                }
            }
        }
        catch { }
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
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey,$false)
        if ($null -eq $key) { return $null }
        $value = [string]$key.GetValue($ValueName,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ([string]::IsNullOrWhiteSpace($value)) { return $null }
        return [Environment]::ExpandEnvironmentVariables($value.Trim('"'))
    }
    catch { return $null }
    finally { if ($null -ne $key) { $key.Dispose() } }
}

function Find-OfficeExe([string]$HostName,[string]$ExeName) {
    $appPathSub = "SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$ExeName"
    $appPath = Get-HklmString $appPathSub ''
    if (-not [string]::IsNullOrWhiteSpace($appPath) -and (Test-Path -LiteralPath $appPath -PathType Leaf)) {
        return $appPath
    }

    foreach ($version in @('16.0','15.0')) {
        $root = Get-HklmString ("SOFTWARE\Microsoft\Office\$version\$HostName\InstallRoot") 'Path'
        if ([string]::IsNullOrWhiteSpace($root)) {
            $root = Get-HkcuString ("Software\Microsoft\Office\$version\$HostName\InstallRoot") 'Path'
        }
        if (-not [string]::IsNullOrWhiteSpace($root)) {
            $candidate = Join-Path $root $ExeName
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }

        $folder = if ($version -eq '16.0') { 'Office16' } else { 'Office15' }
        foreach ($programRoot in @($env:ProgramFiles,${env:ProgramFiles(x86)})) {
            if ([string]::IsNullOrWhiteSpace($programRoot)) { continue }
            foreach ($candidate in @(
                (Join-Path $programRoot ("Microsoft Office\root\$folder\$ExeName")),
                (Join-Path $programRoot ("Microsoft Office\$folder\$ExeName"))
            )) {
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
            }
        }
    }
    return $null
}

try {
    if ($env:OS -ne 'Windows_NT') {
        Add-Failure 'Real Office acceptance requires Windows.'
    }

    try {
        $currentSession = [int](Get-Process -Id $PID -ErrorAction Stop).SessionId
    }
    catch {
        Add-Failure ('Could not determine the current Windows session: ' + $_.Exception.Message)
    }

    if ($currentSession -eq 0) {
        Add-Failure 'Current process is in Windows Session 0. Real Office/UI acceptance requires an interactive user desktop session.'
    }

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $currentUserIsSystem = $identity.IsSystem
        if ($currentUserIsSystem) {
            Add-Failure 'Current process is running as LocalSystem. Real Office/UI acceptance must run as the intended interactive user.'
        }
    }
    catch {
        Add-Failure ('Could not inspect current Windows identity: ' + $_.Exception.Message)
    }

    if ($currentSession -gt 0) {
        $explorers = @(Get-Process explorer -ErrorAction SilentlyContinue | Where-Object { [int]$_.SessionId -eq $currentSession })
        $explorerSameSession = ($explorers.Count -gt 0)
        if (-not $explorerSameSession) {
            Add-Failure 'No Explorer shell is running in the current session. UI Automation evidence requires a real interactive desktop.'
        }
    }

    $officeHosts = @(
        [pscustomobject]@{ Name='Excel'; Exe='EXCEL.EXE'; Process='EXCEL' },
        [pscustomobject]@{ Name='Word'; Exe='WINWORD.EXE'; Process='WINWORD' },
        [pscustomobject]@{ Name='PowerPoint'; Exe='POWERPNT.EXE'; Process='POWERPNT' }
    )

    foreach ($officeHost in $officeHosts) {
        $exePath = Find-OfficeExe $officeHost.Name $officeHost.Exe
        $installed = -not [string]::IsNullOrWhiteSpace($exePath)
        $running = @(Get-Process -Name $officeHost.Process -ErrorAction SilentlyContinue).Count -gt 0
        $hostRows += [pscustomobject]@{
            Host = $officeHost.Name
            Installed = $installed
            Running = $running
        }
        if (-not $installed) { Add-Failure ("Required Office host is not installed: $($officeHost.Name).") }
        if ($running -and -not $AllowRunningOffice) {
            Add-Failure ("$($officeHost.Name) is already running. Close Office applications before starting the canonical acceptance run.")
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($InstallerPath)) {
        if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
            Add-Failure ("Installer not found: $InstallerPath")
        }
        else {
            $installerItem = Get-Item -LiteralPath $InstallerPath
            if ($installerItem.Length -le 0) {
                Add-Failure 'Installer is empty.'
            }
            else {
                $installerSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $installerItem.FullName).Hash.ToLowerInvariant()
                if (-not [string]::IsNullOrWhiteSpace($ExpectedInstallerSha256)) {
                    $expected = $ExpectedInstallerSha256.Trim().ToLowerInvariant()
                    if ($expected -notmatch '^[0-9a-f]{64}$') {
                        Add-Failure 'ExpectedInstallerSha256 must be 64 hexadecimal characters.'
                    }
                    elseif ($installerSha -ne $expected) {
                        Add-Failure 'Installer SHA256 does not match ExpectedInstallerSha256.'
                    }
                }
            }
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ExpectedInstallerSha256)) {
        Add-Failure 'ExpectedInstallerSha256 was provided without InstallerPath.'
    }

    if ($RequireInstalledPayload) {
        if (-not (Test-Path -LiteralPath $bindingScript -PathType Leaf)) {
            Add-Failure ("Evidence binding helper is missing: $bindingScript")
        }
        else {
            try {
                . $bindingScript
                $corePath = Join-Path $InstallDir 'OMNIX.Core.dll'
                $payloadBinding = New-OmnixEvidenceBinding -CorePath $corePath -SourceCommit $SourceCommit
            }
            catch {
                Add-Failure ('Installed payload identity validation failed: ' + $_.Exception.Message)
            }
        }
    }
}
catch {
    Add-Failure ('Unexpected preflight exception: ' + $_.Exception.Message)
}

$report = [ordered]@{
    TestId = 'REAL-MACHINE-PREFLIGHT-001'
    EvidenceSchema = 1
    TimestampUtc = [DateTime]::UtcNow.ToString('o')
    Windows = ($env:OS -eq 'Windows_NT')
    SessionId = $currentSession
    InteractiveSession = ($currentSession -gt 0 -and $explorerSameSession -and -not $currentUserIsSystem)
    ExplorerInSameSession = $explorerSameSession
    CurrentUserIsSystem = $currentUserIsSystem
    OfficeHosts = $hostRows
    InstallerSha256 = $installerSha
    InstalledPayloadRequired = [bool]$RequireInstalledPayload
    InstalledPayloadValidated = ($null -ne $payloadBinding)
    EvidenceBinding = $payloadBinding
    FailureCount = $failures.Count
    Failures = $failures
    OverallPass = ($failures.Count -eq 0)
    Safety = 'Read-only preflight: no Office launch, install, registry write, network/firewall/security change, restart, or document access.'
}

$outDir = Split-Path -Parent $OutputPath
if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$report | ConvertTo-Json -Depth 10

if (-not $report.OverallPass) { exit 1 }
exit 0
