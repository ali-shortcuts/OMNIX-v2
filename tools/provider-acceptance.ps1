# OMNIX provider runtime acceptance harness
#
# Purpose:
#   Exercise the provider endpoints used by OMNIX without ever printing API keys.
#   This is a release-validation helper, not an automatic claim that a provider is free,
#   available, or production-ready.
#
# Credentials are read ONLY from environment variables so they do not appear on the
# command line or in this repository:
#   OMNIX_GEMINI_API_KEY
#   OMNIX_GROQ_API_KEY
#   OMNIX_OPENROUTER_API_KEY
#   OMNIX_MISTRAL_API_KEY
#   OMNIX_HUGGINGFACE_API_KEY
#   OMNIX_CEREBRAS_API_KEY
#   OMNIX_CUSTOM_API_KEY              (optional)
#   OMNIX_CUSTOM_BASE_URL             (optional)
#   OMNIX_CUSTOM_MODEL                (optional)
#
# Local providers need no secrets:
#   Ollama    http://localhost:11434
#   LM Studio http://localhost:1234/v1
#
# The report contains provider/model/status/error-category only. It does NOT persist
# prompts, response bodies, Authorization headers, or API keys.

[CmdletBinding()]
param(
    [string]$OutputPath = "$env:LOCALAPPDATA\OMNIX\logs\provider-acceptance.json",
    [int]$TimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$logDir = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function New-HttpClient([int]$timeoutSeconds) {
    $handler = New-Object System.Net.Http.HttpClientHandler
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($timeoutSeconds)
    return $client
}

function Get-EnvSecret([string]$name) {
    return [Environment]::GetEnvironmentVariable($name, 'Process')
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
        401 { return 'AUTH_ERROR' }
        403 { return 'AUTH_ERROR' }
        404 { return 'MODEL_ERROR' }
        408 { return 'TIMEOUT' }
        429 { return 'RATE_LIMIT' }
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
            $json = $Body | ConvertTo-Json -Depth 16 -Compress
            $request.Content = New-Object System.Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')
        }

        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        return [pscustomobject]@{
            Status = [int]$response.StatusCode
            Success = [bool]$response.IsSuccessStatusCode
            Body = $text
        }
    }
    catch [System.Threading.Tasks.TaskCanceledException] {
        return [pscustomobject]@{ Status = 408; Success = $false; Body = '' }
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

function Test-OpenAiProvider {
    param(
        [string]$Name,
        [string]$BaseUrl,
        [string]$Model,
        [string]$ApiKey,
        [bool]$RequiresKey,
        [hashtable]$ExtraHeaders = @{}
    )

    $configured = (-not $RequiresKey) -or (-not [string]::IsNullOrWhiteSpace($ApiKey))
    if (-not $configured) {
        return [pscustomobject]@{
            Provider = $Name; Configured = $false; Model = $Model
            ModelsPass = $false; ChatPass = $false; Pass = $false
            Status = 'SKIPPED_NO_KEY'; ErrorCategory = $null
        }
    }

    $headers = @{}
    foreach ($k in $ExtraHeaders.Keys) { $headers[$k] = $ExtraHeaders[$k] }
    if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
        $headers['Authorization'] = 'Bearer ' + $ApiKey
    }

    $models = Invoke-JsonHttp -Method 'GET' -Url ($BaseUrl.TrimEnd('/') + '/models') -Headers $headers -Body $null -Timeout $TimeoutSeconds
    if (-not $models.Success) {
        $category = if ($models.Status -eq 0) { 'NETWORK_ERROR' } else { Classify-HttpFailure $models.Status $Name $models.Body }
        return [pscustomobject]@{
            Provider = $Name; Configured = $true; Model = $Model
            ModelsPass = $false; ChatPass = $false; Pass = $false
            Status = $models.Status; ErrorCategory = $category
        }
    }

    $body = @{
        model = $Model
        messages = @(@{ role = 'user'; content = 'Reply with exactly READY.' })
        stream = $false
        max_tokens = 32
    }
    $chat = Invoke-JsonHttp -Method 'POST' -Url ($BaseUrl.TrimEnd('/') + '/chat/completions') -Headers $headers -Body $body -Timeout $TimeoutSeconds
    $chatCategory = $null
    if (-not $chat.Success) {
        $chatCategory = if ($chat.Status -eq 0) { 'NETWORK_ERROR' } else { Classify-HttpFailure $chat.Status $Name $chat.Body }
    }

    return [pscustomobject]@{
        Provider = $Name; Configured = $true; Model = $Model
        ModelsPass = $true; ChatPass = [bool]$chat.Success; Pass = [bool]$chat.Success
        Status = $chat.Status; ErrorCategory = $chatCategory
    }
}

