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
# IMPORTANT POWERSHELL INVARIANT:
# A function returns every object written to its success pipeline. Native build
# output piped through Tee-Object must therefore continue to Out-Host; otherwise
# the log lines become part of the function return value, turning a final $false
# into a non-empty (truthy) array. That exact bug previously produced a false
# "BUILD SUCCEEDED" even though OMNIX.Excel.dll was missing.
#
# Critical packaging boundary:
# Once a strategy succeeds, the complete validated Release output of every
# Office host is copied immediately into build/compiled-payload/<host>. The
# packaging step consumes this validated handoff.
# ============================================================================

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$Solution = $env:SOLUTION
$Config   = $env:CONFIGURATION
$Thumb    = $args[0]
$TimestampUri = 'http://timestamp.digicert.com'
$handoffRoot = Join-Path $PSScriptRoot 'compiled-payload'

$hostProjects = @(
    @{ Name = 'OMNIX.Excel';      Dll = "src\OMNIX.Excel\bin\$Config\OMNIX.Excel.dll" },
    @{ Name = 'OMNIX.Word';       Dll = "src\OMNIX.Word\bin\$Config\OMNIX.Word.dll" },
    @{ Name = 'OMNIX.PowerPoint'; Dll = "src\OMNIX.PowerPoint\bin\$Config\OMNIX.PowerPoint.dll" }
)

function Test-AllArtifactsExist {
    foreach ($p in $hostProjects) {
        if (-not (Test-Path -LiteralPath $p.Dll -PathType Leaf)) {
            Write-Host "Missing artifact: $($p.Dll)"
            return $false
        }
        if ((Get-Item -LiteralPath $p.Dll).Length -eq 0) {
            Write-Host "Empty artifact: $($p.Dll)"
            return $false
        }
    }
    return $true
}

function Test-AllVstoManifestsExist {
    foreach ($p in $hostProjects) {
        $appManifest = "$($p.Dll).manifest"
        $deployManifest = [System.IO.Path]::ChangeExtension($p.Dll, '.vsto')
        if (-not (Test-Path -LiteralPath $appManifest -PathType Leaf)) {
            Write-Host "Missing application manifest: $appManifest"
            return $false
        }
        if (-not (Test-Path -LiteralPath $deployManifest -PathType Leaf)) {
            Write-Host "Missing deployment manifest: $deployManifest"
            return $false
        }
        if ((Get-Item -LiteralPath $appManifest).Length -le 0 -or
            (Get-Item -LiteralPath $deployManifest).Length -le 0) {
            Write-Host "Empty VSTO manifest detected for $($p.Name)."
            return $false
        }
    }
    return $true
}

function Test-CompleteArtifactSet {
    $dllsOk = Test-AllArtifactsExist
    if (-not $dllsOk) { return $false }
    $manifestsOk = Test-AllVstoManifestsExist
    return [bool]$manifestsOk
}

function Show-ValidatedArtifacts {
    Write-Host '--- Validated VSTO build outputs ---'
    foreach ($p in $hostProjects) {
        foreach ($path in @(
            $p.Dll,
            "$($p.Dll).manifest",
            [System.IO.Path]::ChangeExtension($p.Dll, '.vsto')
        )) {
            $item = Get-Item -LiteralPath $path -ErrorAction Stop
            Write-Host ("  {0} | {1} bytes | {2}" -f $p.Name, $item.Length, $item.FullName)
        }
    }
}

function Stage-ValidatedArtifacts {
    if (-not (Test-CompleteArtifactSet)) {
        throw 'Cannot create compiled-payload handoff: the validated VSTO artifact set is incomplete.'
    }

    if (Test-Path -LiteralPath $handoffRoot) {
        Remove-Item -LiteralPath $handoffRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $handoffRoot | Out-Null

    $allowedExtensions = @('.dll', '.vsto', '.manifest', '.config')
    foreach ($p in $hostProjects) {
        $sourceDir = Split-Path -Parent $p.Dll
        $destDir = Join-Path $handoffRoot $p.Name
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null

        $files = @(Get-ChildItem -LiteralPath $sourceDir -File -ErrorAction Stop | Where-Object {
            $allowedExtensions -contains $_.Extension
        })
        if ($files.Count -eq 0) {
            throw "No runtime files found while staging validated output for $($p.Name)."
        }
        foreach ($file in $files) {
            Copy-Item -LiteralPath $file.FullName -Destination $destDir -Force
        }

        foreach ($requiredName in @(
            "$($p.Name).dll",
            "$($p.Name).dll.manifest",
            "$($p.Name).vsto"
        )) {
            $requiredPath = Join-Path $destDir $requiredName
            if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
                throw "COMPILED_HANDOFF_GUARD: $requiredName was not copied for $($p.Name)."
            }
        }

        Write-Host "Compiled handoff for $($p.Name): $($files.Count) files -> $destDir"
    }

    $coreMatches = @(Get-ChildItem -LiteralPath $handoffRoot -Recurse -File -Filter 'OMNIX.Core.dll' -ErrorAction Stop)
    if ($coreMatches.Count -lt 1) {
        throw 'COMPILED_HANDOFF_GUARD: OMNIX.Core.dll is absent from the validated build handoff.'
    }

    Write-Host 'OMNIX COMPILED HANDOFF: PASS'
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
            /maxcpucount:1 2>&1 |
            Tee-Object -FilePath "build_output_s1_$i.txt" |
            Out-Host
        $exitCode = $LASTEXITCODE
        $artifactsOk = Test-CompleteArtifactSet
        Write-Host "Strategy 1 attempt $i: msbuildExit=$exitCode completeArtifacts=$artifactsOk"
        if ($exitCode -eq 0 -and $artifactsOk) { return $true }
        Start-Sleep -Seconds 10
    }
    return $false
}

