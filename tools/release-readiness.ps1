# OMNIX final release-readiness gate
#
# Run this ONLY after building the exact code commit you intend to release and after running:
#   tools/real-office-acceptance.ps1
#   tools/real-office-ui-acceptance.ps1
#   tools/reboot-persistence-acceptance.ps1 -Phase BeforeRestart
#   (restart Windows normally)
#   tools/reboot-persistence-acceptance.ps1 -Phase AfterRestart
#   tools/local-offline-acceptance.ps1   (with Internet intentionally disconnected)
#   tools/provider-acceptance.ps1        (online again for cloud provider evidence)
#   tools/privacy-acceptance.ps1         (compiled AiGateway/PrivacyGate runtime evidence)
#
# This script does not run providers, Office, restart Windows, alter networking, or manufacture
# evidence itself. It validates supplied evidence, requires all three Office hosts to auto-load
# OMNIX on two independent launches, requires a genuine Windows restart persistence proof, requires
# Ribbon/workspace UI proof, requires a real local-model round-trip while public Internet is observed
# disconnected, requires live provider model discovery + streaming evidence, requires deterministic
# runtime proof that the compiled AiGateway/PrivacyGate blocks or prompts BEFORE provider SendAsync,
# optionally requires every built-in cloud provider + Custom, verifies the installer hash, and
# requires a real trusted Authenticode signature for a production release.
#
# Output is intentionally sanitized: it does not copy machine names, API keys, prompts, response
# bodies, Authorization headers, or document contents into release evidence.

[CmdletBinding()]
param(
    [string]$OfficePersistenceReport = "$env:LOCALAPPDATA\OMNIX\logs\real-office-acceptance.json",
    [string]$OfficeUiReport = "$env:LOCALAPPDATA\OMNIX\logs\real-office-ui-acceptance.json",
    [string]$OfficeRestartReport = "$env:LOCALAPPDATA\OMNIX\logs\real-office-restart-acceptance.json",
    [string]$LocalOfflineReport = "$env:LOCALAPPDATA\OMNIX\logs\local-ai-offline-acceptance.json",
    [string]$ProviderReport = "$env:LOCALAPPDATA\OMNIX\logs\provider-acceptance.json",
    [string]$PrivacyReport = ".\build\artifact\privacy-acceptance.json",
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
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "$label report not found: $path" }
    try {
        return Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
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
    if (-not [bool]$report.RequiredHostCountPass) { $errors.Add('Office persistence did not prove all three required hosts.') }
    if (-not [bool]$report.TwoRoundsPerHostPass) { $errors.Add('Office persistence did not prove two launches per host.') }
    if (-not [bool]$report.AutomaticLoadEveryRoundPass) { $errors.Add('OMNIX did not auto-load on every Office launch.') }

    foreach ($name in @('Excel','Word','PowerPoint')) {
        $rows = @($report.Results | Where-Object { $_.Host -eq $name -and $_.Installed })
        if ($rows.Count -ne 2) {
            $errors.Add("$name persistence evidence must contain exactly two installed launch rounds.")
            continue
        }

        foreach ($round in @(1,2)) {
            $r = @($rows | Where-Object { [int]$_.Round -eq $round }) | Select-Object -First 1
            if ($null -eq $r) { $errors.Add("$name persistence round $round is missing."); continue }
            if (-not [bool]$r.Pass) { $errors.Add("$name persistence round $round failed.") }
            if (-not [bool]$r.AddinFound) { $errors.Add("$name round ${round}: OMNIX add-in not found.") }
            if (-not [bool]$r.InitialConnect) { $errors.Add("$name round ${round}: OMNIX was not already Connect=True after normal startup.") }
            if (-not [bool]$r.AutomaticLoadPass) { $errors.Add("$name round ${round}: automatic-load proof failed.") }
            if ([bool]$r.ForceConnectAttempted) { $errors.Add("$name round ${round}: force-connect was required; automatic persistence is not proven.") }

            if ($null -eq $r.Registry -or -not [bool]$r.Registry.Found) {
                $errors.Add("$name round ${round}: OMNIX registration not found.")
            } else {
                if ([int]$r.Registry.LoadBehavior -ne 3) { $errors.Add("$name round ${round}: LoadBehavior is not 3.") }
                if ($null -eq $r.Registry.Manifest -or -not [bool]$r.Registry.Manifest.Exists) {
                    $errors.Add("$name round ${round}: registered VSTO manifest target does not exist.")
                }
            }
        }
    }
    return $errors
}