function Test-GeminiProvider {
    $key = Get-EnvSecret 'OMNIX_GEMINI_API_KEY'
    $model = 'gemini-3.8-flash'
    if ([string]::IsNullOrWhiteSpace($key)) {
        return [pscustomobject]@{
            Provider = 'Gemini'; Configured = $false; Model = $model
            ModelsPass = $false; ChatPass = $false; Pass = $false
            Status = 'SKIPPED_NO_KEY'; ErrorCategory = $null
        }
    }

    $headers = @{ 'x-goog-api-key' = $key }
    $models = Invoke-JsonHttp -Method 'GET' -Url 'https://generativelanguage.googleapis.com/v1beta/models' -Headers $headers -Body $null -Timeout $TimeoutSeconds
    if (-not $models.Success) {
        $category = if ($models.Status -eq 0) { 'NETWORK_ERROR' } else { Classify-HttpFailure $models.Status 'Gemini' $models.Body }
        return [pscustomobject]@{
            Provider = 'Gemini'; Configured = $true; Model = $model
            ModelsPass = $false; ChatPass = $false; Pass = $false
            Status = $models.Status; ErrorCategory = $category
        }
    }

    $body = @{ contents = @(@{ parts = @(@{ text = 'Reply with exactly READY.' }) }) }
    $chatUrl = 'https://generativelanguage.googleapis.com/v1beta/models/' + $model + ':generateContent'
    $chat = Invoke-JsonHttp -Method 'POST' -Url $chatUrl -Headers $headers -Body $body -Timeout $TimeoutSeconds
    $category = $null
    if (-not $chat.Success) {
        $category = if ($chat.Status -eq 0) { 'NETWORK_ERROR' } else { Classify-HttpFailure $chat.Status 'Gemini' $chat.Body }
    }

    return [pscustomobject]@{
        Provider = 'Gemini'; Configured = $true; Model = $model
        ModelsPass = $true; ChatPass = [bool]$chat.Success; Pass = [bool]$chat.Success
        Status = $chat.Status; ErrorCategory = $category
    }
}

function Test-Ollama {
    $models = Invoke-JsonHttp -Method 'GET' -Url 'http://localhost:11434/api/tags' -Headers @{} -Body $null -Timeout 5
    if (-not $models.Success) {
        return [pscustomobject]@{
            Provider = 'Ollama'; Configured = $false; Model = $null
            ModelsPass = $false; ChatPass = $false; Pass = $false
            Status = 'SKIPPED_NOT_RUNNING'; ErrorCategory = $null
        }
    }

    $model = $null
    try {
        $parsed = $models.Body | ConvertFrom-Json
        if ($parsed.models -and $parsed.models.Count -gt 0) { $model = [string]$parsed.models[0].name }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($model)) {
        return [pscustomobject]@{
            Provider = 'Ollama'; Configured = $true; Model = $null
            ModelsPass = $false; ChatPass = $false; Pass = $false
            Status = 'NO_LOCAL_MODEL'; ErrorCategory = 'MODEL_ERROR'
        }
    }

    $body = @{
        model = $model
        messages = @(@{ role = 'user'; content = 'Reply with exactly READY.' })
        stream = $false
    }
    $chat = Invoke-JsonHttp -Method 'POST' -Url 'http://localhost:11434/api/chat' -Headers @{} -Body $body -Timeout $TimeoutSeconds
    return [pscustomobject]@{
        Provider = 'Ollama'; Configured = $true; Model = $model
        ModelsPass = $true; ChatPass = [bool]$chat.Success; Pass = [bool]$chat.Success
        Status = $chat.Status; ErrorCategory = $(if ($chat.Success) { $null } else { 'PROVIDER_ERROR' })
    }
}

