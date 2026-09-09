# OMNIX real local-AI offline acceptance gate
#
# Run this on the target Windows machine with Internet intentionally disconnected and with
# Ollama or LM Studio already running with at least one real local model loaded/available.
#
# The script NEVER disables network adapters, firewall rules, VPNs, proxies, or security settings.
# It only observes whether public HTTPS probes fail, then performs a real localhost model-list +
# chat round-trip. PASS requires no public HTTPS probe to succeed and at least one local runtime
# to complete a real chat request.

[CmdletBinding()]
param(
    [string]$OutputPath = "$env:LOCALAPPDATA\OMNIX\logs\local-ai-offline-acceptance.json",
    [int]$TimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Net.Http

$logDir = Split-Path -Parent $OutputPath
if ($logDir) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }

function Invoke-JsonHttp {
    param(
        [string]$Method,
        [string]$Url,
        [object]$Body,
        [int]$Timeout = 10
    )

    $client = $null
    $request = $null
    $response = $null
    try {
        $handler = New-Object System.Net.Http.HttpClientHandler
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds($Timeout)
        $request = New-Object System.Net.Http.HttpRequestMessage
        $request.Method = New-Object System.Net.Http.HttpMethod($Method)
        $request.RequestUri = [Uri]$Url
        if ($null -ne $Body) {
            $json = $Body | ConvertTo-Json -Depth 16 -Compress
            $request.Content = New-Object System.Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')
        }
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        return [pscustomobject]@{
            Status = [int]$response.StatusCode
            Success = [bool]$response.IsSuccessStatusCode
            Body = $text
            TransportError = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Status = 0
            Success = $false
            Body = ''
            TransportError = $_.Exception.GetType().Name
        }
    }
    finally {
        if ($response) { $response.Dispose() }
        if ($request) { $request.Dispose() }
        if ($client) { $client.Dispose() }
    }
}

function Test-PublicInternetDisconnected {
    $probes = @(
        'https://www.microsoft.com/',
        'https://www.cloudflare.com/'
    )
    $results = @()
    foreach ($url in $probes) {
        $r = Invoke-JsonHttp -Method 'GET' -Url $url -Body $null -Timeout 5
        $results += [pscustomobject]@{
            Endpoint = ([Uri]$url).Host
            Reachable = [bool]$r.Success
            Status = [int]$r.Status
            TransportError = $r.TransportError
        }
    }
    return $results
}

function Test-Ollama {
    $models = Invoke-JsonHttp -Method 'GET' -Url 'http://localhost:11434/api/tags' -Body $null -Timeout 5
    if (-not $models.Success) {
        return [pscustomobject]@{
            Provider='Ollama'; Running=$false; Model=$null; ModelsPass=$false; ChatPass=$false; Pass=$false; Status=$models.Status
        }
    }

    $model = $null
    try {
        $parsed = $models.Body | ConvertFrom-Json
        if ($parsed.models -and $parsed.models.Count -gt 0) { $model = [string]$parsed.models[0].name }
    } catch { }

    if ([string]::IsNullOrWhiteSpace($model)) {
        return [pscustomobject]@{
            Provider='Ollama'; Running=$true; Model=$null; ModelsPass=$false; ChatPass=$false; Pass=$false; Status='NO_LOCAL_MODEL'
        }
    }

    $chat = Invoke-JsonHttp -Method 'POST' -Url 'http://localhost:11434/api/chat' -Body @{
        model=$model
        messages=@(@{role='user';content='Reply with exactly READY.'})
        stream=$false
    } -Timeout $TimeoutSeconds

    return [pscustomobject]@{
        Provider='Ollama'; Running=$true; Model=$model; ModelsPass=$true; ChatPass=[bool]$chat.Success; Pass=[bool]$chat.Success; Status=$chat.Status
    }
}

function Test-LmStudio {
    $models = Invoke-JsonHttp -Method 'GET' -Url 'http://localhost:1234/v1/models' -Body $null -Timeout 5
    if (-not $models.Success) {
        return [pscustomobject]@{
            Provider='LM Studio'; Running=$false; Model=$null; ModelsPass=$false; ChatPass=$false; Pass=$false; Status=$models.Status
        }
    }

    $model = $null
    try {
        $parsed = $models.Body | ConvertFrom-Json
        if ($parsed.data -and $parsed.data.Count -gt 0) { $model = [string]$parsed.data[0].id }
    } catch { }

    if ([string]::IsNullOrWhiteSpace($model)) {
        return [pscustomobject]@{
            Provider='LM Studio'; Running=$true; Model=$null; ModelsPass=$false; ChatPass=$false; Pass=$false; Status='NO_LOCAL_MODEL'
        }
    }

    $chat = Invoke-JsonHttp -Method 'POST' -Url 'http://localhost:1234/v1/chat/completions' -Body @{
        model=$model
        messages=@(@{role='user';content='Reply with exactly READY.'})
        stream=$false
        max_tokens=32
    } -Timeout $TimeoutSeconds

    return [pscustomobject]@{
        Provider='LM Studio'; Running=$true; Model=$model; ModelsPass=$true; ChatPass=[bool]$chat.Success; Pass=[bool]$chat.Success; Status=$chat.Status
    }
}

$publicProbes = @(Test-PublicInternetDisconnected)
$internetReachable = (@($publicProbes | Where-Object { $_.Reachable }).Count -gt 0)
$localResults = @((Test-Ollama), (Test-LmStudio))
$localPass = @($localResults | Where-Object { $_.Pass })

$failures = New-Object System.Collections.Generic.List[string]
if ($internetReachable) {
    $failures.Add('At least one public HTTPS endpoint was reachable. Disconnect Internet before running the offline acceptance gate.')
}
if ($localPass.Count -lt 1) {
    $failures.Add('Neither Ollama nor LM Studio completed a real local-model chat round-trip.')
}

$report = [ordered]@{
    EvidenceSchema = 1
    TestId = 'LOCAL-AI-OFFLINE-REAL-001'
    TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    InternetDisconnectedObserved = (-not $internetReachable)
    PublicProbes = @($publicProbes)
    LocalProviders = @($localResults)
    AtLeastOneLocalRuntimePass = ($localPass.Count -gt 0)
    FailureCount = $failures.Count
    Failures = @($failures)
    OverallPass = [bool]((-not $internetReachable) -and $localPass.Count -gt 0)
    Privacy = 'No prompts/responses or document content persisted; only endpoint reachability, provider/model name, status and pass/fail evidence are stored.'
}

$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$report | ConvertTo-Json -Depth 8

if (-not $report.OverallPass) { exit 1 }
exit 0
