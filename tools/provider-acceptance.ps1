# OMNIX provider runtime acceptance harness
#
# Purpose:
#   Exercise the same provider protocols OMNIX depends on, using LIVE model discovery and a real
#   streaming chat round-trip. This is release evidence, not a claim that any provider is free,
#   permanently available, or guaranteed to keep the same models/quotas.
#
# Credentials are read ONLY from process environment variables so they do not appear on the
# command line, in this repository, or in generated reports:
#   OMNIX_GEMINI_API_KEY
#   OMNIX_GROQ_API_KEY
#   OMNIX_OPENROUTER_API_KEY
#   OMNIX_MISTRAL_API_KEY
#   OMNIX_HUGGINGFACE_API_KEY
#   OMNIX_CEREBRAS_API_KEY
#   OMNIX_CUSTOM_API_KEY              (optional)
#   OMNIX_CUSTOM_BASE_URL             (optional)
#
# Optional non-secret model overrides. If omitted, the harness selects from the live model list:
#   OMNIX_GEMINI_MODEL
#   OMNIX_GROQ_MODEL
#   OMNIX_OPENROUTER_MODEL
#   OMNIX_MISTRAL_MODEL
#   OMNIX_HUGGINGFACE_MODEL
#   OMNIX_CEREBRAS_MODEL
#   OMNIX_CUSTOM_MODEL
#
# Local providers need no secrets:
#   Ollama    http://localhost:11434
#   LM Studio http://localhost:1234/v1
#
# The report contains provider/model/status/error-category/stream timing only. It does NOT persist
# prompts, response bodies, Authorization headers, API keys, or Office document content.

[CmdletBinding()]
param(
    [string]$OutputPath = "$env:LOCALAPPDATA\OMNIX\logs\provider-acceptance.json",
    [int]$TimeoutSeconds = 45
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

$logDir = Split-Path -Parent $OutputPath
if ($logDir) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }

function New-HttpClient([int]$timeoutSeconds) {
    $handler = New-Object System.Net.Http.HttpClientHandler
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($timeoutSeconds)
    return $client
}

function Get-EnvValue([string]$name) {
    return [Environment]::GetEnvironmentVariable($name, 'Process')
}

function Get-EnvSecret([string]$name) {
    return Get-EnvValue $name
}