function Test-OfficeRestart($report) {
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $report -or $report.TestId -ne 'OFFICE-RESTART-PERSISTENCE-REAL-001') {
        $errors.Add('Unexpected/missing Windows restart persistence TestId.')
        return $errors
    }
    if (-not [bool]$report.OverallPass) { $errors.Add('Windows restart persistence OverallPass is false.') }
    if (-not [bool]$report.BootSessionChanged) { $errors.Add('Windows boot session did not change; a real restart was not proven.') }
    if (-not [bool]$report.PreRestartPersistencePass) { $errors.Add('Strict Office persistence failed before Windows restart.') }
    if (-not [bool]$report.PostRestartPersistencePass) { $errors.Add('Strict Office persistence failed after Windows restart.') }
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
        if (-not [bool]$r.RibbonTabActivated) { $errors.Add("${name}: OMNIX Ribbon tab was not activated.") }
        if (-not [bool]$r.OpenWorkspaceButtonFound) { $errors.Add("${name}: Open Workspace button was not found.") }
        if (-not [bool]$r.OpenWorkspaceInvoked) { $errors.Add("${name}: Open Workspace was not invoked.") }
        if (-not [bool]$r.WorkspaceEvidenceFound) { $errors.Add("${name}: workspace UI evidence was not found.") }
        if (-not [bool]$r.WorkspaceEvidenceVisible) { $errors.Add("${name}: workspace UI evidence was not visibly rendered.") }
    }
    return $errors
}

function Test-LocalOffline($report) {
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $report -or $report.TestId -ne 'LOCAL-AI-OFFLINE-REAL-001') {
        $errors.Add('Unexpected/missing local-AI offline TestId.')
        return $errors
    }
    if (-not [bool]$report.OverallPass) { $errors.Add('Local-AI offline OverallPass is false.') }
    if (-not [bool]$report.InternetDisconnectedObserved) { $errors.Add('Offline local-AI evidence did not observe public Internet disconnected.') }
    if (-not [bool]$report.AtLeastOneLocalRuntimePass) { $errors.Add('No local runtime completed a real model chat while Internet was disconnected.') }

    $passing = @($report.LocalProviders | Where-Object {
        ($_.Provider -eq 'Ollama' -or $_.Provider -eq 'LM Studio') -and $_.Pass -and $_.ModelsPass -and $_.ChatPass -and -not [string]::IsNullOrWhiteSpace([string]$_.Model)
    })
    if ($passing.Count -lt 1) {
        $errors.Add('Offline local-AI evidence lacks a passing Ollama/LM Studio model-list + chat round-trip.')
    }
    return $errors
}

function Test-PrivacyGateway($report) {
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $report -or $report.TestId -ne 'PRIVACY-GATE-RUNTIME-001') {
        $errors.Add('Unexpected/missing compiled AI Gateway privacy TestId.')
        return $errors
    }
    if ([int]$report.EvidenceSchema -lt 1) { $errors.Add('Privacy runtime evidence schema is missing/invalid.') }
    if (-not [bool]$report.OverallPass) { $errors.Add('Compiled AI Gateway privacy OverallPass is false.') }
    if ([int]$report.LocalOnlyCloudRoutesTested -lt 7) { $errors.Add('LocalOnly privacy test did not exercise all built-in cloud routes.') }
    if (-not [bool]$report.LocalOnlyAllCloudRoutesBlocked) { $errors.Add('LocalOnly did not block every registered cloud route.') }
    if (-not [bool]$report.LocalOnlyFakeCloudSendPrevented) { $errors.Add('LocalOnly allowed the instrumented cloud SendAsync path.') }
    if (-not [bool]$report.AskDeniedBlockedBeforeSend) { $errors.Add('AskBeforeSending denial did not block before provider SendAsync.') }
    if (-not [bool]$report.AskApprovedBeforeSend) { $errors.Add('AskBeforeSending approval was not proven to occur before provider SendAsync.') }
    if (-not [bool]$report.AskRememberSessionPass) { $errors.Add('AskBeforeSending remembered-session behavior failed.') }
    if (-not [bool]$report.CloudAllowedNoPromptPass) { $errors.Add('CloudAllowed unexpectedly invoked confirmation or failed to route.') }
    if (-not [bool]$report.LocalOnlyLocalRoutePass) { $errors.Add('LocalOnly did not preserve an explicitly available local route.') }
    return $errors
}

