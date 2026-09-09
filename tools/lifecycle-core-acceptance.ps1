# OMNIX lifecycle core — precise real-machine repair/uninstall evidence.
# Canonical entrypoint is tools/lifecycle-acceptance.ps1.
#
# Unlike broad Resiliency-tree snapshots, this implementation fingerprints only the shared Office
# recovery subtrees OMNIX promises never to erase/manipulate: DisabledItems, CrashingAddinList and
# DoNotDisableAddinList. Other Office Resiliency bookkeeping may legitimately change when Office is
# launched during post-install verification and must not create a false release failure.

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Baseline','AfterRepair','AfterUninstall')]
    [string]$Phase,
    [string]$InstallerPath,
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\OMNIX",
    [string]$SettingsPath = "$env:LOCALAPPDATA\OMNIX\settings.dat",
    [string]$StatePath = "$env:LOCALAPPDATA\OMNIX\logs\lifecycle-state.json",
    [string]$OutputPath = "$env:LOCALAPPDATA\OMNIX\logs\lifecycle-acceptance.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$stateDir = Split-Path -Parent $StatePath
if ($stateDir) { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null }
$outDir = Split-Path -Parent $OutputPath
if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

function Assert-OfficeClosed {
    $running=@()
    foreach($name in @('EXCEL','WINWORD','POWERPNT')){ if(Get-Process -Name $name -ErrorAction SilentlyContinue){$running+=$name} }
    if($running.Count -gt 0){ throw "Close Excel, Word and PowerPoint before lifecycle acceptance. Running: $($running -join ', ')" }
}

