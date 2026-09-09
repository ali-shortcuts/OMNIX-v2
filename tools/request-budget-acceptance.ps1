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

# Use a compiled C# harness rather than PowerShell generic-list reflection. This exercises the exact
# public OMNIX.Core request types and avoids PowerShell type-resolution differences between local
# Windows and GitHub-hosted Windows PowerShell.
$source = @'
using System;
using System.Collections.Generic;
using System.Linq;
using OMNIX.Core.AiGateway;
using OMNIX.Core.Settings;
using OMNIX.Core.Storage;

public sealed class RequestBudgetAcceptanceResult
{
    public string TestId { get; set; }
    public int EvidenceSchema { get; set; }
    public string GeneratedUtc { get; set; }
    public bool HistoryTurnCapPass { get; set; }
    public bool HistoryCharCapPass { get; set; }
    public bool HistoricalImagesRemovedPass { get; set; }
    public bool HistoricalImageMarkerPass { get; set; }
    public bool CurrentImagePreservedPass { get; set; }
    public bool SystemPromptCapPass { get; set; }
    public bool SourceRequestNotMutatedPass { get; set; }
    public bool OversizedCurrentTextRejectedPass { get; set; }
    public bool TooManyCurrentImagesRejectedPass { get; set; }
    public int FailureCount { get; set; }
    public List<string> Failures { get; set; }
    public bool OverallPass { get; set; }
    public string Privacy { get; set; }
}

public static class RequestBudgetAcceptanceHarness
{
    private static ChatTurn Turn(ChatRole role, string text)
    {
        return new ChatTurn { Role = role, Text = text, TimestampUtc = DateTime.UtcNow };
    }

    private static ImageAttachment Image(int bytes, string name)
    {
        return new ImageAttachment
        {
            FileName = name,
            SourceLabel = "request-budget-acceptance",
            PngBytes = new byte[bytes]
        };
    }

    public static RequestBudgetAcceptanceResult Run()
    {
        var failures = new List<string>();
        var result = new RequestBudgetAcceptanceResult
        {
            TestId = "REQUEST-BUDGET-RUNTIME-001",
            EvidenceSchema = 1,
            GeneratedUtc = DateTime.UtcNow.ToString("o"),
            Failures = failures,
            Privacy = "Aggregate booleans/counts only; no prompts, document content, API keys or image bytes are written."
        };

        var settings = SettingsManager.Instance.Settings;
        int oldHistoryMax = settings.HistoryMaxMessages;
        int oldContextTokens = settings.ContextMaxTokens;

        try
        {
            settings.HistoryMaxMessages = 500;
            settings.ContextMaxTokens = 10000;

            var history = new List<ChatTurn>();
            for (int i = 0; i < 150; i++)
            {
                var role = (i % 2 == 0) ? ChatRole.User : ChatRole.Assistant;
                var turn = Turn(role, "H" + i.ToString("D3") + ":" + new string('x', 2000));
                if (i == 149)
                    turn.Images = new List<ImageAttachment> { Image(32, "old-image.png") };
                history.Add(turn);
            }

            var current = Turn(ChatRole.User, "current request");
            current.Images = new List<ImageAttachment> { Image(1024, "current.png") };

            var request = new ChatRequest
            {
                SystemPrompt = new string('S', 40000),
                History = history,
                UserTurn = current
            };

            ChatRequest bounded = ChatRequestBudgeter.Apply(request);

            result.HistoryTurnCapPass = bounded.History != null && bounded.History.Count > 0 && bounded.History.Count <= 80;
            if (!result.HistoryTurnCapPass) failures.Add("History turn count exceeded the hard provider replay cap.");

            int historyChars = bounded.History == null ? 0 : bounded.History.Sum(t => (t != null && t.Text != null) ? t.Text.Length : 0);
            result.HistoryCharCapPass = historyChars <= (48 * 1024);
            if (!result.HistoryCharCapPass) failures.Add("History text exceeded the hard provider replay character cap.");

            bool historyHasBytes = false;
            bool markerFound = false;
            foreach (var turn in bounded.History ?? new List<ChatTurn>())
            {
                if ((turn.Text ?? string.Empty).IndexOf("earlier image was omitted from provider replay", StringComparison.Ordinal) >= 0)
                    markerFound = true;
                if (turn.Images == null) continue;
                foreach (var image in turn.Images)
                    if (image != null && image.PngBytes != null && image.PngBytes.Length > 0)
                        historyHasBytes = true;
            }
            result.HistoricalImagesRemovedPass = !historyHasBytes;
            result.HistoricalImageMarkerPass = markerFound;
            if (!result.HistoricalImagesRemovedPass) failures.Add("Historical image bytes survived provider replay budgeting.");
            if (!result.HistoricalImageMarkerPass) failures.Add("Historical image omission was not made explicit to the model.");

            result.CurrentImagePreservedPass = bounded.UserTurn != null && bounded.UserTurn.Images != null &&
                bounded.UserTurn.Images.Count == 1 && bounded.UserTurn.Images[0].PngBytes != null &&
                bounded.UserTurn.Images[0].PngBytes.Length == 1024;
            if (!result.CurrentImagePreservedPass) failures.Add("Current bounded image was not preserved.");

            result.SystemPromptCapPass = (bounded.SystemPrompt ?? string.Empty).Length <= (32 * 1024);
            if (!result.SystemPromptCapPass) failures.Add("System prompt exceeded the hard request cap.");

            result.SourceRequestNotMutatedPass = request.History.Count == 150 &&
                request.History[149].Images != null && request.History[149].Images[0].PngBytes.Length == 32 &&
                request.UserTurn.Images != null && request.UserTurn.Images[0].PngBytes.Length == 1024;
            if (!result.SourceRequestNotMutatedPass) failures.Add("Budgeting mutated source conversation/request objects.");

            try
            {
                ChatRequestBudgeter.Apply(new ChatRequest
                {
                    UserTurn = Turn(ChatRole.User, new string('z', (64 * 1024) + 1))
                });
                result.OversizedCurrentTextRejectedPass = false;
            }
            catch
            {
                result.OversizedCurrentTextRejectedPass = true;
            }
            if (!result.OversizedCurrentTextRejectedPass) failures.Add("Oversized current text was not rejected.");

            try
            {
                var five = Turn(ChatRole.User, "five images");
                five.Images = new List<ImageAttachment>
                {
                    Image(8,"1.png"), Image(8,"2.png"), Image(8,"3.png"), Image(8,"4.png"), Image(8,"5.png")
                };
                ChatRequestBudgeter.Apply(new ChatRequest { UserTurn = five });
                result.TooManyCurrentImagesRejectedPass = false;
            }
            catch
            {
                result.TooManyCurrentImagesRejectedPass = true;
            }
            if (!result.TooManyCurrentImagesRejectedPass) failures.Add("More than four current images were not rejected.");
        }
        finally
        {
            settings.HistoryMaxMessages = oldHistoryMax;
            settings.ContextMaxTokens = oldContextTokens;
        }

        result.FailureCount = failures.Count;
        result.OverallPass = failures.Count == 0;
        return result;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp -ReferencedAssemblies @($core) -ErrorAction Stop
$result = [RequestBudgetAcceptanceHarness]::Run()

$outDir = Split-Path -Parent $OutputPath
if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$result | ConvertTo-Json -Depth 8

if (-not $result.OverallPass) { exit 1 }
exit 0
