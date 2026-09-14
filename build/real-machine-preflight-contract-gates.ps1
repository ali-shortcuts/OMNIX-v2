# Anti-drift contract for the interactive real-machine preflight and manual workflow.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$preflightPath = Join-Path $root 'tools\real-machine-preflight.ps1'
$workflowPath = Join-Path $root '.github\workflows\real-office-interactive.yml'

foreach ($path in @($preflightPath,$workflowPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "REAL_MACHINE_PREFLIGHT_CONTRACT: required file missing: $path"
    }
}

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($preflightPath,[ref]$tokens,[ref]$errors)
if (@($errors).Count -gt 0) {
    throw "REAL_MACHINE_PREFLIGHT_CONTRACT: preflight PowerShell parse failure: $($errors[0].Message)"
}

$preflight = Get-Content -LiteralPath $preflightPath -Raw
foreach ($needle in @(
    'REAL-MACHINE-PREFLIGHT-001',
    'SessionId',
    'ExplorerInSameSession',
    'CurrentUserIsSystem',
    'Excel',
    'Word',
    'PowerPoint',
    'ExpectedInstallerSha256',
    'RequireInstalledPayload',
    'New-OmnixEvidenceBinding',
    'Read-only preflight'
)) {
    if ($preflight.IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "REAL_MACHINE_PREFLIGHT_CONTRACT: preflight missing '$needle'."
    }
}

$forbiddenCommands = @(
    'Stop-Process','Start-Process','Remove-ItemProperty','New-ItemProperty','Set-ItemProperty',
    'Remove-Item','Set-NetFirewallProfile','Set-NetFirewallRule','New-NetFirewallRule',
    'Disable-NetAdapter','Enable-NetAdapter','Restart-Computer','Stop-Computer','shutdown.exe',
    'reg.exe','schtasks.exe','certutil.exe'
)

$commands = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst]
},$true))
foreach ($command in $commands) {
    $name = $command.GetCommandName()
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    foreach ($forbidden in $forbiddenCommands) {
        if ([string]::Equals($name,$forbidden,[StringComparison]::OrdinalIgnoreCase)) {
            throw "REAL_MACHINE_PREFLIGHT_CONTRACT: read-only preflight executes forbidden command '$name'."
        }
    }
}

$workflow = Get-Content -LiteralPath $workflowPath -Raw
foreach ($needle in @(
    'workflow_dispatch',
    'self-hosted',
    'Windows',
    'omnix-office-interactive',
    'real-machine-preflight.ps1',
    'bound-real-acceptance.ps1',
    'FullOfficeE2E',
    'upload-artifact'
)) {
    if ($workflow.IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "REAL_MACHINE_PREFLIGHT_CONTRACT: manual real-Office workflow missing '$needle'."
    }
}

foreach ($forbiddenText in @('Restart-Computer','shutdown.exe','Set-NetFirewall','Disable-NetAdapter','Enable-NetAdapter')) {
    if ($workflow.IndexOf($forbiddenText,[StringComparison]::OrdinalIgnoreCase) -ge 0) {
        throw "REAL_MACHINE_PREFLIGHT_CONTRACT: workflow contains forbidden environment mutation '$forbiddenText'."
    }
}

Write-Host 'REAL-MACHINE-PREFLIGHT-CONTRACT-001: PASS'
exit 0
