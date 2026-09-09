# OMNIX image input/capture anti-drift contract. Structural only; compiled synthetic-image runtime
# acceptance is executed separately in request-budget-runtime CI.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]

function Read-Repo([string]$relative) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $failures.Add("Missing: $relative"); return '' }
    return Get-Content -LiteralPath $path -Raw
}
function Require([string]$relative,[string]$needle,[string]$reason) {
    $text = Read-Repo $relative
    if (-not $text.Contains($needle)) { $failures.Add("${relative}: missing '$needle' — $reason") }
}
function Parse-Ps([string]$relative) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $failures.Add("Missing: $relative"); return }
    $tokens=$null; $errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    foreach($e in @($errors)){ $failures.Add("${relative}: parser error — $($e.Message)") }
}

$util = 'src/OMNIX.Core/Util/Utils.cs'
Require $util 'ImageNormalizer' 'disk uploads must pass through one bounded image normalizer.'
Require $util 'MaxInputBytes = 20L * 1024L * 1024L' 'compressed input bytes need a hard cap.'
Require $util 'MaxOutputBytes = 20L * 1024L * 1024L' 'normalized PNG bytes need a hard cap.'
Require $util 'MaxPixels = 24L * 1024L * 1024L' 'decoded pixel count needs a hard cap.'
Require $util 'MaxDimension = 10000' 'single image dimension needs a hard cap.'
Require $util 'PngBitmapEncoder' 'accepted non-PNG source formats must be re-encoded to truthful PNG bytes.'
Require $util 'ValidatePngBytes' 'Office captures and normalized uploads must verify the PNG signature.'

$controller = 'src/OMNIX.Core/Ui/WorkspaceController.cs'
Require $controller 'ImageNormalizer.LoadFileAsPng(dlg.FileName)' 'disk uploads must be normalized before ImageAttachment creation.'
Require $controller 'ImageNormalizer.ValidatePngBytes(png' 'Office view captures must be validated before attachment.'
Require $controller 'GetFileNameWithoutExtension(dlg.FileName) + ".png"' 'normalized disk attachment filename must match its actual PNG encoding.'

Parse-Ps 'tools/image-normalization-acceptance.ps1'
Require 'tools/image-normalization-acceptance.ps1' 'IMAGE-NORMALIZATION-RUNTIME-001' 'compiled image normalization needs a stable TestId.'
Require 'tools/image-normalization-acceptance.ps1' 'JpegToPngPass' 'runtime test must prove JPEG input becomes PNG.'
Require 'tools/image-normalization-acceptance.ps1' 'BmpToPngPass' 'runtime test must prove BMP input becomes PNG.'
Require 'tools/image-normalization-acceptance.ps1' 'InvalidInputRejectedPass' 'invalid image content must fail closed.'
Require 'tools/image-normalization-acceptance.ps1' 'OversizedInputRejectedPass' 'oversized compressed images must fail closed.'
Require 'tools/image-normalization-acceptance.ps1' 'DimensionLimitRejectedPass' 'oversized decoded dimensions must fail closed.'
Require '.github/workflows/request-budget.yml' 'image-normalization-acceptance.ps1' 'runtime CI must execute image normalization acceptance.'
Require '.github/workflows/request-budget.yml' 'IMAGE-NORMALIZATION-RUNTIME-001' 'runtime CI must validate the image report TestId.'

if ($failures.Count -gt 0) {
    Write-Host 'OMNIX IMAGE-SAFETY CONTRACT: FAIL' -ForegroundColor Red
    foreach ($f in $failures) { Write-Host " - $f" -ForegroundColor Red }
    exit 1
}
Write-Host 'OMNIX IMAGE-SAFETY CONTRACT: PASS'
Write-Host 'Disk image formats are normalized to bounded PNG bytes and Office captures remain PNG-validated.'
exit 0
