# OMNIX final production evidence core. Canonical entrypoint: final-production-gate.ps1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InstallerPath,
    [string]$OfficeE2EReport="$env:LOCALAPPDATA\OMNIX\logs\full-office-e2e.json",
    [string]$LifecycleReport="$env:LOCALAPPDATA\OMNIX\logs\lifecycle-acceptance.json",
    [string]$ConsumerSecurityReport="$env:LOCALAPPDATA\OMNIX\logs\consumer-security-acceptance.json",
    [string]$OfficePersistenceReport="$env:LOCALAPPDATA\OMNIX\logs\real-office-acceptance.json",
    [string]$OfficeUiReport="$env:LOCALAPPDATA\OMNIX\logs\real-office-ui-acceptance.json",
    [string]$OfficeRestartReport="$env:LOCALAPPDATA\OMNIX\logs\real-office-restart-acceptance.json",
    [string]$LocalOfflineReport="$env:LOCALAPPDATA\OMNIX\logs\local-ai-offline-acceptance.json",
    [string]$ProviderReport="$env:LOCALAPPDATA\OMNIX\logs\provider-acceptance.json",
    [string]$PrivacyReport=".\build\artifact\privacy-acceptance.json",
    [string]$BaseReadinessOutput=".\release-evidence\release-readiness.json",
    [string]$OutputPath=".\release-evidence\final-production-gate.json"
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Read-Json([string]$path,[string]$label){
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "$label not found: $path"}
    try{return Get-Content -LiteralPath $path -Raw|ConvertFrom-Json}catch{throw "$label is not valid JSON: $path — $($_.Exception.Message)"}
}
function Fail($list,[string]$m){if(-not[string]::IsNullOrWhiteSpace($m)){$list.Add($m)}}
function Git-Head{try{$s=(& git rev-parse HEAD 2>$null).Trim().ToLowerInvariant();if($LASTEXITCODE -eq 0 -and $s -match '^[0-9a-f]{40}$'){return $s}}catch{};return $null}

if(-not(Test-Path -LiteralPath $InstallerPath -PathType Leaf)){throw "Installer not found: $InstallerPath"}
$installer=Get-Item -LiteralPath $InstallerPath
if($installer.Length -lt 1MB){throw 'Installer is unexpectedly small.'}
$hash=(Get-FileHash -Algorithm SHA256 -LiteralPath $installer.FullName).Hash.ToLowerInvariant()

$scriptDir=Split-Path -Parent $MyInvocation.MyCommand.Path
$baseScript=Join-Path $scriptDir 'release-readiness.ps1'
if(-not(Test-Path -LiteralPath $baseScript -PathType Leaf)){throw 'release-readiness.ps1 is missing.'}
foreach($dir in @((Split-Path -Parent $BaseReadinessOutput),(Split-Path -Parent $OutputPath))){if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}}

$args=@('-NoProfile','-File',$baseScript,
 '-OfficePersistenceReport',$OfficePersistenceReport,
 '-OfficeUiReport',$OfficeUiReport,
 '-OfficeRestartReport',$OfficeRestartReport,
 '-LocalOfflineReport',$LocalOfflineReport,
 '-ProviderReport',$ProviderReport,
 '-PrivacyReport',$PrivacyReport,
 '-InstallerPath',$installer.FullName,
 '-OutputPath',$BaseReadinessOutput)
$baseProc=Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
if(-not(Test-Path -LiteralPath $BaseReadinessOutput -PathType Leaf)){throw "Base readiness evidence missing (exit=$($baseProc.ExitCode))."}

$base=Read-Json $BaseReadinessOutput 'Base release readiness'
$office=Read-Json $OfficeE2EReport 'Office E2E'
$lifecycle=Read-Json $LifecycleReport 'Lifecycle'
$security=Read-Json $ConsumerSecurityReport 'Consumer security'
$failures=New-Object System.Collections.Generic.List[string]

if($baseProc.ExitCode -ne 0){Fail $failures "Base release-readiness exited $($baseProc.ExitCode)."}
if($base.TestId -ne 'OMNIX-RELEASE-READINESS-001'){Fail $failures 'Unexpected base readiness TestId.'}
if(-not[bool]$base.OverallPass){Fail $failures 'Base release-readiness failed.'}
if([string]$base.Installer.Sha256 -ne $hash){Fail $failures 'Base readiness is bound to a different installer.'}
if([string]$base.Installer.SignatureStatus -ne 'Valid'){Fail $failures 'Production Authenticode signature is not Valid.'}
if([bool]$base.Installer.SelfSigned){Fail $failures 'Production installer is self-signed.'}
if(-not[bool]$base.Installer.Timestamped){Fail $failures 'Production installer signature is not timestamped.'}