function Invoke-Strategy2-Devenv {
    Write-Host "`n=== STRATEGY 2: devenv.com /Build ==="
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { Write-Host 'vswhere not found, skipping strategy 2'; return $false }
    $vsPath = & $vswhere -latest -property installationPath
    $devenv = Join-Path $vsPath 'Common7\IDE\devenv.com'
    if (-not (Test-Path $devenv)) { Write-Host "devenv.com not found at $devenv, skipping strategy 2"; return $false }

    & $devenv $Solution /Build "$Config|Any CPU" /Out 'build_output_s2.txt'
    $exitCode = $LASTEXITCODE
    Get-Content 'build_output_s2.txt' -ErrorAction SilentlyContinue | Out-Host
    $artifactsOk = Test-CompleteArtifactSet
    Write-Host "Strategy 2: devenvExit=$exitCode completeArtifacts=$artifactsOk"
    return [bool]($exitCode -eq 0 -and $artifactsOk)
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
        /maxcpucount:1 2>&1 |
        Tee-Object -FilePath 'build_output_s3_compile.txt' |
        Out-Host
    $compileExit = $LASTEXITCODE

    if ($compileExit -ne 0 -or -not (Test-CompleteArtifactSet)) {
        Write-Host "Strategy 3 compile phase incomplete (exit=$compileExit)."
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($Thumb)) {
        Write-Host 'Strategy 3 cannot sign: certificate thumbprint is empty.'
        return $false
    }

    $mage = Find-Mage
    if (-not $mage) {
        Write-Host 'mage.exe not found. Refusing to treat unsigned VSTO manifests as success.'
        return $false
    }

    Write-Host "Mage: $($mage.FullName)"
    foreach ($p in $hostProjects) {
        $appManifest = "$($p.Dll).manifest"
        $deployManifest = [System.IO.Path]::ChangeExtension($p.Dll, '.vsto')

        Write-Host "Signing application manifest: $appManifest"
        & $mage.FullName -Sign $appManifest -CertHash $Thumb -TimestampUri $TimestampUri 2>&1 |
            Tee-Object -FilePath "build_output_s3_sign_$($p.Name)_app.txt" |
            Out-Host
        $signAppExit = $LASTEXITCODE
        if ($signAppExit -ne 0) {
            Write-Host "Application-manifest signing failed for $($p.Name) (exit=$signAppExit)."
            return $false
        }

        Write-Host "Updating/signing deployment manifest: $deployManifest"
        & $mage.FullName -Update $deployManifest -AppManifest $appManifest -CertHash $Thumb -TimestampUri $TimestampUri 2>&1 |
            Tee-Object -FilePath "build_output_s3_sign_$($p.Name)_deploy.txt" |
            Out-Host
        $signDeployExit = $LASTEXITCODE
        if ($signDeployExit -ne 0) {
            Write-Host "Deployment-manifest update/sign failed for $($p.Name) (exit=$signDeployExit)."
            return $false
        }
    }

    return [bool](Test-CompleteArtifactSet)
}

# Assign only the explicit Boolean returned by each strategy. Build log text is routed to Out-Host
# above and can no longer contaminate these values.
[bool]$ok = Invoke-Strategy1-DirectMsbuild
if (-not $ok) { [bool]$ok = Invoke-Strategy2-Devenv }
if (-not $ok) { [bool]$ok = Invoke-Strategy3-TwoPhaseSigning }

if (-not $ok) {
    Write-Host "`n=== ALL THREE BUILD STRATEGIES FAILED TO PRODUCE A COMPLETE VSTO SET ==="
    exit 1
}

try {
    Write-Host "`n=== BUILD SUCCEEDED — validating and snapshotting outputs ==="
    Show-ValidatedArtifacts
    Stage-ValidatedArtifacts
    exit 0
}
catch {
    Write-Host "BUILD HANDOFF FAILED: $($_.Exception.Message)"
    exit 1
}
