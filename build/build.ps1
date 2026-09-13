param([string]$Version='4.0.0-preview.1')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
Set-Location $root
New-Item -ItemType Directory -Force artifacts,artifacts\evidence,artifacts\payload,artifacts\prerequisites | Out-Null
$vswhere="${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs=& $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
if(-not $vs){throw 'Visual Studio with MSBuild is required.'}
$targets=Get-ChildItem "$vs\MSBuild\Microsoft\VisualStudio\v*\OfficeTools\Microsoft.VisualStudio.Tools.Office.targets" -ErrorAction SilentlyContinue | Select-Object -First 1
if(-not $targets){
    $setup="${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe"
    $process=Start-Process $setup -ArgumentList @('modify','--installPath',"`"$vs`"",'--add','Microsoft.VisualStudio.Component.VSTOSDK','--quiet','--norestart','--nocache') -Wait -PassThru
    if($process.ExitCode -notin @(0,3010)){throw "VSTO SDK installation failed: $($process.ExitCode)"}
    $targets=Get-ChildItem "$vs\MSBuild\Microsoft\VisualStudio\v*\OfficeTools\Microsoft.VisualStudio.Tools.Office.targets" | Select-Object -First 1
}
if(-not $targets){throw 'VSTO SDK targets are missing.'}
$vsto=Split-Path -Parent (Split-Path -Parent $targets.FullName)
$msbuild=Join-Path $vs 'MSBuild\Current\Bin\MSBuild.exe'

# The development key remains in the Windows user certificate store and is never exported.
$certificate=New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=OMNIX Development Preview' -CertStoreLocation Cert:\CurrentUser\My -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddMonths(6)
try {
    & $msbuild src\Omnix.Tests\Omnix.Tests.csproj /restore /t:Build /p:Configuration=Release /p:Platform=AnyCPU /m:1 /v:minimal /bl:artifacts/evidence/components.binlog
    if($LASTEXITCODE -ne 0){throw 'Component compilation failed.'}
    & .\src\Omnix.Tests\bin\Release\net48\Omnix.Tests.exe (Join-Path $root 'artifacts\evidence')
    if($LASTEXITCODE -ne 0){throw 'Windows runtime tests failed.'}
    foreach($hostName in @('Excel','Word','PowerPoint')){
        & $msbuild "src\Omnix.$hostName\Omnix.$hostName.csproj" /restore /t:Build /p:Configuration=Release /p:Platform=AnyCPU "/p:VSToolsPath=$vsto" /p:SignManifests=true "/p:ManifestCertificateThumbprint=$($certificate.Thumbprint)" /m:1 /v:minimal "/bl:artifacts/evidence/$hostName.binlog"
        if($LASTEXITCODE -ne 0){throw "$hostName compilation or manifest generation failed."}
        $destination="artifacts\payload\hosts\$hostName"
        New-Item -ItemType Directory -Force $destination | Out-Null
        Get-ChildItem "src\Omnix.$hostName\bin\Release" -File | Where-Object {$_.Extension -in @('.dll','.vsto','.manifest','.config')} | Copy-Item -Destination $destination
        foreach($file in @("Omnix.$hostName.dll","Omnix.$hostName.vsto","Omnix.$hostName.dll.manifest",'Omnix.Desktop.dll','Omnix.Contracts.dll','Microsoft.Office.Tools.Common.v4.0.Utilities.dll')){
            if(-not (Test-Path "$destination\$file")){throw "Incomplete $hostName payload: $file"}
        }
        $assembly=[Reflection.Assembly]::ReflectionOnlyLoadFrom((Resolve-Path "$destination\Omnix.$hostName.dll"))
        $externalOffice=@($assembly.GetReferencedAssemblies() | Where-Object {$_.Name -eq 'office' -or $_.Name -like 'Microsoft.Office.Interop.*'})
        if($externalOffice.Count -gt 0){throw "$hostName still depends on external Office PIAs."}
    }
    foreach($component in @('Gateway','Setup')){
        $destination='artifacts\payload\'+$component.ToLowerInvariant()
        New-Item -ItemType Directory -Force $destination | Out-Null
        Get-ChildItem "src\Omnix.$component\bin\Release\net48" -File | Where-Object {$_.Extension -in @('.dll','.exe','.config')} | Copy-Item -Destination $destination
    }
    & .\artifacts\payload\setup\Omnix.Setup.exe payload (Join-Path $root 'artifacts\payload')
    if($LASTEXITCODE -ne 0){throw 'Staged payload validation failed.'}
    $runtime='artifacts\prerequisites\vstor_redist.exe'
    Invoke-WebRequest 'https://download.microsoft.com/download/C/0/0/C001737F-822B-48C2-8F6A-CDE13B4B9E9C/vstor_redist.exe' -OutFile $runtime
    $signature=Get-AuthenticodeSignature $runtime
    if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation'){throw 'The VSTO redistributable must have a valid Microsoft signature.'}
    $inventory=Get-ChildItem artifacts\payload -Recurse -File | ForEach-Object {
        [ordered]@{Path=$_.FullName.Substring((Resolve-Path artifacts\payload).Path.Length+1);Bytes=$_.Length;Sha256=(Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
    $inventory | ConvertTo-Json -Depth 5 | Set-Content artifacts\evidence\payload-inventory.json
    $iscc='C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
    if(-not(Test-Path $iscc)){choco install innosetup -y --no-progress;if($LASTEXITCODE -ne 0){throw 'Inno Setup installation failed.'}}
    & $iscc "/DAppVersion=$Version" installer\OMNIX.iss
    if($LASTEXITCODE -ne 0){throw 'Installer compilation failed.'}
    $exe=Get-Item "artifacts\release\OMNIX-Setup-$Version.exe"
    $hash=(Get-FileHash $exe.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $($exe.Name)" | Set-Content "artifacts\release\SHA256SUMS.txt" -Encoding ascii
    $commit=(git rev-parse HEAD).Trim()
    [ordered]@{Version=$Version;SourceCommit=$commit;Installer=$exe.Name;Bytes=$exe.Length;Sha256=$hash;Status='DEVELOPMENT_PREVIEW';WindowsComponentTests=$true;RealOfficeRuntimeTested=$false;RebootTested=$false;TrustedProductionSignature=$false;ProductionReleaseApproved=$false} | ConvertTo-Json | Set-Content artifacts\release\manifest.json
    # An Office-less machine must reject installation before touching an existing install.
    if(@(Get-Process EXCEL,WINWORD,POWERPNT -ErrorAction SilentlyContinue).Count -eq 0){
        & .\artifacts\payload\setup\Omnix.Setup.exe probe
        if($LASTEXITCODE -eq 20){
            $sentinel=Join-Path $env:RUNNER_TEMP 'omnix-existing-install'
            New-Item -ItemType Directory -Force $sentinel | Out-Null
            Set-Content (Join-Path $sentinel 'keep.txt') 'existing user file'
            $process=Start-Process $exe.FullName -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"/DIR=`"$sentinel`"") -PassThru
            if(-not $process.WaitForExit(60000)){$process.Kill();throw 'Installer preflight timed out.'}
            if($process.ExitCode -eq 0){throw 'Installer incorrectly reported success without Office.'}
            if((Get-Content (Join-Path $sentinel 'keep.txt') -Raw).Trim() -ne 'existing user file'){throw 'Preflight modified existing files.'}
            [ordered]@{Case='NoOfficeInstall';ExitCode=$process.ExitCode;PreservedExistingFiles=$true} | ConvertTo-Json | Set-Content artifacts\evidence\installer-preflight.json
        }
    }
} finally {
    Remove-Item "Cert:\CurrentUser\My\$($certificate.Thumbprint)" -ErrorAction SilentlyContinue
}
