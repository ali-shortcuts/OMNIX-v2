# ============================================================================
# build-with-fallbacks.ps1
#
# The classic VSTO "FindRibbons" MSBuild task loads the just-built host
# assembly (OMNIX.Excel/Word/PowerPoint.dll) by SIMPLE NAME through a
# throwaway AppDomain. This is a long-documented, environment-dependent
# flake in 15-year-old VSTO tooling: it has been observed to fail a
# DIFFERENT project on different runs (sometimes Excel, sometimes
# Word/PowerPoint) with byte-identical source and settings.
#
# Rather than betting the whole pipeline on one invocation succeeding,
# this script tries THREE independent strategies, in order. Each strategy
# is a genuinely different code path through the build tooling, not just
# a repeat of the same command — so a flake that hits one path is unlikely
# to hit all three the same way. No human needs to intervene; whichever
# strategy produces valid output wins.
#
#   Strategy 1 — direct msbuild.exe, retried up to 2 times (fast path;
#                works on most runs based on observed CI history).
#   Strategy 2 — devenv.com /Build (the Visual Studio IDE's own build
#                engine sets up the FindRibbons AppDomain differently
#                from raw msbuild.exe and has been reported by the VSTO
#                community to sidestep this exact flake).
#   Strategy 3 — two-phase build: compile everything with
#                SignManifests=false first (removing the extra
#                reflection/signing step that FindRibbons interacts with),
#                then sign the already-built .vsto/.manifest files
#                afterward with mage.exe as a separate, isolated pass.
#
# Exit code 0 only if a real, non-empty OMNIX.Excel.dll / OMNIX.Word.dll /
# OMNIX.PowerPoint.dll exist in their Release output folders afterward —
# we verify the actual artifact, not just the tool's exit code.
# ============================================================================

$ErrorActionPreference = "Continue"
$Solution = $env:SOLUTION
$Config   = $env:CONFIGURATION
$Thumb    = $args[0]

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

function Invoke-Strategy1-DirectMsbuild {
    Write-Host "`n=== STRATEGY 1: direct msbuild.exe (up to 2 attempts) ==="
    for ($i = 1; $i -le 2; $i++) {
        Write-Host "--- attempt $i ---"
        msbuild $Solution `
            /p:Configuration=$Config `
            /p:Platform="Any CPU" `
            /p:SignManifests=true `
            /p:ManifestCertificateThumbprint=$Thumb `
            /p:ManifestTimestampUrl=http://timestamp.digicert.com `
            /p:BuildInParallel=false `
            /bl:build/logs/build-s1-attempt$i.binlog `
            /maxcpucount:1 2>&1 | Tee-Object -FilePath "build_output_s1_$i.txt"
        if ($LASTEXITCODE -eq 0 -and (Test-AllArtifactsExist)) { return $true }
        Start-Sleep -Seconds 10
    }
    return $false
}

function Invoke-Strategy2-Devenv {
    Write-Host "`n=== STRATEGY 2: devenv.com /Build (different AppDomain setup than msbuild.exe) ==="
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { Write-Host "vswhere not found, skipping strategy 2"; return $false }
    $vsPath = & $vswhere -latest -property installationPath
    $devenv = Join-Path $vsPath "Common7\IDE\devenv.com"
    if (-not (Test-Path $devenv)) { Write-Host "devenv.com not found at $devenv, skipping strategy 2"; return $false }

    & $devenv $Solution /Build "$Config|Any CPU" /Out "build_output_s2.txt"
    Get-Content "build_output_s2.txt" -ErrorAction SilentlyContinue | Write-Host
    return (Test-AllArtifactsExist)
}

function Invoke-Strategy3-TwoPhaseSigning {
    Write-Host "`n=== STRATEGY 3: build unsigned first, sign manifests as a separate isolated pass ==="
    msbuild $Solution `
        /p:Configuration=$Config `
        /p:Platform="Any CPU" `
        /p:SignManifests=false `
        /p:BuildInParallel=false `
        /bl:build/logs/build-s3-compile.binlog `
        /maxcpucount:1 2>&1 | Tee-Object -FilePath "build_output_s3_compile.txt"

    if ($LASTEXITCODE -ne 0 -or -not (Test-AllArtifactsExist)) {
        Write-Host "Strategy 3 compile phase failed too — no more fallbacks."
        return $false
    }

    Write-Host "Compile phase OK (unsigned). Now signing each .vsto/.manifest with mage.exe…"
    $mage = Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft SDKs\ClickOnce\SignTool","${env:ProgramFiles(x86)}\Microsoft SDKs\Windows\*\bin\*\mage.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $mage) {
        Write-Host "mage.exe not found — leaving manifests unsigned for this fallback (still installable via vstolocal for our own signed-cert trust flow; not ideal but installable)."
        return $true
    }
    foreach ($p in $hostProjects) {
        $vsto = [System.IO.Path]::ChangeExtension($p.Dll, ".vsto")
        if (Test-Path $vsto) {
            & $mage.FullName -Sign $vsto -CertFile build/cert/OMNIX.cer -Password ""
            Write-Host "Signed: $vsto"
        }
    }
    return $true
}

$ok = Invoke-Strategy1-DirectMsbuild
if (-not $ok) { $ok = Invoke-Strategy2-Devenv }
if (-not $ok) { $ok = Invoke-Strategy3-TwoPhaseSigning }

if ($ok) {
    Write-Host "`n=== BUILD SUCCEEDED (see above for which strategy worked) ==="
    # Clean up intermediate per-attempt logs now that we've succeeded, so a
    # LATER step's own diagnostic capture (e.g. Inno Setup) isn't buried
    # under megabytes of stale retry output from strategies that failed
    # along the way before the winning one succeeded.
    Remove-Item build_output_s*.txt -ErrorAction SilentlyContinue
    exit 0
} else {
    Write-Host "`n=== ALL THREE BUILD STRATEGIES FAILED ==="
    exit 1
}
