# Deterministic acceptance for installed payload identity verification.
# Runs without Office/network. Creates a synthetic installed payload and proves tampering is rejected.

[CmdletBinding()]
param([string]$OutputPath = ".\build\artifact\payload-identity-binding-acceptance.json")
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$scriptDir=Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'real-evidence-binding.ps1')
$temp=Join-Path ([IO.Path]::GetTempPath()) ('omnix-payload-identity-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
try{
  $source=('a'*40)
  $files=@('OMNIX.Core.dll','OMNIX.Excel.dll','OMNIX.Word.dll','OMNIX.PowerPoint.dll')
  function Reset-Payload{
    foreach($name in $files){[IO.File]::WriteAllBytes((Join-Path $temp $name),[Text.Encoding]::UTF8.GetBytes('payload-'+$name))}
    $identity=[ordered]@{
      TestId='OMNIX-BUILD-IDENTITY-001';EvidenceSchema=1;SourceCommit=$source
      CoreSha256=(Get-FileHash (Join-Path $temp 'OMNIX.Core.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
      ExcelSha256=(Get-FileHash (Join-Path $temp 'OMNIX.Excel.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
      WordSha256=(Get-FileHash (Join-Path $temp 'OMNIX.Word.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
      PowerPointSha256=(Get-FileHash (Join-Path $temp 'OMNIX.PowerPoint.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
      Scope='synthetic acceptance'
    }
    $identity|ConvertTo-Json -Depth 5|Set-Content (Join-Path $temp 'OMNIX-build-identity.json') -Encoding ASCII
  }
  function Invoke-Binding([string]$expectedSource=$source){
    try{$b=New-OmnixEvidenceBinding -CorePath (Join-Path $temp 'OMNIX.Core.dll') -SourceCommit $expectedSource;return [pscustomobject]@{Accepted=$true;Binding=$b;Error=$null}}
    catch{return [pscustomobject]@{Accepted=$false;Binding=$null;Error=[string]$_.Exception.Message}}
  }
  $results=@();$failures=@()
  function Case([string]$name,[scriptblock]$mutate,[bool]$expected){Reset-Payload;& $mutate;$r=Invoke-Binding;$pass=([bool]$r.Accepted -eq $expected);$results += [pscustomobject]@{Name=$name;ExpectedPass=$expected;Accepted=$r.Accepted;Error=$r.Error;Pass=$pass};if(-not $pass){$failures += "$name unexpected result"};Set-Variable -Scope 1 -Name results -Value $results;Set-Variable -Scope 1 -Name failures -Value $failures}
  Case 'ValidInstalledPayload' {} $true
  Case 'TamperedCore' {[IO.File]::AppendAllText((Join-Path $temp 'OMNIX.Core.dll'),'tamper')} $false
  Case 'TamperedWordHost' {[IO.File]::AppendAllText((Join-Path $temp 'OMNIX.Word.dll'),'tamper')} $false
  Case 'MissingBuildIdentity' {Remove-Item (Join-Path $temp 'OMNIX-build-identity.json') -Force} $false
  Reset-Payload;$wrong=Invoke-Binding ('c'*40);$wrongPass=(-not $wrong.Accepted);$results += [pscustomobject]@{Name='WrongCheckoutSource';ExpectedPass=$false;Accepted=$wrong.Accepted;Error=$wrong.Error;Pass=$wrongPass};if(-not $wrongPass){$failures += 'WrongCheckoutSource unexpected result'}
  Reset-Payload;$valid=Invoke-Binding;$schemaPass=($valid.Accepted -and [int]$valid.Binding.BindingSchema -eq 2 -and [bool]$valid.Binding.PrimaryAssembliesValidated -and [string]$valid.Binding.PayloadIdentitySha256 -match '^[0-9a-f]{64}$');$results += [pscustomobject]@{Name='BindingCarriesIdentity';ExpectedPass=$true;Accepted=$schemaPass;Error=$valid.Error;Pass=$schemaPass};if(-not $schemaPass){$failures += 'BindingCarriesIdentity failed'}
  $out=[ordered]@{TestId='PAYLOAD-IDENTITY-BINDING-RUNTIME-001';EvidenceSchema=1;GeneratedUtc=[DateTime]::UtcNow.ToString('o');CaseCount=$results.Count;FailureCount=$failures.Count;Failures=$failures;Results=$results;OverallPass=($failures.Count -eq 0)}
  $dir=Split-Path -Parent $OutputPath;if($dir){New-Item -ItemType Directory -Force $dir|Out-Null};$out|ConvertTo-Json -Depth 8|Set-Content $OutputPath -Encoding UTF8;$out|ConvertTo-Json -Depth 8;if(-not $out.OverallPass){exit 1};exit 0
}finally{if(Test-Path $temp){Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue}}