function Test-ProviderRow($r, [string]$name) {
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $r) {
        $errors.Add("Provider evidence missing: $name")
        return $errors
    }
    if (-not [bool]$r.Configured) {
        $errors.Add("Provider not configured/tested: $name")
        return $errors
    }
    if ([string]::IsNullOrWhiteSpace([string]$r.Model)) { $errors.Add("Provider live model selection failed: $name") }
    if ([string]::IsNullOrWhiteSpace([string]$r.ModelSource) -or [string]$r.ModelSource -notlike 'live:*') {
        $errors.Add("Provider model was not selected from live discovery: $name")
    }
    if (-not [bool]$r.ModelsPass) { $errors.Add("Provider live model list failed: $name") }
    if (-not [bool]$r.ChatPass) { $errors.Add("Provider chat request failed: $name ($($r.ErrorCategory))") }
    if (-not [bool]$r.StreamingPass) { $errors.Add("Provider streaming evidence failed: $name ($($r.ErrorCategory))") }
    if ([int]$r.StreamEventCount -lt 1) { $errors.Add("Provider produced no streaming events: $name") }
    if ($null -eq $r.FirstStreamEventMs) { $errors.Add("Provider first-stream-event timing is missing: $name") }
    if (-not [bool]$r.Pass) { $errors.Add("Provider runtime test failed: $name ($($r.ErrorCategory))") }
    return $errors
}

function Test-Providers($report, [bool]$requireAllCloud, [bool]$requireCustom) {
    $errors = New-Object System.Collections.Generic.List[string]
    if ($null -eq $report -or $report.TestId -ne 'PROVIDERS-RUNTIME-001') {
        $errors.Add('Unexpected/missing provider TestId.')
        return $errors
    }
    if ([int]$report.EvidenceSchema -lt 2) {
        $errors.Add('Provider evidence schema is too old; live-discovery + streaming evidence is required.')
    }

    $localRows = @($report.Results | Where-Object { $_.Provider -eq 'Ollama' -or $_.Provider -eq 'LM Studio' })
    $localPass = @($localRows | Where-Object {
        $_.Configured -and $_.Pass -and $_.ModelsPass -and $_.StreamingPass -and -not [string]::IsNullOrWhiteSpace([string]$_.Model)
    })
    if ($localPass.Count -lt 1) {
        $errors.Add('At least one local AI runtime (Ollama or LM Studio) must pass live model discovery + a real streaming chat round-trip in the provider harness.')
    }

    if ($requireAllCloud) {
        foreach ($name in @('Gemini','Groq','OpenRouter','Mistral AI','Hugging Face','Cerebras')) {
            $r = @($report.Results | Where-Object { $_.Provider -eq $name }) | Select-Object -First 1
            foreach ($e in @(Test-ProviderRow $r $name)) { $errors.Add([string]$e) }
            if ($name -eq 'OpenRouter' -and $null -ne $r -and -not [bool]$r.FreeRoutePreferencePass) {
                $errors.Add('OpenRouter did not select openrouter/free or a live :free route before non-free routes.')
            }
        }
    }

    if ($requireCustom) {
        $custom = @($report.Results | Where-Object { $_.Provider -eq 'Custom' }) | Select-Object -First 1
        foreach ($e in @(Test-ProviderRow $custom 'Custom')) { $errors.Add([string]$e) }
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
            ModelSource = if ($null -eq $r.ModelSource) { $null } else { [string]$r.ModelSource }
            ModelsPass = [bool]$r.ModelsPass
            StreamingPass = [bool]$r.StreamingPass
            StreamEventCount = [int]$r.StreamEventCount
            FirstStreamEventMs = $r.FirstStreamEventMs
            FreeRoutePreferencePass = $r.FreeRoutePreferencePass
            ErrorCategory = if ($null -eq $r.ErrorCategory) { $null } else { [string]$r.ErrorCategory }
        }
    }
    return $summary
}

$officePersistence = Read-JsonFile $OfficePersistenceReport 'Office persistence'
$officeUi = Read-JsonFile $OfficeUiReport 'Office UI'
$officeRestart = Read-JsonFile $OfficeRestartReport 'Windows restart persistence'
$localOffline = Read-JsonFile $LocalOfflineReport 'Local-AI offline'
$providers = Read-JsonFile $ProviderReport 'Provider'
$privacyGateway = Read-JsonFile $PrivacyReport 'Compiled AI Gateway privacy'

if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) { throw "Installer not found: $InstallerPath" }
$installer = Get-Item -LiteralPath $InstallerPath
if ($installer.Length -lt 1MB) { throw "Installer is unexpectedly small ($($installer.Length) bytes)." }