function File-Hash([string]$path){
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $null}
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
}
function Text-Hash([string]$text){
    $sha=[Security.Cryptography.SHA256]::Create()
    try{
        if($null -eq $text){$text=''}
        $bytes=[Text.Encoding]::UTF8.GetBytes($text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    }finally{$sha.Dispose()}
}
function Stable-Value($v){
    if($null -eq $v){return '<null>'}
    if($v -is [byte[]]){return [Convert]::ToBase64String($v)}
    if($v -is [Array]){$x=@();foreach($i in $v){$x += [string](Stable-Value $i)};return '['+($x -join ',')+']'}
    return [string]$v
}
function Registry-Fingerprint([string]$path){
    if(-not(Test-Path $path)){return [pscustomobject]@{Exists=$false;Sha256=$null;EntryCount=0}}
    $lines=New-Object System.Collections.Generic.List[string]
    $keys=@((Get-Item -Path $path -ErrorAction Stop))+@(Get-ChildItem -Path $path -Recurse -ErrorAction SilentlyContinue)
    foreach($key in ($keys|Sort-Object Name)){
        $lines.Add('K|'+[string]$key.Name)
        try{
            $p=Get-ItemProperty -Path $key.PSPath -ErrorAction Stop
            $names=@($p.PSObject.Properties|Where-Object{$_.Name -notin @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider')}|Select-Object -ExpandProperty Name|Sort-Object)
            foreach($name in $names){$lines.Add('V|'+$key.Name+'|'+$name+'|'+(Stable-Value $p.$name))}
        }catch{}
    }
    return [pscustomobject]@{Exists=$true;Sha256=(Text-Hash ([string]::Join("`n",$lines)));EntryCount=$lines.Count}
}

function Recovery-Snapshot {
    $rows=@()
    foreach($version in @('16.0','15.0')){
        foreach($host in @('Excel','Word','PowerPoint')){
            foreach($subtree in @('DisabledItems','CrashingAddinList','DoNotDisableAddinList')){
                $path="HKCU:\Software\Microsoft\Office\$version\$host\Resiliency\$subtree"
                $fp=Registry-Fingerprint $path
                $rows += [ordered]@{Version=$version;Host=$host;Subtree=$subtree;Exists=[bool]$fp.Exists;Sha256=$fp.Sha256;EntryCount=[int]$fp.EntryCount}
            }
        }
    }
    return $rows
}
function Compare-Recovery($baseline,$current){
    $errors=New-Object System.Collections.Generic.List[string]
    foreach($b in @($baseline)){
        $c=@($current|Where-Object{$_.Version -eq $b.Version -and $_.Host -eq $b.Host -and $_.Subtree -eq $b.Subtree})|Select-Object -First 1
        if($null -eq $c){$errors.Add("Missing recovery snapshot $($b.Version)/$($b.Host)/$($b.Subtree).");continue}
        if([bool]$c.Exists -ne [bool]$b.Exists){$errors.Add("Office recovery subtree existence changed: $($b.Version)/$($b.Host)/$($b.Subtree).");continue}
        if([bool]$b.Exists -and [string]$c.Sha256 -ne [string]$b.Sha256){$errors.Add("Office recovery subtree fingerprint changed: $($b.Version)/$($b.Host)/$($b.Subtree).")}
    }
    return $errors
}

function Resolve-Manifest([string]$value){
    if([string]::IsNullOrWhiteSpace($value)){return $null}
    try{
        $v=$value.Trim()
        if($v.EndsWith('|vstolocal',[StringComparison]::OrdinalIgnoreCase)){$v=$v.Substring(0,$v.Length-'|vstolocal'.Length)}
        if($v -match '^file:'){$u=New-Object Uri($v);if(-not $u.IsFile){return $null};$v=$u.LocalPath}
        return [Environment]::ExpandEnvironmentVariables($v.Trim('"'))
    }catch{return $null}
}
function Registrations {
    $rows=@()
    foreach($version in @('16.0','15.0')){
        foreach($host in @('Excel','Word','PowerPoint')){
            $path="HKCU:\Software\Microsoft\Office\$version\$host\Addins\OMNIX"
            if(Test-Path $path){
                $p=Get-ItemProperty -Path $path
                $m=Resolve-Manifest ([string]$p.Manifest)
                $rows += [ordered]@{Version=$version;Host=$host;Exists=$true;LoadBehavior=[int]$p.LoadBehavior;ManifestExists=[bool]($m -and (Test-Path -LiteralPath $m -PathType Leaf));FriendlyName=[string]$p.FriendlyName}
            }
        }
    }
    return $rows
}
function Registration-Errors($rows){
    $errors=New-Object System.Collections.Generic.List[string]
    foreach($host in @('Excel','Word','PowerPoint')){
        $r=@($rows|Where-Object{$_.Host -eq $host -and $_.Exists})
        if($r.Count -lt 1){$errors.Add("OMNIX registration missing for $host.");continue}
        foreach($x in $r){
            if([int]$x.LoadBehavior -ne 3){$errors.Add("$host/$($x.Version) LoadBehavior is not 3.")}
            if(-not[bool]$x.ManifestExists){$errors.Add("$host/$($x.Version) manifest target is missing.")}
            if([string]$x.FriendlyName -ne 'OMNIX'){$errors.Add("$host/$($x.Version) FriendlyName is unexpected.")}
        }
    }
    return $errors
}
function Dev-Thumb {
    $p=Join-Path $InstallDir 'dev-cert-thumbprint.txt'
    if(-not(Test-Path -LiteralPath $p -PathType Leaf)){return $null}
    try{$t=(Get-Content -LiteralPath $p -Raw).Trim().Replace(' ','');if($t -match '^[0-9A-Fa-f]{40,64}$'){return $t.ToUpperInvariant()}}catch{}
    return $null
}
function Cert-Present([string]$store,[string]$thumb){if([string]::IsNullOrWhiteSpace($thumb)){return $false};return [bool](Test-Path -LiteralPath "Cert:\CurrentUser\$store\$thumb")}
function Snapshot {
    $thumb=Dev-Thumb
    return [ordered]@{
        CapturedUtc=(Get-Date).ToUniversalTime().ToString('o')
        InstallDirExists=[bool](Test-Path -LiteralPath $InstallDir -PathType Container)
        CoreExists=[bool](Test-Path -LiteralPath (Join-Path $InstallDir 'OMNIX.Core.dll') -PathType Leaf)
        CoreSha256=(File-Hash (Join-Path $InstallDir 'OMNIX.Core.dll'))
        SettingsExists=[bool](Test-Path -LiteralPath $SettingsPath -PathType Leaf)
        SettingsSha256=(File-Hash $SettingsPath)
        Registrations=@(Registrations)
        SharedRecoveryState=@(Recovery-Snapshot)
        DevelopmentCertThumbprint=$thumb
        DevelopmentCertTrustedPublisherPresent=[bool](Cert-Present 'TrustedPublisher' $thumb)
        DevelopmentCertRootPresent=[bool](Cert-Present 'Root' $thumb)
    }
}

Assert-OfficeClosed

if($Phase -eq 'Baseline'){
    if([string]::IsNullOrWhiteSpace($InstallerPath)){throw 'Baseline requires -InstallerPath so lifecycle evidence is bound to the exact repair/uninstall candidate.'}
    if(-not(Test-Path -LiteralPath $InstallerPath -PathType Leaf)){throw "Installer not found: $InstallerPath"}
    $installer=Get-Item -LiteralPath $InstallerPath
    if($installer.Length -lt 1MB){throw 'Installer is unexpectedly small.'}
    $installerHash=File-Hash $installer.FullName
    $snap=Snapshot
    $errors=New-Object System.Collections.Generic.List[string]
    if(-not $snap.CoreExists){$errors.Add('OMNIX.Core.dll is not installed.')}
    if(-not $snap.SettingsExists){$errors.Add('settings.dat does not exist; save OMNIX settings before baseline.')}
    foreach($e in @(Registration-Errors $snap.Registrations)){$errors.Add([string]$e)}
    $pass=($errors.Count -eq 0)
    $state=[ordered]@{TestId='LIFECYCLE-REAL-002';EvidenceSchema=2;InstallerFileName=$installer.Name;InstallerSha256=$installerHash;BaselinePass=$pass;Baseline=$snap;Repair=$null;Uninstall=$null}
    $state|ConvertTo-Json -Depth 11|Set-Content -LiteralPath $StatePath -Encoding UTF8
    $report=[ordered]@{TestId='LIFECYCLE-REAL-002';EvidenceSchema=2;Phase='Baseline';InstallerSha256=$installerHash;FailureCount=$errors.Count;Failures=@($errors);BaselinePass=$pass;RepairPass=$false;UninstallPass=$false;OverallPass=$false;NextAction='Run this exact authorized installer normally, then run -Phase AfterRepair.'}
    $report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $OutputPath -Encoding UTF8;$report|ConvertTo-Json -Depth 8
    if(-not $pass){exit 1};exit 0
}

if(-not(Test-Path -LiteralPath $StatePath -PathType Leaf)){throw 'Lifecycle baseline state not found. Run Baseline first.'}
$state=Get-Content -LiteralPath $StatePath -Raw|ConvertFrom-Json
if($state.TestId -ne 'LIFECYCLE-REAL-002' -or -not[bool]$state.BaselinePass){throw 'Lifecycle baseline is invalid or did not pass.'}
$baseline=$state.Baseline
$current=Snapshot
$errors=New-Object System.Collections.Generic.List[string]

if($Phase -eq 'AfterRepair'){
    if(-not$current.CoreExists){$errors.Add('OMNIX.Core.dll missing after repair.')}
    if([string]$current.CoreSha256 -ne [string]$baseline.CoreSha256){$errors.Add('Installed OMNIX.Core.dll changed during same-build repair; exact-build repair is not proven.')}
    if(-not$current.SettingsExists -or [string]$current.SettingsSha256 -ne [string]$baseline.SettingsSha256){$errors.Add('settings.dat was not preserved exactly across repair.')}
    foreach($e in @(Compare-Recovery $baseline.SharedRecoveryState $current.SharedRecoveryState)){$errors.Add([string]$e)}
    foreach($e in @(Registration-Errors $current.Registrations)){$errors.Add([string]$e)}
    $baselineThumb=[string]$baseline.DevelopmentCertThumbprint
    if(-not[string]::IsNullOrWhiteSpace($baselineThumb)){
        if([string]$current.DevelopmentCertThumbprint -ne $baselineThumb){$errors.Add('Development certificate thumbprint changed during same-build repair.')}
        if(-not(Cert-Present 'TrustedPublisher' $baselineThumb) -or -not(Cert-Present 'Root' $baselineThumb)){$errors.Add('Expected development trust certificate is not present after repair.')}
    }
    $pass=($errors.Count -eq 0)
    $state.Repair=[ordered]@{Pass=$pass;SettingsPreserved=($current.SettingsSha256 -eq $baseline.SettingsSha256);CorePreserved=($current.CoreSha256 -eq $baseline.CoreSha256);SharedRecoveryStatePreserved=(@(Compare-Recovery $baseline.SharedRecoveryState $current.SharedRecoveryState).Count -eq 0);RegistrationHealthy=(@(Registration-Errors $current.Registrations).Count -eq 0)}
    $state|ConvertTo-Json -Depth 11|Set-Content -LiteralPath $StatePath -Encoding UTF8
    $report=[ordered]@{TestId='LIFECYCLE-REAL-002';EvidenceSchema=2;Phase='AfterRepair';InstallerSha256=[string]$state.InstallerSha256;FailureCount=$errors.Count;Failures=@($errors);BaselinePass=$true;RepairPass=$pass;UninstallPass=$false;OverallPass=$false;NextAction='Uninstall OMNIX normally and choose NO when asked to delete settings/history, then run -Phase AfterUninstall.'}
    $report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $OutputPath -Encoding UTF8;$report|ConvertTo-Json -Depth 8
    if(-not$pass){exit 1};exit 0
}

if($null -eq $state.Repair -or -not[bool]$state.Repair.Pass){$errors.Add('Passing AfterRepair evidence is required before AfterUninstall.')}
if($current.InstallDirExists -or $current.CoreExists){$errors.Add('OMNIX application payload remains after uninstall.')}
if(-not$current.SettingsExists -or [string]$current.SettingsSha256 -ne [string]$baseline.SettingsSha256){$errors.Add('settings.dat was not preserved after user chose to keep data.')}
if(@($current.Registrations).Count -ne 0){$errors.Add('OMNIX Office registration remains after uninstall.')}
foreach($e in @(Compare-Recovery $baseline.SharedRecoveryState $current.SharedRecoveryState)){$errors.Add([string]$e)}
$thumb=[string]$baseline.DevelopmentCertThumbprint
$certRemoved=$true
if(-not[string]::IsNullOrWhiteSpace($thumb)){
    if(Cert-Present 'TrustedPublisher' $thumb){$errors.Add('OMNIX development certificate remains in TrustedPublisher.');$certRemoved=$false}
    if(Cert-Present 'Root' $thumb){$errors.Add('OMNIX development certificate remains in Root.');$certRemoved=$false}
}
$pass=($errors.Count -eq 0)
$state.Uninstall=[ordered]@{Pass=$pass;SettingsPreserved=($current.SettingsExists -and $current.SettingsSha256 -eq $baseline.SettingsSha256);RegistrationRemoved=(@($current.Registrations).Count -eq 0);PayloadRemoved=(-not$current.InstallDirExists -and -not$current.CoreExists);SharedRecoveryStatePreserved=(@(Compare-Recovery $baseline.SharedRecoveryState $current.SharedRecoveryState).Count -eq 0);DevelopmentCertificateRemoved=$certRemoved}
$state|ConvertTo-Json -Depth 11|Set-Content -LiteralPath $StatePath -Encoding UTF8
$report=[ordered]@{
    TestId='LIFECYCLE-REAL-002';EvidenceSchema=2;Phase='AfterUninstall';TimestampUtc=(Get-Date).ToUniversalTime().ToString('o');InstallerSha256=[string]$state.InstallerSha256
    FailureCount=$errors.Count;Failures=@($errors);BaselinePass=[bool]$state.BaselinePass;RepairPass=[bool]$state.Repair.Pass
    SettingsPreservedAcrossRepair=[bool]$state.Repair.SettingsPreserved;CorePreservedAcrossRepair=[bool]$state.Repair.CorePreserved;SharedOfficeRecoveryStatePreservedAcrossRepair=[bool]$state.Repair.SharedRecoveryStatePreserved;RegistrationHealthyAfterRepair=[bool]$state.Repair.RegistrationHealthy
    UninstallPass=$pass;SettingsPreservedAcrossUninstall=[bool]$state.Uninstall.SettingsPreserved;OmnixRegistrationRemoved=[bool]$state.Uninstall.RegistrationRemoved;AppPayloadRemoved=[bool]$state.Uninstall.PayloadRemoved;SharedOfficeRecoveryStatePreservedAcrossUninstall=[bool]$state.Uninstall.SharedRecoveryStatePreserved;DevelopmentCertificateRemoved=[bool]$state.Uninstall.DevelopmentCertificateRemoved
    OverallPass=[bool]([bool]$state.BaselinePass -and [bool]$state.Repair.Pass -and $pass)
    Privacy='Hash-only evidence. No settings/API-key contents or raw Office recovery values are copied to the report.'
    Safety='Read-only registry/certificate snapshots. User performs supported installer/uninstaller actions explicitly.'
}
$report|ConvertTo-Json -Depth 9|Set-Content -LiteralPath $OutputPath -Encoding UTF8;$report|ConvertTo-Json -Depth 9
if(-not$report.OverallPass){exit 1};exit 0