# Full Office install + automatic maintenance + persistence/UI/function/write-bounds/AI marker route.
if($office.TestId -ne 'OFFICE-E2E-REAL-001'){Fail $failures 'Unexpected Office E2E TestId.'}
if([int]$office.EvidenceSchema -lt 4){Fail $failures 'Office E2E schema is too old; automatic Office-maintenance evidence is mandatory.'}
if(-not[bool]$office.OverallPass){Fail $failures 'Full Office E2E failed.'}
if([string]$office.Installer.Sha256 -ne $hash){Fail $failures 'Office E2E used a different installer.'}
if($null -eq $office.Installer.HashMatchedExpected -or -not[bool]$office.Installer.HashMatchedExpected){Fail $failures 'Office E2E was not explicitly bound to the intended SHA256.'}

if($null -eq $office.Maintenance){Fail $failures 'Automatic Office registration-maintenance evidence is missing.'}
else{
 if([string]$office.Maintenance.TestId -ne 'OFFICE-MAINTENANCE-REAL-001'){Fail $failures 'Unexpected Office maintenance TestId.'}
 if(-not[bool]$office.Maintenance.OverallPass){Fail $failures 'Automatic Office registration-maintenance acceptance failed.'}
 if(-not[bool]$office.Maintenance.MaintenanceTaskPresent){Fail $failures 'Automatic Office maintenance task is missing.'}
 if(-not[bool]$office.Maintenance.MaintenanceTaskLimited){Fail $failures 'Office maintenance task is not limited privilege.'}
 if(-not[bool]$office.Maintenance.MaintenanceTaskCurrentUser){Fail $failures 'Office maintenance task is not scoped to the current user.'}
 if(-not[bool]$office.Maintenance.MaintenanceTaskLogonTrigger){Fail $failures 'Office maintenance task has no user-logon trigger.'}
 if([int]$office.Maintenance.InstalledHostCount -lt 3){Fail $failures 'Office maintenance did not detect Excel + Word + PowerPoint.'}
 if([int]$office.Maintenance.RegisteredHostCount -lt 3){Fail $failures 'Office maintenance did not prove OMNIX registration in all three Office hosts.'}
 if(-not[bool]$office.Maintenance.AllInstalledRegistrationsPass){Fail $failures 'One or more Office registrations are unhealthy after maintenance.'}
 if(-not[bool]$office.Maintenance.SharedOfficeResiliencyPreserved){Fail $failures 'Office Resiliency changed during automatic maintenance.'}
 if(-not[bool]$office.Maintenance.OfficeProcessesRemainedClosed){Fail $failures 'Automatic maintenance launched or left an Office process.'}
}

if($null -eq $office.WriteBoundary){Fail $failures 'Office AI write-boundary evidence is missing.'}
else{
 if([string]$office.WriteBoundary.TestId -ne 'OFFICE-WRITE-BOUNDARY-REAL-001'){Fail $failures 'Unexpected Office write-boundary TestId.'}
 if(-not[bool]$office.WriteBoundary.OverallPass){Fail $failures 'Approved-but-invalid Office AI write-boundary acceptance failed.'}
 if(-not[bool]$office.WriteBoundary.RequiredHostCountPass){Fail $failures 'Write-boundary acceptance did not prove Excel + Word + PowerPoint.'}
 if(-not[bool]$office.WriteBoundary.AllBoundaryChecksPass){Fail $failures 'One or more host-level write bounds failed.'}
}

if($null -eq $office.AiRoundTrip){Fail $failures 'Office AI E2E evidence is missing.'}
else{
 if(-not[bool]$office.AiRoundTrip.Required){Fail $failures 'Office AI E2E was skipped.'}
 if([string]$office.AiRoundTrip.TestId -ne 'OFFICE-AI-E2E-REAL-001'){Fail $failures 'Unexpected Office AI E2E TestId.'}
 if(-not[bool]$office.AiRoundTrip.OverallPass){Fail $failures 'Office context -> AI -> rendered UI failed.'}
 if(-not[bool]$office.AiRoundTrip.RequiredHostCountPass){Fail $failures 'Office AI E2E did not prove all 3 hosts.'}
 if(-not[bool]$office.AiRoundTrip.AllMarkerRoundTripsPass){Fail $failures 'At least one host failed random-marker AI round-trip.'}
 if(-not[bool]$office.AiRoundTrip.AllProcessesExitedPass){Fail $failures 'Office AI E2E left an orphan Office process.'}
}

