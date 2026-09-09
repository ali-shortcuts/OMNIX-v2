# OMNIX provider request-budget runtime acceptance
#
# Deterministic, offline test of the compiled OMNIX.Core ChatRequestBudgeter. It proves that local
# chat history may remain useful to the UI while provider-bound replay is hard-bounded and stale
# image bytes are not resent forever. No Office application, provider, network, registry or file
# outside the requested JSON output is touched.

[CmdletBinding()]
param(
    [string]$CorePath = ".\src\OMNIX.Core\bin\Release\OMNIX.Core.dll",
    [string]$OutputPath = ".\build\artifact\request-budget-acceptance.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$core = (Resolve-Path -LiteralPath $CorePath -ErrorAction Stop).Path
$coreDir = Split-Path -Parent $core
$newtonsoft = Join-Path $coreDir 'Newtonsoft.Json.dll'
if (Test-Path -LiteralPath $newtonsoft) { [void][Reflection.Assembly]::LoadFrom($newtonsoft) }
[void][Reflection.Assembly]::LoadFrom($core)

function New-Turn([string]$roleName, [string]$text) {
    $turn = New-Object -TypeName 'OMNIX.Core.Storage.ChatTurn'
    $turn.Role = [Enum]::Parse(('OMNIX.Core.Storage.ChatRole' -as [type]), $roleName)
    $turn.Text = $text
    $turn.TimestampUtc = [DateTime]::UtcNow
    return $turn
}

function New-Image([int]$bytes, [string]$name = 'budget.png') {
    $img = New-Object -TypeName 'OMNIX.Core.Storage.ImageAttachment'
    $img.FileName = $name
    $img.SourceLabel = 'request-budget-acceptance'
    $img.PngBytes = New-Object byte[] $bytes
    return $img
}

function New-ImageList([object[]]$images) {
    $listType = [System.Collections.Generic.List``1].MakeGenericType(('OMNIX.Core.Storage.ImageAttachment' -as [type]))
    $list = [Activator]::CreateInstance($listType)
    foreach ($img in $images) { [void]$list.Add($img) }
    return $list
}

function New-TurnList {
    $listType = [System.Collections.Generic.List``1].MakeGenericType(('OMNIX.Core.Storage.ChatTurn' -as [type]))
    return [Activator]::CreateInstance($listType)
}

function Invoke-Budget($request) {
    $type = 'OMNIX.Core.AiGateway.ChatRequestBudgeter' -as [type]
    if ($null -eq $type) { throw 'ChatRequestBudgeter type is missing from compiled OMNIX.Core.' }
    return $type.GetMethod('Apply').Invoke($null, @($request))
}

$failures = New-Object System.Collections.Generic.List[string]
$settings = [OMNIX.Core.Settings.SettingsManager]::Instance.Settings
$oldHistoryMax = $settings.HistoryMaxMessages
$oldContextTokens = $settings.ContextMaxTokens

$result = [ordered]@{
    TestId = 'REQUEST-BUDGET-RUNTIME-001'
    EvidenceSchema = 1
    GeneratedUtc = [DateTime]::UtcNow.ToString('o')
    HistoryTurnCapPass = $false
    HistoryCharCapPass = $false
    HistoricalImagesRemovedPass = $false
    HistoricalImageMarkerPass = $false
    CurrentImagePreservedPass = $false
    SystemPromptCapPass = $false
    SourceRequestNotMutatedPass = $false
    OversizedCurrentTextRejectedPass = $false
    TooManyCurrentImagesRejectedPass = $false
    FailureCount = 0
    Failures = @()
    OverallPass = $false
    Privacy = 'Aggregate booleans/counts only; no prompts, document content, API keys or image bytes are written.'
}

try {
    # Force the hard history ceilings rather than a lower user preference.
    $settings.HistoryMaxMessages = 500
    $settings.ContextMaxTokens = 10000

    $history = New-TurnList
    for ($i = 0; $i -lt 150; $i++) {
        $role = if (($i % 2) -eq 0) { 'User' } else { 'Assistant' }
        $turn = New-Turn $role (("H{0:D3}:" -f $i) + ('x' * 2000))
        if ($i -eq 149) {
            $turn.Images = New-ImageList @((New-Image 32 'old-image.png'))
        }
        [void]$history.Add($turn)
    }

    $current = New-Turn 'User' 'current request'
    $current.Images = New-ImageList @((New-Image 1024 'current.png'))

    $request = New-Object -TypeName 'OMNIX.Core.AiGateway.ChatRequest'
    $request.SystemPrompt = 'S' * 40000
    $request.History = $history
    $request.UserTurn = $current

    $bounded = Invoke-Budget $request

    $result.HistoryTurnCapPass = [bool]($bounded.History.Count -le 80 -and $bounded.History.Count -gt 0)
    if (-not $result.HistoryTurnCapPass) { $failures.Add('History turn count exceeded the hard provider replay cap.') }

    $historyChars = 0
    foreach ($turn in $bounded.History) { $historyChars += ([string]$turn.Text).Length }
    $result.HistoryCharCapPass = [bool]($historyChars -le (48 * 1024))
    if (-not $result.HistoryCharCapPass) { $failures.Add('History text exceeded the hard provider replay character cap.') }

    $historyHasBytes = $false
    $markerFound = $false
    foreach ($turn in $bounded.History) {
        if (([string]$turn.Text).Contains('earlier image was omitted from provider replay')) { $markerFound = $true }
        if ($null -ne $turn.Images) {
            foreach ($img in $turn.Images) {
                if ($null -ne $img -and $null -ne $img.PngBytes -and $img.PngBytes.Length -gt 0) { $historyHasBytes = $true }
            }
        }
    }
    $result.HistoricalImagesRemovedPass = -not $historyHasBytes
    $result.HistoricalImageMarkerPass = $markerFound
    if (-not $result.HistoricalImagesRemovedPass) { $failures.Add('Historical image bytes survived provider replay budgeting.') }
    if (-not $result.HistoricalImageMarkerPass) { $failures.Add('Historical image omission was not made explicit to the model.') }

    $result.CurrentImagePreservedPass = [bool](
        $null -ne $bounded.UserTurn.Images -and
        $bounded.UserTurn.Images.Count -eq 1 -and
        $bounded.UserTurn.Images[0].PngBytes.Length -eq 1024)
    if (-not $result.CurrentImagePreservedPass) { $failures.Add('Current bounded image was not preserved.') }

    $result.SystemPromptCapPass = [bool](([string]$bounded.SystemPrompt).Length -le (32 * 1024))
    if (-not $result.SystemPromptCapPass) { $failures.Add('System prompt exceeded the hard request cap.') }

    $result.SourceRequestNotMutatedPass = [bool](
        $request.History.Count -eq 150 -and
        $request.History[149].Images[0].PngBytes.Length -eq 32 -and
        $request.UserTurn.Images[0].PngBytes.Length -eq 1024)
    if (-not $result.SourceRequestNotMutatedPass) { $failures.Add('Budgeting mutated the source conversation/request objects.') }

    # Current user text must fail closed rather than silently losing the user's newest message.
    try {
        $tooLong = New-Object -TypeName 'OMNIX.Core.AiGateway.ChatRequest'
        $tooLong.UserTurn = New-Turn 'User' ('z' * ((64 * 1024) + 1))
        [void](Invoke-Budget $tooLong)
        $result.OversizedCurrentTextRejectedPass = $false
    } catch {
        $result.OversizedCurrentTextRejectedPass = $true
    }
    if (-not $result.OversizedCurrentTextRejectedPass) { $failures.Add('Oversized current text was not rejected.') }

    # Current images are useful, but one request cannot carry an unbounded number of them.
    try {
        $tooMany = New-Object -TypeName 'OMNIX.Core.AiGateway.ChatRequest'
        $tooMany.UserTurn = New-Turn 'User' 'five images'
        $tooMany.UserTurn.Images = New-ImageList @(
            (New-Image 8 '1.png'), (New-Image 8 '2.png'), (New-Image 8 '3.png'),
            (New-Image 8 '4.png'), (New-Image 8 '5.png'))
        [void](Invoke-Budget $tooMany)
        $result.TooManyCurrentImagesRejectedPass = $false
    } catch {
        $result.TooManyCurrentImagesRejectedPass = $true
    }
    if (-not $result.TooManyCurrentImagesRejectedPass) { $failures.Add('More than four current images were not rejected.') }
}
finally {
    $settings.HistoryMaxMessages = $oldHistoryMax
    $settings.ContextMaxTokens = $oldContextTokens
}

$result.FailureCount = $failures.Count
$result.Failures = @($failures)
$result.OverallPass = ($failures.Count -eq 0)

$outDir = Split-Path -Parent $OutputPath
if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$result | ConvertTo-Json -Depth 8

if (-not $result.OverallPass) { exit 1 }
exit 0