$failures = New-Object System.Collections.Generic.List[string]
foreach ($e in @(Test-OfficePersistence $officePersistence)) { $failures.Add([string]$e) }
foreach ($e in @(Test-OfficeUi $officeUi)) { $failures.Add([string]$e) }
foreach ($e in @(Test-OfficeRestart $officeRestart)) { $failures.Add([string]$e) }
foreach ($e in @(Test-LocalOffline $localOffline)) { $failures.Add([string]$e) }
foreach ($e in @(Test-Providers $providers ([bool]$RequireAllCloudProviders) ([bool]$RequireCustomProvider))) { $failures.Add([string]$e) }
foreach ($e in @(Test-PrivacyGateway $privacyGateway)) { $failures.Add([string]$e) }

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $InstallerPath).Hash.ToLowerInvariant()
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
        PersistenceRoundsPass = ($pRows.Count -eq 2 -and @($pRows | Where-Object { -not $_.Pass }).Count -eq 0)
        AutomaticLoadEveryRoundPass = ($pRows.Count -eq 2 -and @($pRows | Where-Object { -not $_.AutomaticLoadPass }).Count -eq 0)
        NoForceConnectNeeded = ($pRows.Count -eq 2 -and @($pRows | Where-Object { $_.ForceConnectAttempted }).Count -eq 0)
        RibbonPass = ($null -ne $uiRow -and [bool]$uiRow.RibbonTabFound -and [bool]$uiRow.RibbonTabActivated)
        WorkspacePass = ($null -ne $uiRow -and [bool]$uiRow.WorkspaceEvidenceFound -and [bool]$uiRow.WorkspaceEvidenceVisible)
        RestartPersistencePass = [bool]$officeRestart.OverallPass
    }
}

$outDir = Split-Path -Parent $OutputPath
if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

$evidence = [ordered]@{
    EvidenceSchema = 5
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
    RestartPersistence = [ordered]@{
        BootSessionChanged = [bool]$officeRestart.BootSessionChanged
        PreRestartPersistencePass = [bool]$officeRestart.PreRestartPersistencePass
        PostRestartPersistencePass = [bool]$officeRestart.PostRestartPersistencePass
        OverallPass = [bool]$officeRestart.OverallPass
    }
    LocalOffline = [ordered]@{
        InternetDisconnectedObserved = [bool]$localOffline.InternetDisconnectedObserved
        AtLeastOneLocalRuntimePass = [bool]$localOffline.AtLeastOneLocalRuntimePass
        OverallPass = [bool]$localOffline.OverallPass
    }
    PrivacyGatewayRuntime = [ordered]@{
        LocalOnlyCloudRoutesTested = [int]$privacyGateway.LocalOnlyCloudRoutesTested
        LocalOnlyAllCloudRoutesBlocked = [bool]$privacyGateway.LocalOnlyAllCloudRoutesBlocked
        CloudSendPreventedUnderLocalOnly = [bool]$privacyGateway.LocalOnlyFakeCloudSendPrevented
        AskDeniedBlockedBeforeSend = [bool]$privacyGateway.AskDeniedBlockedBeforeSend
        AskApprovedBeforeSend = [bool]$privacyGateway.AskApprovedBeforeSend
        AskRememberSessionPass = [bool]$privacyGateway.AskRememberSessionPass
        CloudAllowedNoPromptPass = [bool]$privacyGateway.CloudAllowedNoPromptPass
        LocalOnlyLocalRoutePass = [bool]$privacyGateway.LocalOnlyLocalRoutePass
        OverallPass = [bool]$privacyGateway.OverallPass
    }
    Providers = Get-ProviderSummary $providers
    Requirements = [ordered]@{
        AllThreeOfficeHosts = $true
        OfficePersistenceTwoLaunches = $true
        AutomaticLoadWithoutForceConnect = $true
        WindowsRestartPersistence = $true
        RibbonAndWorkspaceUi = $true
        LocalAiWithInternetDisconnected = $true
        AtLeastOneLocalAi = $true
        GatewayPrivacyOrderingRuntime = $true
        LiveProviderModelDiscovery = $true
        StreamingProviderRoundTrips = $true
        OpenRouterFreeRoutePriority = [bool]$RequireAllCloudProviders
        AllBuiltInCloudProviders = [bool]$RequireAllCloudProviders
        CustomProvider = [bool]$RequireCustomProvider
        ProductionAuthenticode = (-not [bool]$AllowDevelopmentSignature)
    }
    FailureCount = $failures.Count
    Failures = @($failures)
    OverallPass = ($failures.Count -eq 0)
    Privacy = 'Sanitized evidence only; no API keys, prompts, response bodies, machine names or Office document data copied.'
}

$evidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$evidence | ConvertTo-Json -Depth 10

if ($failures.Count -gt 0) { exit 1 }
exit 0