# Exact-build repair/uninstall lifecycle, including the transparent maintenance task.
if($lifecycle.TestId -ne 'LIFECYCLE-REAL-002'){Fail $failures 'Lifecycle v2 evidence is required.'}
if([int]$lifecycle.EvidenceSchema -lt 3){Fail $failures 'Lifecycle evidence schema is too old; maintenance-task lifecycle evidence is mandatory.'}
if([string]$lifecycle.Phase -ne 'AfterUninstall'){Fail $failures 'Lifecycle must finish at AfterUninstall.'}
if([string]$lifecycle.InstallerSha256 -ne $hash){Fail $failures 'Lifecycle repair was not bound to the final installer hash.'}
if(-not[bool]$lifecycle.OverallPass){Fail $failures 'Lifecycle v2 failed.'}
if(-not[bool]$lifecycle.BaselinePass){Fail $failures 'Lifecycle baseline failed.'}
if(-not[bool]$lifecycle.RepairPass){Fail $failures 'Same-build repair/reinstall failed.'}
if(-not[bool]$lifecycle.SettingsPreservedAcrossRepair){Fail $failures 'Settings were not preserved across repair.'}
if(-not[bool]$lifecycle.CorePreservedAcrossRepair){Fail $failures 'Installed Core hash changed during same-build repair.'}
if(-not[bool]$lifecycle.SharedOfficeRecoveryStatePreservedAcrossRepair){Fail $failures 'Shared Office DisabledItems/CrashingAddinList/DoNotDisableAddinList changed during repair.'}
if(-not[bool]$lifecycle.RegistrationHealthyAfterRepair){Fail $failures 'OMNIX registration was unhealthy after repair.'}
if(-not[bool]$lifecycle.MaintenanceTaskHealthyAfterRepair){Fail $failures 'OMNIX maintenance task was unhealthy after repair.'}
if(-not[bool]$lifecycle.UninstallPass){Fail $failures 'Uninstall lifecycle failed.'}
if(-not[bool]$lifecycle.SettingsPreservedAcrossUninstall){Fail $failures 'User settings were not preserved when requested.'}
if(-not[bool]$lifecycle.OmnixRegistrationRemoved){Fail $failures 'OMNIX registration remains after uninstall.'}
if(-not[bool]$lifecycle.MaintenanceTaskRemoved){Fail $failures 'OMNIX maintenance task remains after uninstall.'}
if(-not[bool]$lifecycle.AppPayloadRemoved){Fail $failures 'OMNIX application payload remains after uninstall.'}
if(-not[bool]$lifecycle.SharedOfficeRecoveryStatePreservedAcrossUninstall){Fail $failures 'Shared Office recovery state changed during uninstall.'}
if(-not[bool]$lifecycle.DevelopmentCertificateRemoved){Fail $failures 'Exact OMNIX development trust material remains after uninstall.'}

if($security.TestId -ne 'CONSUMER-SECURITY-REAL-001'){Fail $failures 'Unexpected consumer security TestId.'}
if([int]$security.EvidenceSchema -lt 1){Fail $failures 'Consumer security evidence schema is invalid.'}
if([string]$security.Installer.Sha256 -ne $hash){Fail $failures 'Consumer security evidence is for a different installer.'}
if(-not[bool]$security.Defender.Available){Fail $failures 'Microsoft Defender was unavailable.'}
if(-not[bool]$security.Defender.AntivirusEnabled){Fail $failures 'Defender Antivirus was disabled.'}
if(-not[bool]$security.Defender.RealTimeProtectionEnabled){Fail $failures 'Defender real-time protection was disabled.'}
if(-not[bool]$security.Defender.BehaviorMonitorEnabled){Fail $failures 'Defender behavior monitoring was disabled.'}
if(-not[bool]$security.Defender.CustomScanCompleted){Fail $failures 'Defender custom scan did not complete.'}
if([int]$security.Defender.InstallerDetectionCount -ne 0){Fail $failures 'Defender detected the final installer.'}
if(-not[bool]$security.Defender.Pass){Fail $failures 'Defender consumer acceptance failed.'}
if([string]$security.SmartScreen.Disposition -eq 'NotTested' -or [string]$security.SmartScreen.Disposition -eq 'Blocked'){Fail $failures 'SmartScreen is untested or blocked the final installer.'}
if(-not[bool]$security.SmartScreen.Pass){Fail $failures 'SmartScreen consumer acceptance failed.'}
if(-not[bool]$security.OverallPass){Fail $failures 'Consumer security acceptance failed.'}

$source=Git-Head
if([string]::IsNullOrWhiteSpace($source)){Fail $failures 'Could not resolve source Git commit.'}
if(-not[string]::IsNullOrWhiteSpace([string]$base.SourceCommit) -and -not[string]::IsNullOrWhiteSpace($source) -and [string]$base.SourceCommit -ne $source){Fail $failures 'Base readiness source commit does not match current checkout.'}

