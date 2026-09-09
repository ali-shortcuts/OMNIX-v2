# OMNIX PowerShell automatic-variable safety contract.
# Prevents scripts from binding/assigning read-only automatic variables such as $Host.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]
$protected = @('Host')

$files = @(
    Get-ChildItem -LiteralPath (Join-Path $root 'build') -Filter '*.ps1' -File -Recurse -ErrorAction Stop
    Get-ChildItem -LiteralPath (Join-Path $root 'tools') -Filter '*.ps1' -File -Recurse -ErrorAction Stop
) | Sort-Object FullName -Unique

foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    foreach ($e in @($errors)) {
        $failures.Add("$($file.FullName.Substring($root.Length + 1)): parser error: $($e.Message)")
    }

    foreach ($paramAst in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true))) {
        $name = $paramAst.Name.VariablePath.UserPath
        if ($protected -contains $name) {
            $failures.Add("$($file.FullName.Substring($root.Length + 1)):$($paramAst.Extent.StartLineNumber): parameter `$${name} collides with a read-only automatic variable.")
        }
    }

    foreach ($foreachAst in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true))) {
        $name = $foreachAst.Variable.VariablePath.UserPath
        if ($protected -contains $name) {
            $failures.Add("$($file.FullName.Substring($root.Length + 1)):$($foreachAst.Extent.StartLineNumber): foreach variable `$${name} collides with a read-only automatic variable.")
        }
    }

    foreach ($assignAst in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))) {
        $left = $assignAst.Left
        if ($left -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $name = $left.VariablePath.UserPath
            if ($protected -contains $name) {
                $failures.Add("$($file.FullName.Substring($root.Length + 1)):$($assignAst.Extent.StartLineNumber): assignment to read-only automatic variable `$${name} is forbidden.")
            }
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host 'OMNIX POWERSHELL AUTOMATIC-VARIABLE CONTRACT: FAIL' -ForegroundColor Red
    foreach ($f in $failures) { Write-Host " - $f" -ForegroundColor Red }
    exit 1
}

Write-Host 'OMNIX POWERSHELL AUTOMATIC-VARIABLE CONTRACT: PASS'
Write-Host "Scanned $($files.Count) PowerShell scripts; no read-only automatic variable binding/assignment collisions found."
exit 0