function Classify-HttpFailure([int]$status, [string]$provider, [string]$body) {
    if ($provider -eq 'OpenRouter' -and $body) {
        if ($body.IndexOf('guardrail', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $body.IndexOf('data policy', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $body.IndexOf('settings/privacy', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return 'PRIVACY_BLOCKED'
        }
    }

    switch ($status) {
        400 { return 'REQUEST_ERROR' }
        401 { return 'AUTH_ERROR' }
        403 { return 'AUTH_ERROR' }
        404 { return 'MODEL_ERROR' }
        408 { return 'TIMEOUT' }
        409 { return 'PROVIDER_ERROR' }
        422 { return 'REQUEST_ERROR' }
        429 { return 'RATE_LIMIT' }
        500 { return 'PROVIDER_ERROR' }
        502 { return 'PROVIDER_ERROR' }
        503 { return 'PROVIDER_ERROR' }
        504 { return 'TIMEOUT' }
        default { return 'PROVIDER_ERROR' }
    }
}

function Invoke-JsonHttp {
    param(
        [string]$Method,
        [string]$Url,
        [hashtable]$Headers,
        [object]$Body,
        [int]$Timeout = 30
    )

    $client = $null
    $request = $null
    $response = $null
    try {
        $client = New-HttpClient $Timeout
        $request = New-Object System.Net.Http.HttpRequestMessage
        $request.Method = New-Object System.Net.Http.HttpMethod($Method)
        $request.RequestUri = [Uri]$Url

        foreach ($name in @($Headers.Keys)) {
            [void]$request.Headers.TryAddWithoutValidation($name, [string]$Headers[$name])
        }

        if ($null -ne $Body) {
            $json = $Body | ConvertTo-Json -Depth 20 -Compress
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
    catch [System.Threading.Tasks.TaskCanceledException] {
        return [pscustomobject]@{ Status = 408; Success = $false; Body = ''; TransportError = 'TaskCanceledException' }
    }
    catch {
        return [pscustomobject]@{ Status = 0; Success = $false; Body = ''; TransportError = $_.Exception.GetType().Name }
    }
    finally {
        if ($response) { $response.Dispose() }
        if ($request) { $request.Dispose() }
        if ($client) { $client.Dispose() }
    }
}

function Invoke-StreamingHttp {
    param(
        [string]$Url,
        [hashtable]$Headers,
        [object]$Body,
        [ValidateSet('SSE','NDJSON')]
        [string]$Mode = 'SSE',
        [int]$Timeout = 45
    )

    $client = $null
    $request = $null
    $response = $null
    $stream = $null
    $reader = $null
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $eventCount = 0
    $firstEventMs = $null
    $failureBody = ''

    try {
        $client = New-HttpClient $Timeout
        $request = New-Object System.Net.Http.HttpRequestMessage
        $request.Method = [System.Net.Http.HttpMethod]::Post
        $request.RequestUri = [Uri]$Url
        foreach ($name in @($Headers.Keys)) {
            [void]$request.Headers.TryAddWithoutValidation($name, [string]$Headers[$name])
        }

        $json = $Body | ConvertTo-Json -Depth 20 -Compress
        $request.Content = New-Object System.Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')

        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            $failureBody = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            return [pscustomobject]@{
                Status = [int]$response.StatusCode
                Success = $false
                StreamingPass = $false
                EventCount = 0
                FirstEventMs = $null
                Body = $failureBody
                TransportError = $null
            }
        }

        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $reader = New-Object System.IO.StreamReader($stream)

        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            $isEvent = $false
            if ($Mode -eq 'SSE') {
                $isEvent = $line.StartsWith('data:', [StringComparison]::OrdinalIgnoreCase)
            } else {
                try {
                    $null = $line | ConvertFrom-Json
                    $isEvent = $true
                } catch {
                    $isEvent = $false
                }
            }

            if ($isEvent) {
                $eventCount++
                if ($null -eq $firstEventMs) { $firstEventMs = [int]$watch.ElapsedMilliseconds }
            }
        }

        return [pscustomobject]@{
            Status = [int]$response.StatusCode
            Success = $true
            StreamingPass = [bool]($eventCount -gt 0 -and $null -ne $firstEventMs)
            EventCount = $eventCount
            FirstEventMs = $firstEventMs
            Body = ''
            TransportError = $null
        }
    }
    catch [System.Threading.Tasks.TaskCanceledException] {
        return [pscustomobject]@{
            Status = 408; Success = $false; StreamingPass = $false; EventCount = $eventCount
            FirstEventMs = $firstEventMs; Body = ''; TransportError = 'TaskCanceledException'
        }
    }
    catch {
        return [pscustomobject]@{
            Status = 0; Success = $false; StreamingPass = $false; EventCount = $eventCount
            FirstEventMs = $firstEventMs; Body = ''; TransportError = $_.Exception.GetType().Name
        }
    }
    finally {
        $watch.Stop()
        if ($reader) { $reader.Dispose() }
        elseif ($stream) { $stream.Dispose() }
        if ($response) { $response.Dispose() }
        if ($request) { $request.Dispose() }
        if ($client) { $client.Dispose() }
    }
}

function Get-OpenAiModelIds([string]$body) {
    try {
        $parsed = $body | ConvertFrom-Json
        return @($parsed.data | ForEach-Object { [string]$_.id } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    } catch {
        return @()
    }
}

function Select-LiveModel {
    param(
        [string[]]$Ids,
        [string]$ExplicitModel,
        [string[]]$PreferredExact = @(),
        [string[]]$PreferredSuffix = @(),
        [string[]]$PreferredContains = @()
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitModel)) {
        $match = @($Ids | Where-Object { $_ -eq $ExplicitModel }) | Select-Object -First 1
        if ($match) { return [string]$match }
    }

    foreach ($wanted in $PreferredExact) {
        $match = @($Ids | Where-Object { $_ -eq $wanted }) | Select-Object -First 1
        if ($match) { return [string]$match }
    }
    foreach ($suffix in $PreferredSuffix) {
        $match = @($Ids | Where-Object { $_.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
        if ($match) { return [string]$match }
    }
    foreach ($fragment in $PreferredContains) {
        $match = @($Ids | Where-Object { $_.IndexOf($fragment, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) | Select-Object -First 1
        if ($match) { return [string]$match }
    }

    return @($Ids | Select-Object -First 1)[0]
}

function New-SkippedResult([string]$name, [string]$status) {
    return [pscustomobject]@{
        Provider=$name; Configured=$false; Model=$null; ModelSource=$null
        ModelsPass=$false; ChatPass=$false; StreamingPass=$false; StreamEventCount=0
        FirstStreamEventMs=$null; FreeRoutePreferencePass=$null; Pass=$false
        Status=$status; ErrorCategory=$null
    }
}

function Test-OpenAiProvider {
    param(
        [string]$Name,
        [string]$BaseUrl,
        [string]$ApiKey,
        [bool]$RequiresKey,
        [string]$ExplicitModel,
        [hashtable]$ExtraHeaders = @{},
        [string[]]$PreferredExact = @(),
        [string[]]$PreferredSuffix = @(),
        [string[]]$PreferredContains = @()
    )

    $configured = (-not $RequiresKey) -or (-not [string]::IsNullOrWhiteSpace($ApiKey))
    if (-not $configured) { return New-SkippedResult $Name 'SKIPPED_NO_KEY' }

    $headers = @{}
    foreach ($k in $ExtraHeaders.Keys) { $headers[$k] = $ExtraHeaders[$k] }
    if (-not [string]::IsNullOrWhiteSpace($ApiKey)) { $headers['Authorization'] = 'Bearer ' + $ApiKey }

    $models = Invoke-JsonHttp -Method 'GET' -Url ($BaseUrl.TrimEnd('/') + '/models') -Headers $headers -Body $null -Timeout $TimeoutSeconds
    if (-not $models.Success) {
        $category = if ($models.Status -eq 0) { 'NETWORK_ERROR' } else { Classify-HttpFailure $models.Status $Name $models.Body }
        return [pscustomobject]@{
            Provider=$Name; Configured=$true; Model=$null; ModelSource='live:/models'
            ModelsPass=$false; ChatPass=$false; StreamingPass=$false; StreamEventCount=0
            FirstStreamEventMs=$null; FreeRoutePreferencePass=$null; Pass=$false
            Status=$models.Status; ErrorCategory=$category
        }
    }

    $ids = @(Get-OpenAiModelIds $models.Body)
    $model = Select-LiveModel -Ids $ids -ExplicitModel $ExplicitModel -PreferredExact $PreferredExact -PreferredSuffix $PreferredSuffix -PreferredContains $PreferredContains
    if ([string]::IsNullOrWhiteSpace($model)) {
        return [pscustomobject]@{
            Provider=$Name; Configured=$true; Model=$null; ModelSource='live:/models'
            ModelsPass=$false; ChatPass=$false; StreamingPass=$false; StreamEventCount=0
            FirstStreamEventMs=$null; FreeRoutePreferencePass=$null; Pass=$false
            Status='NO_COMPATIBLE_MODEL'; ErrorCategory='MODEL_ERROR'
        }
    }

    $body = @{
        model=$model
        messages=@(@{ role='user'; content='Reply with exactly READY.' })
        stream=$true
        max_tokens=32
    }
    $chat = Invoke-StreamingHttp -Url ($BaseUrl.TrimEnd('/') + '/chat/completions') -Headers $headers -Body $body -Mode 'SSE' -Timeout $TimeoutSeconds
    $category = $null
    if (-not $chat.Success) {
        $category = if ($chat.Status -eq 0) { 'NETWORK_ERROR' } else { Classify-HttpFailure $chat.Status $Name $chat.Body }
    } elseif (-not $chat.StreamingPass) {
        $category = 'STREAMING_ERROR'
    }

    $freePreference = $null
    if ($Name -eq 'OpenRouter') {
        $freePreference = [bool]($model -eq 'openrouter/free' -or $model.EndsWith(':free', [StringComparison]::OrdinalIgnoreCase))
    }

    return [pscustomobject]@{
        Provider=$Name; Configured=$true; Model=$model; ModelSource='live:/models'
        ModelsPass=$true; ChatPass=[bool]$chat.Success; StreamingPass=[bool]$chat.StreamingPass
        StreamEventCount=[int]$chat.EventCount; FirstStreamEventMs=$chat.FirstEventMs
        FreeRoutePreferencePass=$freePreference
        Pass=[bool]($chat.Success -and $chat.StreamingPass)
        Status=$chat.Status; ErrorCategory=$category
    }
}

function Test-GeminiProvider {
    $key = Get-EnvSecret 'OMNIX_GEMINI_API_KEY'
    if ([string]::IsNullOrWhiteSpace($key)) { return New-SkippedResult 'Gemini' 'SKIPPED_NO_KEY' }

    $headers = @{ 'x-goog-api-key' = $key }
    $models = Invoke-JsonHttp -Method 'GET' -Url 'https://generativelanguage.googleapis.com/v1beta/models' -Headers $headers -Body $null -Timeout $TimeoutSeconds
    if (-not $models.Success) {
        $category = if ($models.Status -eq 0) { 'NETWORK_ERROR' } else { Classify-HttpFailure $models.Status 'Gemini' $models.Body }
        return [pscustomobject]@{
            Provider='Gemini'; Configured=$true; Model=$null; ModelSource='live:/v1beta/models'
            ModelsPass=$false; ChatPass=$false; StreamingPass=$false; StreamEventCount=0
            FirstStreamEventMs=$null; FreeRoutePreferencePass=$null; Pass=$false
            Status=$models.Status; ErrorCategory=$category
        }
    }

    $ids = @()
    try {
        $parsed = $models.Body | ConvertFrom-Json
        foreach ($m in @($parsed.models)) {
            $methods = @($m.supportedGenerationMethods)
            if ($methods -contains 'generateContent') {
                $name = [string]$m.name
                if ($name.StartsWith('models/')) { $name = $name.Substring('models/'.Length) }
                if (-not [string]::IsNullOrWhiteSpace($name)) { $ids += $name }
            }
        }
    } catch { }

    $model = Select-LiveModel -Ids $ids -ExplicitModel (Get-EnvValue 'OMNIX_GEMINI_MODEL') -PreferredContains @('flash')
    if ([string]::IsNullOrWhiteSpace($model)) {
        return [pscustomobject]@{
            Provider='Gemini'; Configured=$true; Model=$null; ModelSource='live:/v1beta/models'
            ModelsPass=$false; ChatPass=$false; StreamingPass=$false; StreamEventCount=0
            FirstStreamEventMs=$null; FreeRoutePreferencePass=$null; Pass=$false
            Status='NO_COMPATIBLE_MODEL'; ErrorCategory='MODEL_ERROR'
        }
    }

    $body = @{ contents=@(@{ parts=@(@{ text='Reply with exactly READY.' }) }) }
    $url = 'https://generativelanguage.googleapis.com/v1beta/models/' + $model + ':streamGenerateContent?alt=sse'
    $chat = Invoke-StreamingHttp -Url $url -Headers $headers -Body $body -Mode 'SSE' -Timeout $TimeoutSeconds
    $category = $null
    if (-not $chat.Success) {
        $category = if ($chat.Status -eq 0) { 'NETWORK_ERROR' } else { Classify-HttpFailure $chat.Status 'Gemini' $chat.Body }
    } elseif (-not $chat.StreamingPass) {
        $category = 'STREAMING_ERROR'
    }

    return [pscustomobject]@{
        Provider='Gemini'; Configured=$true; Model=$model; ModelSource='live:/v1beta/models'
        ModelsPass=$true; ChatPass=[bool]$chat.Success; StreamingPass=[bool]$chat.StreamingPass
        StreamEventCount=[int]$chat.EventCount; FirstStreamEventMs=$chat.FirstEventMs
        FreeRoutePreferencePass=$null; Pass=[bool]($chat.Success -and $chat.StreamingPass)
        Status=$chat.Status; ErrorCategory=$category
    }
}

function Test-Ollama {
    $models = Invoke-JsonHttp -Method 'GET' -Url 'http://localhost:11434/api/tags' -Headers @{} -Body $null -Timeout 5
    if (-not $models.Success) { return New-SkippedResult 'Ollama' 'SKIPPED_NOT_RUNNING' }

    $ids = @()
    try {
        $parsed = $models.Body | ConvertFrom-Json
        $ids = @($parsed.models | ForEach-Object { [string]$_.name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    } catch { }
    $model = Select-LiveModel -Ids $ids -ExplicitModel ''
    if ([string]::IsNullOrWhiteSpace($model)) {
        return [pscustomobject]@{
            Provider='Ollama'; Configured=$true; Model=$null; ModelSource='live:/api/tags'
            ModelsPass=$false; ChatPass=$false; StreamingPass=$false; StreamEventCount=0
            FirstStreamEventMs=$null; FreeRoutePreferencePass=$null; Pass=$false
            Status='NO_LOCAL_MODEL'; ErrorCategory='MODEL_ERROR'
        }
    }

    $chat = Invoke-StreamingHttp -Url 'http://localhost:11434/api/chat' -Headers @{} -Body @{
        model=$model
        messages=@(@{role='user';content='Reply with exactly READY.'})
        stream=$true
    } -Mode 'NDJSON' -Timeout $TimeoutSeconds

    return [pscustomobject]@{
        Provider='Ollama'; Configured=$true; Model=$model; ModelSource='live:/api/tags'
        ModelsPass=$true; ChatPass=[bool]$chat.Success; StreamingPass=[bool]$chat.StreamingPass
        StreamEventCount=[int]$chat.EventCount; FirstStreamEventMs=$chat.FirstEventMs
        FreeRoutePreferencePass=$null; Pass=[bool]($chat.Success -and $chat.StreamingPass)
        Status=$chat.Status; ErrorCategory=$(if (-not $chat.Success) { 'PROVIDER_ERROR' } elseif (-not $chat.StreamingPass) { 'STREAMING_ERROR' } else { $null })
    }
}

$results = New-Object System.Collections.Generic.List[object]
$results.Add((Test-Ollama))
$results.Add((Test-OpenAiProvider -Name 'LM Studio' -BaseUrl 'http://localhost:1234/v1' -ApiKey '' -RequiresKey $false -ExplicitModel ''))
$results.Add((Test-GeminiProvider))
$results.Add((Test-OpenAiProvider -Name 'Groq' -BaseUrl 'https://api.groq.com/openai/v1' -ApiKey (Get-EnvSecret 'OMNIX_GROQ_API_KEY') -RequiresKey $true -ExplicitModel (Get-EnvValue 'OMNIX_GROQ_MODEL')))
$results.Add((Test-OpenAiProvider -Name 'OpenRouter' -BaseUrl 'https://openrouter.ai/api/v1' -ApiKey (Get-EnvSecret 'OMNIX_OPENROUTER_API_KEY') -RequiresKey $true -ExplicitModel (Get-EnvValue 'OMNIX_OPENROUTER_MODEL') -ExtraHeaders @{ 'X-Title'='OMNIX Provider Acceptance' } -PreferredExact @('openrouter/free') -PreferredSuffix @(':free')))
$results.Add((Test-OpenAiProvider -Name 'Mistral AI' -BaseUrl 'https://api.mistral.ai/v1' -ApiKey (Get-EnvSecret 'OMNIX_MISTRAL_API_KEY') -RequiresKey $true -ExplicitModel (Get-EnvValue 'OMNIX_MISTRAL_MODEL')))
$results.Add((Test-OpenAiProvider -Name 'Hugging Face' -BaseUrl 'https://router.huggingface.co/v1' -ApiKey (Get-EnvSecret 'OMNIX_HUGGINGFACE_API_KEY') -RequiresKey $true -ExplicitModel (Get-EnvValue 'OMNIX_HUGGINGFACE_MODEL')))
$results.Add((Test-OpenAiProvider -Name 'Cerebras' -BaseUrl 'https://api.cerebras.ai/v1' -ApiKey (Get-EnvSecret 'OMNIX_CEREBRAS_API_KEY') -RequiresKey $true -ExplicitModel (Get-EnvValue 'OMNIX_CEREBRAS_MODEL')))

$customBase = Get-EnvValue 'OMNIX_CUSTOM_BASE_URL'
if (-not [string]::IsNullOrWhiteSpace($customBase)) {
    $results.Add((Test-OpenAiProvider -Name 'Custom' -BaseUrl $customBase -ApiKey (Get-EnvSecret 'OMNIX_CUSTOM_API_KEY') -RequiresKey $false -ExplicitModel (Get-EnvValue 'OMNIX_CUSTOM_MODEL')))
} else {
    $results.Add((New-SkippedResult 'Custom' 'SKIPPED_NO_BASE_URL'))
}

$configured = @($results | Where-Object { $_.Configured })
$failedConfigured = @($configured | Where-Object { -not $_.Pass })

$report = [ordered]@{
    EvidenceSchema = 2
    TestId = 'PROVIDERS-RUNTIME-001'
    TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    ConfiguredProviderCount = $configured.Count
    FailedConfiguredProviderCount = $failedConfigured.Count
    StreamingConfiguredProviderCount = @($configured | Where-Object { $_.StreamingPass }).Count
    OverallPass = ($configured.Count -gt 0 -and $failedConfigured.Count -eq 0)
    Results = $results
    SecretHandling = 'API keys read from process environment only; keys, headers, prompts and response bodies are omitted from the report.'
}

$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$report | ConvertTo-Json -Depth 8

if ($failedConfigured.Count -gt 0) { exit 1 }
if ($configured.Count -eq 0) { exit 2 }
exit 0
