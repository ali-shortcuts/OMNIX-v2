# ============================================================================
# build-with-fallbacks.ps1
#
# OMNIX uses Ribbon XML through Office.IRibbonExtensibility in all three Office
# hosts. It does NOT use VSTO Ribbon Designer / RibbonBase classes.
#
# The stock VSTO FindRibbons build task loads the just-built host assembly in an
# isolated AppDomain. On hosted build agents that probe can fail even after the
# host DLL compiled successfully, preventing VSTO manifests from being emitted.
# For OMNIX's XML-Ribbon architecture the RibbonBase type scan is unnecessary.
#
# Strategy 1 therefore creates a PER-BUILD COPY of the installed OfficeTools
# targets, removes only the paired <FindRibbons> task invocation from that copy,
# and builds against the copy with normal ClickOnce/VSTO manifest signing still
# enabled. The installed Visual Studio/MSBuild files are NEVER modified.
#
# Strategy 2 — direct signed MSBuild against the installed targets.
# Strategy 3 — Visual Studio/devenv signed build against the installed targets.
#
# There is deliberately NO SignManifests=false fallback: VSTO application-level
# projects require signed ClickOnce manifests, so an unsigned build cannot count
# as a valid packaging path.
#
# IMPORTANT POWERSHELL INVARIANT:
# A function returns every object written to its success pipeline. Native build
# output must therefore be consumed/routed to Out-Host; otherwise log text can
# contaminate a Boolean strategy result. Invoke-StrictBooleanStrategy fail-closes
# if a strategy emits anything except one Boolean value.
#
# Critical packaging boundary:
# Once a strategy succeeds, the complete validated Release output of every
# Office host is copied immediately into build/compiled-payload/<host>. The
# packaging step consumes only this validated handoff.
# ============================================================================

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$Solution = $env:SOLUTION
$Config   = $env:CONFIGURATION
$Thumb    = $args[0]
$TimestampUri = 'http://timestamp.digicert.com'
$handoffRoot = Join-Path $PSScriptRoot 'compiled-payload'
$overlayRoot = Join-Path $PSScriptRoot 'vsto-xml-ribbon-overlay'

$hostProjects = @(
    @{ Name = 'OMNIX.Excel';      Dll = "src\OMNIX.Excel\bin\$Config\OMNIX.Excel.dll" },
    @{ Name = 'OMNIX.Word';       Dll = "src\OMNIX.Word\bin\$Config\OMNIX.Word.dll" },
    @{ Name = 'OMNIX.PowerPoint'; Dll = "src\OMNIX.PowerPoint\bin\$Config\OMNIX.PowerPoint.dll" }
)

function Test-OmnixXmlRibbonArchitecture {
    foreach ($p in $hostProjects) {
        $hostDir = Join-Path 'src' $p.Name
        $thisAddIn = Join-Path $hostDir 'ThisAddIn.cs'
        $ribbon = Join-Path $hostDir 'OmnixRibbon.cs'
        $ribbonXml = Join-Path $hostDir 'OmnixRibbon.xml'

        foreach ($required in @($thisAddIn, $ribbon, $ribbonXml)) {
            if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
                Write-Host "XML Ribbon architecture check failed: missing $required"
                return $false
            }
        }

        $addInText = Get-Content -LiteralPath $thisAddIn -Raw
        $ribbonText = Get-Content -LiteralPath $ribbon -Raw
        if ($addInText -notmatch 'CreateRibbonExtensibilityObject\s*\(' -or
            $ribbonText -notmatch 'Office\.IRibbonExtensibility') {
            Write-Host "XML Ribbon architecture check failed for $($p.Name): IRibbonExtensibility path not found."
            return $false
        }

        if ($ribbonText -match '\bRibbonBase\b' -or $ribbonText -match '\bOfficeRibbon\b') {
            Write-Host "XML Ribbon overlay is not valid for $($p.Name): VSTO Ribbon Designer types were detected."
            return $false
        }
    }

    Write-Host 'OMNIX XML Ribbon architecture: verified for Excel, Word and PowerPoint.'
    return $true
}

