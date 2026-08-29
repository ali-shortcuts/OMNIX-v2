# ============================================================================
# ensure-vsto-sdk.ps1 — verifies the machine can build VSTO projects.
# If the VSTO targets are missing (e.g., a fresh CI runner without the Office
# development workload), the Visual Studio installer adds it silently.
# Run once before msbuild. Writes nothing when everything is present.
# ============================================================================
$ErrorActionPreference = "Continue"

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    Write-Error "vswhere.exe not found — is Visual Studio installed on this machine?"
    exit 1
}

$vsPath = & $vswhere -latest -requires Microsoft.VisualStudio.Workload.ManagedDesktop -property installationPath
if (-not $vsPath) { $vsPath = & $vswhere -latest -property installationPath }
Write-Host "Visual Studio at: $vsPath"

$patterns = @(
    "$vsPath\MSBuild\Microsoft\VisualStudio\v*\OfficeTools\Microsoft.VisualStudio.Tools.Office.targets",
    "$vsPath\MSBuild\Microsoft\VisualStudio\v*\VisualStudioToolsForOffice\Microsoft.VisualStudio.Tools.Office.targets"
)
$targets = Get-ChildItem $patterns -ErrorAction SilentlyContinue | Select-Object -First 1

if ($targets) {
    Write-Host "VSTO build targets present: $($targets.FullName)"
    exit 0
}

Write-Host "VSTO targets NOT found — installing the Office development tools (this can take several minutes)…"
$setup = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe"
$proc = Start-Process $setup -ArgumentList @(
    "modify", "--installPath", "`"$vsPath`"",
    "--add", "Microsoft.VisualStudio.Component.VSTOSDK",
    "--includeRecommended", "--quiet", "--norestart", "--nocache"
) -Wait -PassThru
Write-Host "VS installer exit code: $($proc.ExitCode)"

$targets = Get-ChildItem $patterns -ErrorAction SilentlyContinue | Select-Object -First 1
if ($targets) {
    Write-Host "VSTO targets installed OK: $($targets.FullName)"
    exit 0
}

Write-Error "VSTO targets are still missing after the workload install. Cannot build VSTO on this machine."
exit 1
