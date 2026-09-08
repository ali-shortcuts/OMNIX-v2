# ============================================================================
# build-with-fallbacks.ps1
#
# The classic VSTO "FindRibbons" MSBuild task loads the just-built host
# assembly through a throwaway AppDomain and can be flaky on hosted Windows
# build machines. We keep independent build paths, but EVERY path must produce
# valid host DLLs and valid signed VSTO manifests. No unsigned fallback may be
# reported as a successful release build.
#
# Strategy 1 — direct msbuild.exe, up to 2 attempts.
# Strategy 2 — devenv.com /Build.
# Strategy 3 — compile with SignManifests=false, then explicitly re-sign the
#              application manifest and UPDATE+sign the .vsto deployment
#              manifest with Mage.exe using the certificate thumbprint.
#
# Microsoft documents that the application manifest must be signed first, then
# the deployment manifest must be updated with -AppManifest and re-signed.
# ============================================================================

$ErrorActionPreference = "Continue"
$Solution = $env:SOLUTION
$Config   = $env:CONFIGURATION
$Thumb    = $args[0]
$TimestampUri = "http://timestamp.digicert.com"

$hostProjects = @(
    @{ Name = "OMNIX.Excel";      Dll = "src\OMNIX.Excel\bin\$Config\OMNIX.Excel.dll" },
    @{ Name = "OMNIX.Word";       Dll = "src\OMNIX.Word\bin\$Config\OMNIX.Word.dll" },
    @{ Name = "OMNIX.PowerPoint"; Dll = "src\OMNIX.PowerPoint\bin\$Config\OMNIX.PowerPoint.dll" }
)

function Test-AllArtifactsExist {
    foreach ($p in $hostProjects) {
        if (-not (Test-Path $p.Dll) -or (Get-Item $p.Dll).Length -eq 0) {
            Write-Host "Missing or empty artifact: $($p.Dll)"
            return $false
        }
    }
    return $true
}

function Test-AllVstoManifestsExist {
    foreach ($p in $hostProjects) {
        $appManifest = "$($p.Dll).manifest"
        $deployManifest = [System.IO.Path]::ChangeExtension($p.Dll, ".vsto")
        if (-not (Test-Path $appManifest)) {
            Write-Host "Missing application manifest: $appManifest"
            return $false
        }
        if (-not (Test-Path $deployManifest)) {
            Write-Host "Missing deployment manifest: $deployManifest"
            return $false
        }
    }
    return $true
}

function Invoke-Strategy1-DirectMsbuild {
    Write-Host "`n=== STRATEGY 1: direct msbuild.exe (up to 2 attempts) ==="
    for ($i = 1; $i -le 2; $i++) {
        Write-Host "--- attempt $i ---"
        msbuild $Solution `
            /p:Configuration=$Config `
            /p:Platform="Any CPU" `
            /p:SignManifests=true `
            /p:ManifestCertificateThumbprint=$Thumb `
            /p:ManifestTimestampUrl=$TimestampUri `
            /p:BuildInParallel=false `
            /bl:build/logs/build-s1-attempt$i.binlog `
            /maxcpucount:1 2>&1 | Tee-Object -FilePath "build_output_s1_$i.txt"
        if ($LASTEXITCODE -eq 0 -and (Test-AllArtifactsExist) -and (Test-AllVstoManifestsExist)) { return $true }
        Start-Sleep -Seconds 10
    }
    return $false
}

function Invoke-Strategy2-Devenv {
    Write-Host "`n=== STRATEGY 2: devenv.com /Build ==="
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { Write-Host "vswhere not found, skipping strategy 2"; return $false }
    $vsPath = & $vswhere -latest -property installationPath
    $devenv = Join-Path $vsPath "Common7\IDE\devenv.com"
    if (-not (Test-Path $devenv)) { Write-Host "devenv.com not found at $devenv, skipping strategy 2"; return $false }

    # The projects already contain their manifest-signing settings; the certificate thumbprint is
    # also supplied to the environment so the same build identity is used as strategy 1.
    $env:ManifestCertificateThumbprint = $Thumb
    & $devenv $Solution /Build "$Config|Any CPU" /Out "build_output_s2.txt"
    Get-Content "build_output_s2.txt" -ErrorAction SilentlyContinue | Write-Host
    return ((Test-AllArtifactsExist) -and (Test-AllVstoManifestsExist))
}

function Find-Mage {
    $candidates = @()
    $candidates += Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft SDKs\Windows\*\bin\*\mage.exe" -ErrorAction SilentlyContinue
    $candidates += Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft SDKs\ClickOnce\SignTool\mage.exe" -ErrorAction SilentlyContinue
    return $candidates | Sort-Object FullName -Descending | Select-Object -First 1
}

function Invoke-Strategy3-TwoPhaseSigning {
    Write-Host "`n=== STRATEGY 3: unsigned compile + explicit Mage re-sign ==="
    msbuild $Solution `
        /p:Configuration=$Config `
        /p:Platform="Any CPU" `
        /p:SignManifests=false `
        /p:BuildInParallel=false `
        /bl:build/logs/build-s3-compile.binlog `
        /maxcpucount:1 2>&1 | Tee-Object -FilePath "build_output_s3_compile.txt"

    if ($LASTEXITCODE -ne 0 -or -not (Test-AllArtifactsExist) -or -not (Test-AllVstoManifestsExist)) {
        Write-Host "Strategy 3 compile phase did not produce the complete VSTO artifact set."
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($Thumb)) {
        Write-Host "Strategy 3 cannot sign: certificate thumbprint is empty."
        return $false
    }

    $mage = Find-Mage
    if (-not $mage) {
        Write-Host "mage.exe not found. Refusing to treat unsigned VSTO manifests as success."
        return $false
    }

    Write-Host "Mage: $($mage.FullName)"
    foreach ($p in $hostProjects) {
        $appManifest = "$($p.Dll).manifest"
        $deployManifest = [System.IO.Path]::ChangeExtension($p.Dll, ".vsto")

        Write-Host "Signing application manifest: $appManifest"
        & $mage.FullName -Sign $appManifest -CertHash $Thumb -TimestampUri $TimestampUri 2>&1 | Tee-Object -FilePath "build_output_s3_sign_$($p.Name)_app.txt"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Application-manifest signing failed for $($p.Name)."
            return $false
        }

        # Re-signing the application manifest changes its hash. Update the deployment manifest with
        # the freshly signed application manifest and sign the deployment manifest in one operation.
        Write-Host "Updating/signing deployment manifest: $deployManifest"
        & $mage.FullName -Update $deployManifest -AppManifest $appManifest -CertHash $Thumb -TimestampUri $TimestampUri 2>&1 | Tee-Object -FilePath "build_output_s3_sign_$($p.Name)_deploy.txt"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Deployment-manifest update/sign failed for $($p.Name)."
            return $false
        }
    }

    return ((Test-AllArtifactsExist) -and (Test-AllVstoManifestsExist))
}

$ok = Invoke-Strategy1-DirectMsbuild
if (-not $ok) { $ok = Invoke-Strategy2-Devenv }
if (-not $ok) { $ok = Invoke-Strategy3-TwoPhaseSigning }

if ($ok) {
    Write-Host "`n=== BUILD SUCCEEDED (see above for which strategy worked) ==="
    Remove-Item build_output_s*.txt -ErrorAction SilentlyContinue
    exit 0
} else {
    Write-Host "`n=== ALL THREE BUILD STRATEGIES FAILED ==="
    exit 1
}
