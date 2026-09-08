# OMNIX final release-readiness gate
#
# Run this ONLY after building the exact code commit you intend to release and after running:
#   tools/real-office-acceptance.ps1
#   tools/real-office-ui-acceptance.ps1
#   tools/provider-acceptance.ps1
#
# This script does not run providers or Office itself. It validates their evidence, requires the
# three Office hosts to have passed, requires at least one local AI runtime, optionally requires
# every built-in cloud provider + Custom to have passed, verifies the installer hash and requires
# a real trusted Authenticode signature for a production release.
#
# Output is intentionally sanitized: it does not copy machine names, API keys, prompts, response
# bodies, Authorization headers, or document contents into release evidence.

[CmdletBinding()]
param(
    [string]$OfficePersistenceReport = "$env:LOCALAPPDATA\OMNIX\logs\real-office-acceptance.json",
    [string]$OfficeUiReport = "$env:LOCALAPPDATA\OMNIX\logs\real-office-ui-acceptance.json",
    [string]$ProviderReport = "$env:LOCALAPPDATA\OMNIX\logs\provider-acceptance.json",
    [Parameter(Mandatory=$true)]
    [string]$InstallerPath,
    [string]$OutputPath = ".\release-evidence\release-readiness.json",
    [switch]$RequireAllCloudProviders = $true,
    [switch]$RequireCustomProvider = $true,
    [switch]$AllowDevelopmentSignature
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-JsonFile([string]$path, [string]$label) {
    if (-not (Test-Path $path)) { throw "$label report not found: $path" }
    try {
        return Get-Content -Raw -Path $path | ConvertFrom-Json
    } catch {
        throw "$label report is not valid JSON: $path — $($_.Exception.Message)"
    }
}

function Get-GitHead {
    try {
        $sha = (& git rev-parse HEAD 2>$null).Trim()
        if ($LASTEXITCODE -eq 0 -and $sha -match '^[0-9a-fA-F]{40}$') { return $sha.ToLowerInvariant() }
    } catch { }
    return $null
}

function Test-OfficePersistence($report) {
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $report -or $report.TestId -ne 'OFFICE-PERSISTENCE-REAL-001') {
        $errors.Add('Unexpected/missing persistence TestId.')
        return $errors
    }
    if (-not [bool]$report.OverallPass) { $errors.Add('Office persistence OverallPass is false.') }

    foreach ($name in @('Excel','Word','PowerPoint')) {
        $rows = @($report.Results | Where-Object { $_.Host -eq $name -and $_.Installed })
        if ($rows.Count -lt 2) {
            $errors.Add("$name persistence evidence must contain two installed launch rounds.")
            continue
        }
        foreach ($round in @(1,2)) {
            $r = @($rows | Where-Object { [int]$_.Round -eq $round }) | Select-Object -First 1
            if ($null -eq $r) { $errors.Add("$name persistence round $round is missing."); continue }
            if (-not [bool]$r.Pass) { $errors.Add("$name persistence round $round failed.") }
            if (-not [bool]$r.AddinFound) { $errors.Add("$name round ${round}: OMNIX add-in not found.") }
            if (-not [bool]$r.FinalConnect) { $errors.Add("$name round ${round}: OMNIX Connect=False.") }
        }
    }
    return $errors
}

function Test-OfficeUi($report) {
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $report -or $report.TestId -ne 'OFFICE-UI-REAL-001') {
        $errors.Add('Unexpected/missing Office UI TestId.')
        return $errors
    }
    if (-not [bool]$report.OverallPass) { $errors.Add('Office UI OverallPass is false.') }

    foreach ($name in @('Excel','Word','PowerPoint')) {
        $r = @($report.Results | Where-Object { $_.Host -eq $name -and $_.Installed }) | Select-Object -First 1
        if ($null -eq $r) { $errors.Add("$name UI evidence is missing or host was not installed."); continue }
        if (-not [bool]$r.Pass) { $errors.Add("$name UI acceptance failed.") }
        if (-not [bool]$r.RibbonTabFound) { $errors.Add("${name}: OMNIX Ribbon tab was not found.") }
        if (-not [bool]$r.OpenWorkspaceButtonFound) { $errors.Add("${name}: Open Workspace button was not found.") }
        if (-not [bool]$r.OpenWorkspaceInvoked) { $errors.Add("${name}: Open Workspace was not invoked.") }
        if (-not [bool]$r.WorkspaceEvidenceFound) { $errors.Add("${name}: workspace UI evidence was not found.") }
    }
    return $errors
}

function Test-Providers($report, [bool]$requireAllCloud, [bool]$requireCustom) {
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $report -or $report.TestId -ne 'PROVIDERS-RUNTIME-001') {
        $errors.Add('Unexpected/missing provider TestId.')
        return $errors
    }

    $localPass = @($report.Results | Where-Object {
        ($_.Provider -eq 'Ollama' -or $_.Provider -eq 'LM Studio') -and $_.Configured -and $_.Pass
    })
    if ($localPass.Count -lt 1) {
        $errors.Add('At least one local AI runtime (Ollama or LM Studio) must pass a real chat round-trip.')
    }

    if ($requireAllCloud) {
        foreach ($name in @('Gemini','Groq','OpenRouter','Mistral AI','Hugging Face','Cerebras')) {
            $r = @($report.Results | Where-Object { $_.Provider -eq $name }) | Select-Object -First 1
            if ($null -eq $r) { $errors.Add("Provider evidence missing: $name"); continue }
            if (-not [bool]$r.Configured) { $errors.Add("Provider not configured/tested: $name") }
            elseif (-not [bool]$r.Pass) { $errors.Add("Provider runtime test failed: $name ($($r.ErrorCategory))") }
        }
    }

    if ($requireCustom) {
        $custom = @($report.Results | Where-Object { $_.Provider -eq 'Custom' }) | Select-Object -First 1
        if ($null -eq $custom) { $errors.Add('Custom provider evidence is missing.') }
        elseif (-not [bool]$custom.Configured) { $errors.Add('Custom provider was not configured/tested.') }
        elseif (-not [bool]$custom.Pass) { $errors.Add("Custom provider runtime test failed ($($custom.ErrorCategory)).") }
    }

    return $errors
}

