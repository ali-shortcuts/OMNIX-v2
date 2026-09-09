# OMNIX provider-error redaction runtime acceptance
#
# Deterministic, offline test of the compiled HttpStatusMapper + OmnixException logging boundary.
# It injects unpredictable secret-like markers into fake provider response bodies and proves those
# markers do not enter TechnicalDetails, friendly messages or gateway logs. No network/provider call
# is made and no API key/document content is used.

[CmdletBinding()]
param(
    [string]$CorePath = ".\src\OMNIX.Core\bin\Release\OMNIX.Core.dll",
    [string]$OutputPath = ".\build\artifact\provider-error-redaction-acceptance.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$core = (Resolve-Path -LiteralPath $CorePath -ErrorAction Stop).Path
$coreDir = Split-Path -Parent $core
$newtonsoft = Join-Path $coreDir 'Newtonsoft.Json.dll'
if (Test-Path -LiteralPath $newtonsoft) { [void][Reflection.Assembly]::LoadFrom($newtonsoft) }
[void][Reflection.Assembly]::LoadFrom($core)

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using OMNIX.Core.AiGateway;
using OMNIX.Core.Errors;
using OMNIX.Core.Logging;

public sealed class ProviderErrorRedactionResult
{
    public string TestId { get; set; }
    public int EvidenceSchema { get; set; }
    public string GeneratedUtc { get; set; }
    public bool GenericBodyRedactedPass { get; set; }
    public bool AuthBodyRedactedPass { get; set; }
    public bool PrivacyClassificationPass { get; set; }
    public bool PrivacyBodyRedactedPass { get; set; }
    public bool ProviderNameSanitizedPass { get; set; }
    public bool GatewayLogRedactedPass { get; set; }
    public int FailureCount { get; set; }
    public List<string> Failures { get; set; }
    public bool OverallPass { get; set; }
    public string Privacy { get; set; }
}

public static class ProviderErrorRedactionHarness
{
    private static bool Contains(OmnixException ex, string marker)
    {
        if (ex == null) return true;
        return (ex.Message ?? string.Empty).IndexOf(marker, StringComparison.Ordinal) >= 0 ||
               (ex.TechnicalDetails ?? string.Empty).IndexOf(marker, StringComparison.Ordinal) >= 0 ||
               (ex.SuggestedFix ?? string.Empty).IndexOf(marker, StringComparison.Ordinal) >= 0;
    }

    public static ProviderErrorRedactionResult Run()
    {
        var failures = new List<string>();
        var result = new ProviderErrorRedactionResult
        {
            TestId = "PROVIDER-ERROR-REDACTION-RUNTIME-001",
            EvidenceSchema = 1,
            GeneratedUtc = DateTime.UtcNow.ToString("o"),
            Failures = failures,
            Privacy = "Only aggregate PASS/FAIL booleans are emitted; injected markers and fake provider bodies are never written to evidence."
        };

        string marker = "OMNIX_SECRET_" + Guid.NewGuid().ToString("N");
        string fakeBody = "{\"error\":{\"message\":\"" + marker + " echoed prompt text\",\"code\":\"quota\"}}";

        OmnixException generic = HttpStatusMapper.Map(429, fakeBody, "TestProvider");
        result.GenericBodyRedactedPass = !Contains(generic, marker) &&
            generic.Code == ErrorCode.PROVIDER_ERROR &&
            (generic.TechnicalDetails ?? string.Empty).IndexOf("provider_response_body=REDACTED", StringComparison.Ordinal) >= 0;
        if (!result.GenericBodyRedactedPass) failures.Add("Generic provider response body leaked into mapped diagnostics.");

        OmnixException auth = HttpStatusMapper.Map(401, fakeBody, "TestProvider");
        result.AuthBodyRedactedPass = !Contains(auth, marker) && auth.Code == ErrorCode.AUTH_ERROR;
        if (!result.AuthBodyRedactedPass) failures.Add("Authentication provider response body leaked into mapped diagnostics.");

        string privacyBody = "{\"error\":{\"message\":\"No endpoints available matching your guardrail restrictions and data policy " + marker +
            "\",\"help\":\"https://openrouter.ai/settings/privacy\"}}";
        OmnixException privacy = HttpStatusMapper.Map(403, privacyBody, "OpenRouter");
        result.PrivacyClassificationPass = privacy.Code == ErrorCode.PRIVACY_BLOCKED &&
            (privacy.TechnicalDetails ?? string.Empty).IndexOf("data_policy_no_eligible_endpoint", StringComparison.Ordinal) >= 0;
        result.PrivacyBodyRedactedPass = !Contains(privacy, marker);
        if (!result.PrivacyClassificationPass) failures.Add("OpenRouter privacy/data-policy failure was not categorized as PRIVACY_BLOCKED.");
        if (!result.PrivacyBodyRedactedPass) failures.Add("OpenRouter privacy provider body leaked into diagnostics.");

        OmnixException oddName = HttpStatusMapper.Map(500, fakeBody, "Bad\r\nProvider:<script>");
        string oddDetails = oddName.TechnicalDetails ?? string.Empty;
        result.ProviderNameSanitizedPass = oddDetails.IndexOf("\r", StringComparison.Ordinal) < 0 &&
            oddDetails.IndexOf("\n", StringComparison.Ordinal) < 0 &&
            oddDetails.IndexOf("<", StringComparison.Ordinal) < 0 &&
            oddDetails.IndexOf(">", StringComparison.Ordinal) < 0 &&
            !Contains(oddName, marker);
        if (!result.ProviderNameSanitizedPass) failures.Add("Provider name was not sanitized in diagnostics.");

        // Constructors above wrote category/friendly summaries to the real local gateway log. The
        // unpredictable fake-body marker must not appear anywhere in that log.
        string logPath = Path.Combine(Logger.LogsDir, "gateway-debug.log");
        string log = File.Exists(logPath) ? File.ReadAllText(logPath) : string.Empty;
        result.GatewayLogRedactedPass = log.IndexOf(marker, StringComparison.Ordinal) < 0;
        if (!result.GatewayLogRedactedPass) failures.Add("A raw provider-body marker reached the gateway log.");

        result.FailureCount = failures.Count;
        result.OverallPass = failures.Count == 0;
        return result;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp -ReferencedAssemblies @($core) -ErrorAction Stop
$result = [ProviderErrorRedactionHarness]::Run()

$outDir = Split-Path -Parent $OutputPath
if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$result | ConvertTo-Json -Depth 8

if (-not $result.OverallPass) { exit 1 }
exit 0