$results = New-Object System.Collections.Generic.List[object]
$results.Add((Test-Ollama))
$results.Add((Test-OpenAiProvider -Name 'LM Studio' -BaseUrl 'http://localhost:1234/v1' -Model 'local-model' -ApiKey '' -RequiresKey $false))
$results.Add((Test-GeminiProvider))
$results.Add((Test-OpenAiProvider -Name 'Groq' -BaseUrl 'https://api.groq.com/openai/v1' -Model 'openai/gpt-oss-120b' -ApiKey (Get-EnvSecret 'OMNIX_GROQ_API_KEY') -RequiresKey $true))
$results.Add((Test-OpenAiProvider -Name 'OpenRouter' -BaseUrl 'https://openrouter.ai/api/v1' -Model 'openrouter/free' -ApiKey (Get-EnvSecret 'OMNIX_OPENROUTER_API_KEY') -RequiresKey $true -ExtraHeaders @{ 'X-Title' = 'OMNIX Provider Acceptance' }))
$results.Add((Test-OpenAiProvider -Name 'Mistral AI' -BaseUrl 'https://api.mistral.ai/v1' -Model 'mistral-small-latest' -ApiKey (Get-EnvSecret 'OMNIX_MISTRAL_API_KEY') -RequiresKey $true))
$results.Add((Test-OpenAiProvider -Name 'Hugging Face' -BaseUrl 'https://router.huggingface.co/v1' -Model 'openai/gpt-oss-120b:fastest' -ApiKey (Get-EnvSecret 'OMNIX_HUGGINGFACE_API_KEY') -RequiresKey $true))
$results.Add((Test-OpenAiProvider -Name 'Cerebras' -BaseUrl 'https://api.cerebras.ai/v1' -Model 'gpt-oss-120b' -ApiKey (Get-EnvSecret 'OMNIX_CEREBRAS_API_KEY') -RequiresKey $true))

$customBase = [Environment]::GetEnvironmentVariable('OMNIX_CUSTOM_BASE_URL', 'Process')
if (-not [string]::IsNullOrWhiteSpace($customBase)) {
    $customModel = [Environment]::GetEnvironmentVariable('OMNIX_CUSTOM_MODEL', 'Process')
    if ([string]::IsNullOrWhiteSpace($customModel)) { $customModel = 'gpt-4o-mini' }
    $customKey = Get-EnvSecret 'OMNIX_CUSTOM_API_KEY'
    $results.Add((Test-OpenAiProvider -Name 'Custom' -BaseUrl $customBase -Model $customModel -ApiKey $customKey -RequiresKey $false))
} else {
    $results.Add([pscustomobject]@{
        Provider = 'Custom'; Configured = $false; Model = $null
        ModelsPass = $false; ChatPass = $false; Pass = $false
        Status = 'SKIPPED_NO_BASE_URL'; ErrorCategory = $null
    })
}

$configured = @($results | Where-Object { $_.Configured })
$failedConfigured = @($configured | Where-Object { -not $_.Pass })

$report = [ordered]@{
    TestId = 'PROVIDERS-RUNTIME-001'
    TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    Machine = $env:COMPUTERNAME
    PowerShell = $PSVersionTable.PSVersion.ToString()
    ConfiguredProviderCount = $configured.Count
    FailedConfiguredProviderCount = $failedConfigured.Count
    OverallPass = ($configured.Count -gt 0 -and $failedConfigured.Count -eq 0)
    Results = $results
    SecretHandling = 'API keys read from process environment only; keys/headers/response bodies omitted from report.'
}

$report | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputPath -Encoding UTF8
$report | ConvertTo-Json -Depth 8

if ($failedConfigured.Count -gt 0) { exit 1 }
if ($configured.Count -eq 0) { exit 2 }
exit 0