function Resolve-InstalledOfficeToolsDirectory {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
        throw 'vswhere.exe was not found; cannot create the isolated VSTO OfficeTools overlay.'
    }

    $vsInstall = (& $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($vsInstall)) {
        throw 'Visual Studio/MSBuild installation path could not be resolved with vswhere.'
    }

    $visualStudioMsBuild = Join-Path $vsInstall 'MSBuild\Microsoft\VisualStudio'
    $targets = @(Get-ChildItem -LiteralPath $visualStudioMsBuild -Filter 'Microsoft.VisualStudio.Tools.Office.targets' -Recurse -File -ErrorAction Stop |
        Where-Object { $_.Directory.Name -eq 'OfficeTools' } |
        Sort-Object FullName -Descending)

    if ($targets.Count -lt 1) {
        throw "Microsoft.VisualStudio.Tools.Office.targets was not found under $visualStudioMsBuild."
    }

    return $targets[0].Directory.FullName
}

function New-XmlRibbonOfficeToolsOverlay {
    if (-not (Test-OmnixXmlRibbonArchitecture)) {
        throw 'Refusing to bypass FindRibbons because OMNIX is not exclusively using the verified IRibbonExtensibility XML-Ribbon path.'
    }

    $sourceOfficeTools = Resolve-InstalledOfficeToolsDirectory
    $overlayVSToolsPath = Join-Path $overlayRoot 'VSTools'
    $overlayOfficeTools = Join-Path $overlayVSToolsPath 'OfficeTools'

    if (Test-Path -LiteralPath $overlayRoot) {
        Remove-Item -LiteralPath $overlayRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $overlayOfficeTools -Force | Out-Null

    Copy-Item -Path (Join-Path $sourceOfficeTools '*') -Destination $overlayOfficeTools -Recurse -Force

    $overlayTargets = Join-Path $overlayOfficeTools 'Microsoft.VisualStudio.Tools.Office.targets'
    if (-not (Test-Path -LiteralPath $overlayTargets -PathType Leaf)) {
        throw 'VSTO overlay copy did not contain Microsoft.VisualStudio.Tools.Office.targets.'
    }

    $sourceText = Get-Content -LiteralPath $overlayTargets -Raw
    $findRibbonsPattern = '(?s)\s*<FindRibbons\b.*?</FindRibbons>'
    $matches = [regex]::Matches($sourceText, $findRibbonsPattern)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one paired FindRibbons task invocation in the copied Office targets; found $($matches.Count). Refusing an ambiguous patch."
    }

    $patchedText = [regex]::Replace($sourceText, $findRibbonsPattern, '', 1)

    # Preserve all manifest/signing machinery. We bypass only the RibbonBase discovery task.
    foreach ($requiredMarker in @(
        'VerifyClickOnceSigningSettings',
        'GenerateOfficeAddInManifest',
        'GenerateApplicationManifest',
        'GenerateDeploymentManifest',
        '<SignFile'
    )) {
        if ($patchedText -notlike "*$requiredMarker*") {
            throw "VSTO overlay integrity check failed: '$requiredMarker' disappeared from copied targets."
        }
    }
    if ([regex]::IsMatch($patchedText, $findRibbonsPattern)) {
        throw 'VSTO overlay integrity check failed: FindRibbons invocation is still present.'
    }

    # Only the copied file under build/ is written. Never write into Program Files/Visual Studio.
    Set-Content -LiteralPath $overlayTargets -Value $patchedText -Encoding UTF8

    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $sourceOfficeTools 'Microsoft.VisualStudio.Tools.Office.targets')).Hash.ToLowerInvariant()
    $overlayHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $overlayTargets).Hash.ToLowerInvariant()
    Write-Host 'Created isolated XML-Ribbon-safe VSTO OfficeTools overlay.'
    Write-Host "  Installed source (read-only): $sourceOfficeTools"
    Write-Host "  Per-build overlay:            $overlayOfficeTools"
    Write-Host "  Source targets SHA256:        $sourceHash"
    Write-Host "  Overlay targets SHA256:       $overlayHash"

    return (Resolve-Path -LiteralPath $overlayVSToolsPath).Path
}

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

function Invoke-StrictBooleanStrategy([string]$name, [scriptblock]$action) {
    $items = @(& $action)
    if ($items.Count -ne 1 -or $items[0] -isnot [bool]) {
        Write-Host "$name emitted unexpected success-pipeline output; treating the strategy as FAILED."
        Write-Host "Expected exactly one Boolean result; observed item count: $($items.Count)."
        return $false
    }
    return [bool]$items[0]
}

