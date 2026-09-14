# Deterministic behavior acceptance for final-production-evidence-binding-guard.ps1.
# Uses only synthetic JSON + a temporary installer file. It does not require Office or networking.

[CmdletBinding()]
param([string]$OutputPath = ".\build\artifact\final-evidence-binding-guard-acceptance.json")
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$guard = Join-Path $scriptDir 'final-production-evidence-binding-guard.ps1'
if (-not (Test-Path -LiteralPath $guard -PathType Leaf)) { throw "Binding guard missing: $guard" }
$temp = Join-Path ([IO.Path]::GetTempPath()) ('omnix-binding-guard-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null

try {
    $installer = Join-Path $temp 'candidate.exe'
    [IO.File]::WriteAllBytes([string]$installer,[byte[]](New-Object byte[] 4096))
    $installerHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $installer).Hash.ToLowerInvariant()
    $source = ('a' * 40); $core = ('b' * 64); $identity = ('f' * 64)
    $paths = [ordered]@{
        Office=(Join-Path $temp 'office.json');Lifecycle=(Join-Path $temp 'lifecycle.json');Security=(Join-Path $temp 'security.json')
        Persistence=(Join-Path $temp 'persistence.json');Ui=(Join-Path $temp 'ui.json');Restart=(Join-Path $temp 'restart.json')
        Offline=(Join-Path $temp 'offline.json');Provider=(Join-Path $temp 'provider.json')
    }
    function Binding([string]$s=$source,[string]$c=$core,[string]$i=$identity) {
        return [ordered]@{BindingSchema=2;SourceCommit=$s;CoreSha256=$c;PayloadIdentitySha256=$i;BuildIdentityTestId='OMNIX-BUILD-IDENTITY-001';PrimaryAssembliesValidated=$true;CoreFileName='OMNIX.Core.dll'}
    }
    function Write-ValidReports {
        $now=[DateTime]::UtcNow.ToString('o')
        [ordered]@{TestId='OFFICE-E2E-REAL-001';EvidenceSchema=5;TimestampUtc=$now;OverallPass=$true;Installer=[ordered]@{Sha256=$installerHash;HashMatchedExpected=$true};EvidenceBinding=(Binding)}|ConvertTo-Json -Depth 8|Set-Content $paths.Office -Encoding UTF8
        foreach($name in @('Persistence','Ui','Restart','Offline','Provider')){[ordered]@{TestId=('SYNTHETIC-'+$name);TimestampUtc=$now;OverallPass=$true;EvidenceBinding=(Binding)}|ConvertTo-Json -Depth 8|Set-Content $paths[$name] -Encoding UTF8}
        [ordered]@{TestId='LIFECYCLE-REAL-002';EvidenceSchema=4;TimestampUtc=$now;InstallerSha256=$installerHash;OverallPass=$true;PayloadIdentityPreservedAcrossRepair=$true;PrimaryAssembliesValidatedBeforeAndAfterRepair=$true;EvidenceBinding=(Binding)}|ConvertTo-Json -Depth 8|Set-Content $paths.Lifecycle -Encoding UTF8
        [ordered]@{TestId='CONSUMER-SECURITY-REAL-001';TimestampUtc=$now;Installer=[ordered]@{Sha256=$installerHash};OverallPass=$true}|ConvertTo-Json -Depth 6|Set-Content $paths.Security -Encoding UTF8
    }
    function Invoke-Guard {
        try {
            & $guard -InstallerPath $installer -OfficeE2EReport $paths.Office -LifecycleReport $paths.Lifecycle -ConsumerSecurityReport $paths.Security -OfficePersistenceReport $paths.Persistence -OfficeUiReport $paths.Ui -OfficeRestartReport $paths.Restart -LocalOfflineReport $paths.Offline -ProviderReport $paths.Provider -ExpectedSourceCommit $source | Out-Null
            return [pscustomobject]@{Accepted=$true;Error=$null}
        } catch { return [pscustomobject]@{Accepted=$false;Error=[string]$_.Exception.Message} }
    }
    $script:CaseResults=@();$script:CaseFailures=@()
    function Run-Case([string]$name,[scriptblock]$mutate,[bool]$shouldPass){
        Write-ValidReports;& $mutate;$r=Invoke-Guard;$pass=([bool]$r.Accepted -eq $shouldPass)
        $script:CaseResults += [pscustomobject]@{Name=$name;ExpectedPass=$shouldPass;Accepted=[bool]$r.Accepted;Error=$r.Error;Pass=$pass}
        if(-not $pass){$script:CaseFailures += "$name expected pass=$shouldPass accepted=$($r.Accepted) error=$($r.Error)"}
    }
    Run-Case 'ValidExactBinding' {} $true
    Run-Case 'MissingProviderBinding' {$r=Get-Content $paths.Provider -Raw|ConvertFrom-Json;$r.PSObject.Properties.Remove('EvidenceBinding');$r|ConvertTo-Json -Depth 8|Set-Content $paths.Provider -Encoding UTF8} $false
    Run-Case 'WrongProviderCore' {$r=Get-Content $paths.Provider -Raw|ConvertFrom-Json;$r.EvidenceBinding.CoreSha256=('c'*64);$r|ConvertTo-Json -Depth 8|Set-Content $paths.Provider -Encoding UTF8} $false
    Run-Case 'WrongProviderIdentity' {$r=Get-Content $paths.Provider -Raw|ConvertFrom-Json;$r.EvidenceBinding.PayloadIdentitySha256=('1'*64);$r|ConvertTo-Json -Depth 8|Set-Content $paths.Provider -Encoding UTF8} $false
    Run-Case 'OldBindingSchema' {$r=Get-Content $paths.Provider -Raw|ConvertFrom-Json;$r.EvidenceBinding.BindingSchema=1;$r|ConvertTo-Json -Depth 8|Set-Content $paths.Provider -Encoding UTF8} $false
    Run-Case 'WrongRestartSource' {$r=Get-Content $paths.Restart -Raw|ConvertFrom-Json;$r.EvidenceBinding.SourceCommit=('d'*40);$r|ConvertTo-Json -Depth 8|Set-Content $paths.Restart -Encoding UTF8} $false
    Run-Case 'MissingLifecycleBinding' {$r=Get-Content $paths.Lifecycle -Raw|ConvertFrom-Json;$r.PSObject.Properties.Remove('EvidenceBinding');$r|ConvertTo-Json -Depth 8|Set-Content $paths.Lifecycle -Encoding UTF8} $false
    Run-Case 'WrongLifecycleIdentity' {$r=Get-Content $paths.Lifecycle -Raw|ConvertFrom-Json;$r.EvidenceBinding.PayloadIdentitySha256=('2'*64);$r|ConvertTo-Json -Depth 8|Set-Content $paths.Lifecycle -Encoding UTF8} $false
    Run-Case 'LifecycleIdentityNotPreserved' {$r=Get-Content $paths.Lifecycle -Raw|ConvertFrom-Json;$r.PayloadIdentityPreservedAcrossRepair=$false;$r|ConvertTo-Json -Depth 8|Set-Content $paths.Lifecycle -Encoding UTF8} $false
    Run-Case 'OldLifecycleSchema' {$r=Get-Content $paths.Lifecycle -Raw|ConvertFrom-Json;$r.EvidenceSchema=3;$r|ConvertTo-Json -Depth 8|Set-Content $paths.Lifecycle -Encoding UTF8} $false
    Run-Case 'StaleProvider' {$r=Get-Content $paths.Provider -Raw|ConvertFrom-Json;$r.TimestampUtc=[DateTime]::UtcNow.AddHours(-80).ToString('o');$r|ConvertTo-Json -Depth 8|Set-Content $paths.Provider -Encoding UTF8} $false
    Run-Case 'FutureOfficeUi' {$r=Get-Content $paths.Ui -Raw|ConvertFrom-Json;$r.TimestampUtc=[DateTime]::UtcNow.AddHours(1).ToString('o');$r|ConvertTo-Json -Depth 8|Set-Content $paths.Ui -Encoding UTF8} $false
    Run-Case 'StaleLifecycle' {$r=Get-Content $paths.Lifecycle -Raw|ConvertFrom-Json;$r.TimestampUtc=[DateTime]::UtcNow.AddHours(-180).ToString('o');$r|ConvertTo-Json -Depth 8|Set-Content $paths.Lifecycle -Encoding UTF8} $false
    Run-Case 'WrongOfficeInstaller' {$r=Get-Content $paths.Office -Raw|ConvertFrom-Json;$r.Installer.Sha256=('e'*64);$r|ConvertTo-Json -Depth 8|Set-Content $paths.Office -Encoding UTF8} $false

    Write-ValidReports
    $sentinel=Join-Path $temp 'caller-continued.txt';$caller=Join-Path $temp 'caller.ps1'
    $callerText="`$ErrorActionPreference='Stop'`n& '$guard' -InstallerPath '$installer' -OfficeE2EReport '$($paths.Office)' -LifecycleReport '$($paths.Lifecycle)' -ConsumerSecurityReport '$($paths.Security)' -OfficePersistenceReport '$($paths.Persistence)' -OfficeUiReport '$($paths.Ui)' -OfficeRestartReport '$($paths.Restart)' -LocalOfflineReport '$($paths.Offline)' -ProviderReport '$($paths.Provider)' -ExpectedSourceCommit '$source'`nSet-Content -LiteralPath '$sentinel' -Value 'CONTINUED' -NoNewline"
    Set-Content -LiteralPath $caller -Value $callerText -Encoding UTF8
    $cp=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-File',$caller) -Wait -PassThru -WindowStyle Hidden
    $continued=($cp.ExitCode -eq 0 -and (Test-Path $sentinel) -and (Get-Content $sentinel -Raw) -eq 'CONTINUED')
    $script:CaseResults += [pscustomobject]@{Name='CallerContinuation';ExpectedPass=$true;Accepted=$continued;Error=$null;Pass=$continued}
    if(-not $continued){$script:CaseFailures += 'Valid guard did not return control to its caller.'}
    $out=[ordered]@{TestId='FINAL-EVIDENCE-BINDING-GUARD-RUNTIME-001';EvidenceSchema=3;GeneratedUtc=[DateTime]::UtcNow.ToString('o');CaseCount=$script:CaseResults.Count;CallerContinuationProven=$continued;FailureCount=$script:CaseFailures.Count;Failures=$script:CaseFailures;Results=$script:CaseResults;OverallPass=($script:CaseFailures.Count -eq 0)}
    $outDir=Split-Path -Parent $OutputPath;if($outDir){New-Item -ItemType Directory -Force $outDir|Out-Null};$out|ConvertTo-Json -Depth 8|Set-Content $OutputPath -Encoding UTF8;$out|ConvertTo-Json -Depth 8
    if(-not $out.OverallPass){exit 1};exit 0
} finally { if(Test-Path $temp){Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue} }
