# Windows PowerShell 5.1 compatibility gate for production evidence scripts.
# These scripts run on consumer Office machines where powershell.exe is the compatibility baseline.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$relativeFiles = @(
    'tools\real-evidence-binding.ps1',
    'tools\bound-real-acceptance.ps1',
    'tools\payload-identity-binding-acceptance.ps1',
    'tools\lifecycle-acceptance.ps1',
    'tools\lifecycle-core-acceptance.ps1',
    'tools\final-production-evidence-binding-guard.ps1',
    'tools\final-evidence-binding-guard-acceptance.ps1',
    'tools\final-production-gate.ps1',
    'build\post-install-verify.ps1'
)

$failures = @()
foreach ($relative in $relativeFiles) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failures += "Missing: $relative"
        continue
    }

    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    foreach ($parseError in @($errors)) {
        $failures += "$relative parser error: $($parseError.Message)"
    }

    # GitHub content writes are UTF-8 without a BOM. Windows PowerShell 5.1 can misdecode non-ASCII
    # punctuation in such scripts as the active ANSI code page. Keep this production gate ASCII-only.
    $bytes = [IO.File]::ReadAllBytes($path)
    $nonAscii = @($bytes | Where-Object { $_ -gt 127 })
    if ($nonAscii.Count -gt 0) {
        $failures += "$relative contains $($nonAscii.Count) non-ASCII byte(s); production evidence scripts must remain ASCII-safe for Windows PowerShell 5.1."
    }
}

if ($failures.Count -gt 0) {
    Write-Host 'WINDOWS-POWERSHELL-EVIDENCE-CONTRACT-001: FAIL' -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host " - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host 'WINDOWS-POWERSHELL-EVIDENCE-CONTRACT-001: PASS'
Write-Host 'Critical production evidence scripts parse under Windows PowerShell and are ASCII-safe.'
exit 0