function Invoke-Strategy1-XmlRibbonOverlay {
    Write-Host "`n=== STRATEGY 1: signed MSBuild + isolated XML-Ribbon VSTO overlay ==="
    try {
        # Capture path only; all helper diagnostics are host output.
        $overlayPathItems = @(New-XmlRibbonOfficeToolsOverlay)
        if ($overlayPathItems.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$overlayPathItems[0])) {
            Write-Host 'XML Ribbon overlay did not return exactly one VSToolsPath.'
            return $false
        }
        $overlayVSToolsPath = [string]$overlayPathItems[0]
    }
    catch {
        Write-Host "XML Ribbon overlay creation failed: $($_.Exception.Message)"
        return $false
    }

    msbuild $Solution `
        /p:Configuration=$Config `
        /p:Platform="Any CPU" `
        /p:VSToolsPath="$overlayVSToolsPath" `
        /p:SignManifests=true `
        /p:ManifestCertificateThumbprint=$Thumb `
        /p:ManifestTimestampUrl=$TimestampUri `
        /p:BuildInParallel=false `
        /bl:build/logs/build-s1-xml-ribbon-overlay.binlog `
        /maxcpucount:1 2>&1 |
        Tee-Object -FilePath 'build_output_s1_xml_ribbon_overlay.txt' |
        Out-Host

    $exitCode = $LASTEXITCODE
    $artifactsOk = Test-CompleteArtifactSet
    Write-Host "Strategy 1: msbuildExit=$exitCode completeArtifacts=$artifactsOk"
    return [bool]($exitCode -eq 0 -and $artifactsOk)
}

function Invoke-Strategy2-DirectMsbuild {
    Write-Host "`n=== STRATEGY 2: direct signed msbuild.exe (up to 2 attempts) ==="
    for ($i = 1; $i -le 2; $i++) {
        Write-Host "--- attempt $i ---"
        msbuild $Solution `
            /p:Configuration=$Config `
            /p:Platform="Any CPU" `
            /p:SignManifests=true `
            /p:ManifestCertificateThumbprint=$Thumb `
            /p:ManifestTimestampUrl=$TimestampUri `
            /p:BuildInParallel=false `
            /bl:build/logs/build-s2-attempt$i.binlog `
            /maxcpucount:1 2>&1 |
            Tee-Object -FilePath "build_output_s2_$i.txt" |
            Out-Host
        $exitCode = $LASTEXITCODE
        $artifactsOk = Test-CompleteArtifactSet
        Write-Host "Strategy 2 attempt ${i}: msbuildExit=$exitCode completeArtifacts=$artifactsOk"
        if ($exitCode -eq 0 -and $artifactsOk) { return $true }
        Start-Sleep -Seconds 5
    }
    return $false
}

function Invoke-Strategy3-Devenv {
    Write-Host "`n=== STRATEGY 3: devenv.com /Build ==="
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { Write-Host 'vswhere not found, skipping strategy 3'; return $false }
    $vsPath = & $vswhere -latest -property installationPath
    $devenv = Join-Path $vsPath 'Common7\IDE\devenv.com'
    if (-not (Test-Path $devenv)) { Write-Host "devenv.com not found at $devenv, skipping strategy 3"; return $false }

    # Consume native stdout/stderr locally so it cannot become part of the function return value.
    $devenvOutput = @(& $devenv $Solution /Build "$Config|Any CPU" /Out 'build_output_s3.txt' 2>&1)
    $exitCode = $LASTEXITCODE
    if ($devenvOutput.Count -gt 0) { $devenvOutput | Out-Host }
    Get-Content 'build_output_s3.txt' -ErrorAction SilentlyContinue | Out-Host
    $artifactsOk = Test-CompleteArtifactSet
    Write-Host "Strategy 3: devenvExit=$exitCode completeArtifacts=$artifactsOk"
    return [bool]($exitCode -eq 0 -and $artifactsOk)
}

# Every strategy is wrapped so accidental pipeline output is a failure, never a success signal.
[bool]$ok = Invoke-StrictBooleanStrategy 'Strategy 1' { Invoke-Strategy1-XmlRibbonOverlay }
if (-not $ok) { [bool]$ok = Invoke-StrictBooleanStrategy 'Strategy 2' { Invoke-Strategy2-DirectMsbuild } }
if (-not $ok) { [bool]$ok = Invoke-StrictBooleanStrategy 'Strategy 3' { Invoke-Strategy3-Devenv } }

if (-not $ok) {
    Write-Host "`n=== ALL THREE BUILD STRATEGIES FAILED TO PRODUCE A COMPLETE SIGNED VSTO SET ==="
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
