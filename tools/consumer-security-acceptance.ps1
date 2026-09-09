# OMNIX consumer-machine security acceptance
#
# Run on the real Windows consumer test machine with normal protections ENABLED.
# This script does NOT disable Defender, change SmartScreen, add exclusions, change firewall rules,
# or bypass any warning. It requires Defender real-time protection, runs a normal custom scan of the
# exact installer, and records the user's explicit SmartScreen observation.
#
# SmartScreen cannot be truthfully automated without changing/bypassing the very UI being tested.
# The user must launch the exact installer normally and provide one of:
#   NotBlocked          - normal launch had no SmartScreen block
#   WarnedButAllowed    - SmartScreen warned, publisher/hash was reviewed, user chose the normal UI path
#   Blocked             - SmartScreen blocked the installer
#   NotTested           - no SmartScreen observation yet (FAIL)
#
# A valid trusted production Authenticode signature is checked separately by final-production-gate.ps1.

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$InstallerPath,

    [Parameter(Mandatory=$true)]
    [ValidateSet('NotBlocked','WarnedButAllowed','Blocked','NotTested')]
    [string]$SmartScreenDisposition,

    [string]$OutputPath = "$env:LOCALAPPDATA\OMNIX\logs\consumer-security-acceptance.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) { throw "Installer not found: $InstallerPath" }
$installer = Get-Item -LiteralPath $InstallerPath
if ($installer.Length -lt 1MB) { throw "Installer is unexpectedly small: $($installer.Length) bytes" }
$installerHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $installer.FullName).Hash.ToLowerInvariant()

$outDir = Split-Path -Parent $OutputPath
if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

$failures = New-Object System.Collections.Generic.List[string]
$defenderAvailable = $false
$antivirusEnabled = $false
$realTimeEnabled = $false
$behaviorMonitorEnabled = $false
$signatureAgeHours = $null
$scanCompleted = $false
$installerDetectionCount = 0
$scanStarted = Get-Date

try {
    $status = Get-MpComputerStatus -ErrorAction Stop
    $defenderAvailable = $true
    $antivirusEnabled = [bool]$status.AntivirusEnabled
    $realTimeEnabled = [bool]$status.RealTimeProtectionEnabled
    try { $behaviorMonitorEnabled = [bool]$status.BehaviorMonitorEnabled } catch { $behaviorMonitorEnabled = $false }

    if ($null -ne $status.AntivirusSignatureLastUpdated) {
        $signatureAgeHours = [Math]::Round(((Get-Date) - [DateTime]$status.AntivirusSignatureLastUpdated).TotalHours, 2)
    }

    if (-not $antivirusEnabled) { $failures.Add('Microsoft Defender Antivirus is not enabled on the consumer test machine.') }
    if (-not $realTimeEnabled) { $failures.Add('Microsoft Defender real-time protection is not enabled; consumer-realistic security evidence is invalid.') }
    if (-not $behaviorMonitorEnabled) { $failures.Add('Microsoft Defender behavior monitoring is not enabled.') }
    if ($null -eq $signatureAgeHours -or [double]$signatureAgeHours -gt 72) {
        $failures.Add('Microsoft Defender signatures are missing or older than 72 hours.')
    }

    # Run the scan only under normal protection state. Never add exclusions or relax policy.
    if ($antivirusEnabled -and $realTimeEnabled) {
        $scanStarted = Get-Date
        Start-MpScan -ScanType CustomScan -ScanPath $installer.FullName -ErrorAction Stop
        $scanCompleted = $true

        try {
            $detections = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object {
                $timeOk = $true
                try { $timeOk = ([DateTime]$_.InitialDetectionTime -ge $scanStarted.AddMinutes(-2)) } catch { }
                $resourceMatch = $false
                foreach ($resource in @($_.Resources)) {
                    if ([string]$resource -like ('*' + $installer.FullName + '*') -or
                        [string]$resource -like ('*' + $installer.Name + '*')) {
                        $resourceMatch = $true
                    }
                }
                $timeOk -and $resourceMatch
            })
            $installerDetectionCount = $detections.Count
        } catch { $installerDetectionCount = 0 }

        if ($installerDetectionCount -gt 0) {
            $failures.Add("Microsoft Defender recorded $installerDetectionCount detection(s) associated with the tested installer.")
        }
    }
}
catch {
    $failures.Add('Microsoft Defender consumer-machine verification failed: ' + $_.Exception.Message)
}

$smartScreenPass = $false
switch ($SmartScreenDisposition) {
    'NotBlocked'       { $smartScreenPass = $true }
    'WarnedButAllowed' { $smartScreenPass = $true }
    'Blocked'          { $failures.Add('SmartScreen blocked the tested installer.'); $smartScreenPass = $false }
    'NotTested'        { $failures.Add('SmartScreen was not tested through the normal Windows UI.'); $smartScreenPass = $false }
}

$report = [ordered]@{
    TestId = 'CONSUMER-SECURITY-REAL-001'
    EvidenceSchema = 1
    TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    Installer = [ordered]@{
        FileName = $installer.Name
        SizeBytes = [int64]$installer.Length
        Sha256 = $installerHash
    }
    Defender = [ordered]@{
        Available = $defenderAvailable
        AntivirusEnabled = $antivirusEnabled
        RealTimeProtectionEnabled = $realTimeEnabled
        BehaviorMonitorEnabled = $behaviorMonitorEnabled
        SignatureAgeHours = $signatureAgeHours
        CustomScanCompleted = $scanCompleted
        InstallerDetectionCount = $installerDetectionCount
        Pass = [bool]($defenderAvailable -and $antivirusEnabled -and $realTimeEnabled -and $behaviorMonitorEnabled -and $scanCompleted -and $installerDetectionCount -eq 0 -and $null -ne $signatureAgeHours -and [double]$signatureAgeHours -le 72)
    }
    SmartScreen = [ordered]@{
        Disposition = $SmartScreenDisposition
        EvidenceKind = 'Explicit user observation through normal Windows SmartScreen UI; script never bypasses or changes SmartScreen.'
        Pass = $smartScreenPass
    }
    FailureCount = $failures.Count
    Failures = @($failures)
    OverallPass = ($failures.Count -eq 0)
    Safety = 'No Defender exclusions, no protection disablement, no SmartScreen/policy/firewall modification.'
}

$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$report | ConvertTo-Json -Depth 8
if (-not $report.OverallPass) { exit 1 }
exit 0