$out=[ordered]@{
 TestId='OMNIX-FINAL-PRODUCTION-GATE-002';EvidenceSchema=4;GeneratedUtc=(Get-Date).ToUniversalTime().ToString('o');SourceCommit=$source
 Installer=[ordered]@{FileName=$installer.Name;SizeBytes=[int64]$installer.Length;Sha256=$hash;SignatureStatus=[string]$base.Installer.SignatureStatus;SignerSubject=[string]$base.Installer.SignerSubject;SignerThumbprint=[string]$base.Installer.SignerThumbprint;Timestamped=[bool]$base.Installer.Timestamped}
 BaseReleaseReadinessPass=[bool]$base.OverallPass
 OfficeE2E=[ordered]@{
  Pass=[bool]$office.OverallPass
  InstallerHashMatchedExpected=[bool]$office.Installer.HashMatchedExpected
  AutomaticMaintenancePass=[bool]$office.Maintenance.OverallPass
  AutomaticMaintenanceLimited=[bool]$office.Maintenance.MaintenanceTaskLimited
  AutomaticMaintenanceAllThreeHosts=[bool]([int]$office.Maintenance.RegisteredHostCount -ge 3)
  AutomaticMaintenancePreservedResiliency=[bool]$office.Maintenance.SharedOfficeResiliencyPreserved
  WriteBoundaryPass=[bool]$office.WriteBoundary.OverallPass
  AllThreeOfficeWriteBounds=[bool]$office.WriteBoundary.AllBoundaryChecksPass
  AiRoundTripRequired=[bool]$office.AiRoundTrip.Required
  AiRoundTripPass=[bool]$office.AiRoundTrip.OverallPass
  AllThreeOfficeMarkerRoundTrips=[bool]$office.AiRoundTrip.AllMarkerRoundTripsPass
 }
 Lifecycle=[ordered]@{
  Pass=[bool]$lifecycle.OverallPass
  InstallerHashBound=([string]$lifecycle.InstallerSha256 -eq $hash)
  RepairPass=[bool]$lifecycle.RepairPass
  SettingsPreserved=[bool]($lifecycle.SettingsPreservedAcrossRepair -and $lifecycle.SettingsPreservedAcrossUninstall)
  CorePreserved=[bool]$lifecycle.CorePreservedAcrossRepair
  MaintenanceTaskHealthyAfterRepair=[bool]$lifecycle.MaintenanceTaskHealthyAfterRepair
  MaintenanceTaskRemoved=[bool]$lifecycle.MaintenanceTaskRemoved
  SharedOfficeRecoveryStatePreserved=[bool]($lifecycle.SharedOfficeRecoveryStatePreservedAcrossRepair -and $lifecycle.SharedOfficeRecoveryStatePreservedAcrossUninstall)
  RegistrationRemoved=[bool]$lifecycle.OmnixRegistrationRemoved
  PayloadRemoved=[bool]$lifecycle.AppPayloadRemoved
  DevelopmentCertificateRemoved=[bool]$lifecycle.DevelopmentCertificateRemoved
 }
 ConsumerSecurity=[ordered]@{Pass=[bool]$security.OverallPass;DefenderRealTimeProtectionEnabled=[bool]$security.Defender.RealTimeProtectionEnabled;DefenderDetectionCount=[int]$security.Defender.InstallerDetectionCount;SmartScreenDisposition=[string]$security.SmartScreen.Disposition;SmartScreenPass=[bool]$security.SmartScreen.Pass}
 Requirements=[ordered]@{ExactInstallerHashBinding=$true;ExcelWordPowerPoint=$true;AutomaticSupportedOfficeHostDiscoveryAndRegistration=$true;LimitedCurrentUserMaintenanceTask=$true;OfficeResiliencyPreservedDuringMaintenance=$true;MaintenanceTaskPreservedAcrossRepairAndRemovedOnUninstall=$true;RealOfficeAutomaticLoadAndUi=$true;BoundedApprovedOfficeWrites=$true;RealOfficeContextToAiToRenderedUi=$true;RealWindowsRestartPersistence=$true;OfflineLocalAi=$true;LiveProviderMatrixAndStreaming=$true;GatewayPrivacyBeforeSend=$true;ExactBuildRepairAndUninstallLifecycle=$true;SharedOfficeRecoveryStatePreservation=$true;ConsumerDefenderAndSmartScreen=$true;TrustedTimestampedProductionAuthenticode=$true}
 FailureCount=$failures.Count;Failures=@($failures);OverallPass=($failures.Count -eq 0)
 Privacy='Sanitized aggregate only; no API keys, prompts, response bodies, machine names, settings contents or Office document contents.'
}
$out|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $OutputPath -Encoding UTF8
$out|ConvertTo-Json -Depth 10
if(-not$out.OverallPass){exit 1};exit 0