function Get-ProviderSummary($report) {
    $summary = @()
    foreach ($r in @($report.Results)) {
        $summary += [ordered]@{
            Provider = [string]$r.Provider
            Configured = [bool]$r.Configured
            Pass = [bool]$r.Pass
            Model = [string]$r.Model
            ErrorCategory = if ($null -eq $r.ErrorCategory) { $null } else { [string]$r.ErrorCategory }
        }
    }
    return $summary
}

$officePersistence = Read-JsonFile $OfficePersistenceReport 'Office persistence'
$officeUi = Read-JsonFile $OfficeUiReport 'Office UI'
$providers = Read-JsonFile $ProviderReport 'Provider'

if (-not (Test-Path $InstallerPath)) { throw "Installer not found: $InstallerPath" }
$installer = Get-Item $InstallerPath
if ($installer.Length -lt 1MB) { throw "Installer is unexpectedly small ($($installer.Length) bytes)." }

$failures = New-Object System.Collections.Generic.List[string]
foreach ($e in @(Test-OfficePersistence $officePersistence)) { $failures.Add([string]$e) }
foreach ($e in @(Test-OfficeUi $officeUi)) { $failures.Add([string]$e) }
foreach ($e in @(Test-Providers $providers ([bool]$RequireAllCloudProviders) ([bool]$RequireCustomProvider))) { $failures.Add([string]$e) }

$hash = (Get-FileHash -Algorithm SHA256 -Path $InstallerPath).Hash.ToLowerInvariant()
$signature = Get-AuthenticodeSignature -FilePath $InstallerPath
$signer = $signature.SignerCertificate
$selfSigned = $false
if ($null -ne $signer) {
    $selfSigned = [string]::Equals($signer.Subject, $signer.Issuer, [StringComparison]::OrdinalIgnoreCase)
}

if (-not $AllowDevelopmentSignature) {
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        $failures.Add("Installer Authenticode signature is not Valid (status=$($signature.Status)).")
    }
    if ($null -eq $signer) {
        $failures.Add('Installer has no Authenticode signer certificate.')
    } elseif ($selfSigned) {
        $failures.Add('Installer signer certificate is self-signed; production release requires a trusted code-signing certificate.')
    }
}

$sourceCommit = Get-GitHead
if ([string]::IsNullOrWhiteSpace($sourceCommit)) {
    $failures.Add('Could not resolve the tested Git commit. Run the release gate from the OMNIX git checkout.')
}

$officeSummary = @()
foreach ($name in @('Excel','Word','PowerPoint')) {
    $pRows = @($officePersistence.Results | Where-Object { $_.Host -eq $name -and $_.Installed })
    $uiRow = @($officeUi.Results | Where-Object { $_.Host -eq $name -and $_.Installed }) | Select-Object -First 1
    $officeSummary += [ordered]@{
        Host = $name
        Version = if ($pRows.Count -gt 0) { [string]$pRows[0].Version } else { $null }
        PersistenceRoundsPass = ($pRows.Count -ge 2 -and @($pRows | Where-Object { -not $_.Pass }).Count -eq 0)
        RibbonPass = ($null -ne $uiRow -and [bool]$uiRow.RibbonTabFound)
        WorkspacePass = ($null -ne $uiRow -and [bool]$uiRow.WorkspaceEvidenceFound)
    }
}

$outDir = Split-Path -Parent $OutputPath
if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

$evidence = [ordered]@{
    EvidenceSchema = 1
    TestId = 'OMNIX-RELEASE-READINESS-001'
    GeneratedUtc = (Get-Date).ToUniversalTime().ToString('o')
    SourceCommit = $sourceCommit
    Installer = [ordered]@{
        FileName = $installer.Name
        SizeBytes = [int64]$installer.Length
        Sha256 = $hash
        SignatureStatus = [string]$signature.Status
        SignerSubject = if ($signer) { [string]$signer.Subject } else { $null }
        SignerThumbprint = if ($signer) { [string]$signer.Thumbprint } else { $null }
        SelfSigned = $selfSigned
        Timestamped = ($null -ne $signature.TimeStamperCertificate)
    }
    Office = $officeSummary
    Providers = Get-ProviderSummary $providers
    Requirements = [ordered]@{
        AllThreeOfficeHosts = $true
        OfficePersistenceTwoLaunches = $true
        RibbonAndWorkspaceUi = $true
        AtLeastOneLocalAi = $true
        AllBuiltInCloudProviders = [bool]$RequireAllCloudProviders
        CustomProvider = [bool]$RequireCustomProvider
        ProductionAuthenticode = (-not [bool]$AllowDevelopmentSignature)
    }
    FailureCount = $failures.Count
    Failures = @($failures)
    OverallPass = ($failures.Count -eq 0)
    Privacy = 'Sanitized evidence only; no API keys, prompts, response bodies, machine names or Office document data copied.'
}

$evidence | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8
$evidence | ConvertTo-Json -Depth 10

if ($failures.Count -gt 0) { exit 1 }
exit 0
