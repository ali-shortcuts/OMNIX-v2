# OMNIX Office tool request-scope runtime acceptance
#
# Deterministic test of the compiled OMNIX.Core ToolExecutor. No Office installation, network,
# provider account or user document is required. A fake IHostAdapter records every attempted read,
# preview and mutation.
#
# Proves:
# - a pre-cancelled request cannot touch Office read APIs;
# - an invalid document scope cannot touch Office read APIs;
# - cancellation after an approved preview still blocks ApplyWrite;
# - scope loss after an approved preview still blocks ApplyWrite;
# - cancellation is propagated as cancellation, never downgraded to a model-visible TOOL ERROR;
# - a valid confirmed write continues to apply exactly once.

[CmdletBinding()]
param(
    [string]$CorePath = ".\src\OMNIX.Core\bin\Release\OMNIX.Core.dll",
    [string]$OutputPath = ".\build\artifact\tool-request-isolation-acceptance.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$core = (Resolve-Path -LiteralPath $CorePath -ErrorAction Stop).Path
$coreDir = Split-Path -Parent $core
$newtonsoft = Join-Path $coreDir 'Newtonsoft.Json.dll'
if (Test-Path -LiteralPath $newtonsoft) {
    [void][Reflection.Assembly]::LoadFrom($newtonsoft)
}
[void][Reflection.Assembly]::LoadFrom($core)

$source = @'
using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using OMNIX.Core.Context;
using OMNIX.Core.Tools;

public sealed class ToolIsolationFakeHost : IHostAdapter
{
    public HostType Host { get { return HostType.Excel; } }
    public string HostDisplayName { get { return "Fake Excel"; } }

    public int ReadSelectionCount { get; private set; }
    public int ReadDocumentCount { get; private set; }
    public int PrepareWriteCount { get; private set; }
    public int ApplyWriteCount { get; private set; }

    public OfficeContext ReadContext() { return null; }

    public string ReadSelection()
    {
        ReadSelectionCount++;
        return "selection";
    }

    public string ReadDocument(int maxChars)
    {
        ReadDocumentCount++;
        return "document";
    }

    public byte[] CaptureChartAsImage(string chartName) { return null; }
    public byte[] CaptureSlideAsImage(int slideIndexOneBased) { return null; }
    public byte[] CaptureCurrentViewAsImage() { return null; }

    public WritePreview PrepareWrite(string toolName, string argumentsJson)
    {
        PrepareWriteCount++;
        return new WritePreview
        {
            ToolName = toolName,
            Title = "test preview",
            Before = "old",
            After = "new",
            ArgumentsJson = argumentsJson
        };
    }

    public void ApplyWrite(string toolName, string argumentsJson)
    {
        ApplyWriteCount++;
    }
}

public sealed class ToolIsolationAcceptanceResult
{
    public string TestId { get; set; }
    public int EvidenceSchema { get; set; }
    public bool PreCancelledReadBlocked { get; set; }
    public bool InvalidScopeReadBlocked { get; set; }
    public bool CancelAfterApprovalBlockedWrite { get; set; }
    public bool ScopeLossAfterApprovalBlockedWrite { get; set; }
    public bool CancellationPropagated { get; set; }
    public bool ValidApprovedWritePass { get; set; }
    public int FailureCount { get; set; }
    public List<string> Failures { get; set; }
    public bool OverallPass { get; set; }
}

public static class ToolIsolationAcceptanceHarness
{
    private static ToolCall ReadCall()
    {
        return new ToolCall { Name = ToolNames.ReadSelection, ArgumentsJson = "{}" };
    }

    private static ToolCall WriteCall()
    {
        return new ToolCall
        {
            Name = ToolNames.WriteToCell,
            ArgumentsJson = "{\"address\":\"A1\",\"value\":\"safe\"}"
        };
    }

    private static bool ExpectCancelled(Func<Task<ToolResult>> action)
    {
        try
        {
            action().GetAwaiter().GetResult();
            return false;
        }
        catch (OperationCanceledException)
        {
            return true;
        }
    }

    public static ToolIsolationAcceptanceResult Run()
    {
        var failures = new List<string>();
        var result = new ToolIsolationAcceptanceResult
        {
            TestId = "TOOL-REQUEST-ISOLATION-RUNTIME-001",
            EvidenceSchema = 1,
            Failures = failures
        };

        // 1. A request that is already cancelled must not cross the Office adapter boundary.
        var cancelledHost = new ToolIsolationFakeHost();
        var cancelledCts = new CancellationTokenSource();
        cancelledCts.Cancel();
        var cancelledExecutor = new ToolExecutor
        {
            RequestCancellationTokenProvider = () => cancelledCts.Token,
            RequestScopeValidator = () => true
        };
        bool preCancelledRaised = ExpectCancelled(() => cancelledExecutor.ExecuteAsync(ReadCall(), cancelledHost));
        result.PreCancelledReadBlocked = preCancelledRaised && cancelledHost.ReadSelectionCount == 0;
        if (!result.PreCancelledReadBlocked)
            failures.Add("A pre-cancelled request touched the Office read adapter or failed to propagate cancellation.");

        // 2. Even with a live token, a document-scope mismatch must fail closed before COM/read access.
        var invalidScopeHost = new ToolIsolationFakeHost();
        var invalidScopeExecutor = new ToolExecutor
        {
            RequestCancellationTokenProvider = () => CancellationToken.None,
            RequestScopeValidator = () => false
        };
        bool invalidScopeRaised = ExpectCancelled(() => invalidScopeExecutor.ExecuteAsync(ReadCall(), invalidScopeHost));
        result.InvalidScopeReadBlocked = invalidScopeRaised && invalidScopeHost.ReadSelectionCount == 0;
        if (!result.InvalidScopeReadBlocked)
            failures.Add("An invalid document scope reached the Office read adapter.");

        // 3. Cancellation can happen while the user is looking at a write preview. Approval from
        // the old document must not be enough; ApplyWrite must re-check the request token.
        var cancelAfterPreviewHost = new ToolIsolationFakeHost();
        var previewCts = new CancellationTokenSource();
        var cancelAfterPreviewExecutor = new ToolExecutor
        {
            RequestCancellationTokenProvider = () => previewCts.Token,
            RequestScopeValidator = () => true
        };
        cancelAfterPreviewExecutor.WriteConfirmation = preview =>
        {
            previewCts.Cancel();
            return Task.FromResult(true);
        };
        bool cancelAfterPreviewRaised = ExpectCancelled(() => cancelAfterPreviewExecutor.ExecuteAsync(WriteCall(), cancelAfterPreviewHost));
        result.CancelAfterApprovalBlockedWrite =
            cancelAfterPreviewRaised &&
            cancelAfterPreviewHost.PrepareWriteCount == 1 &&
            cancelAfterPreviewHost.ApplyWriteCount == 0;
        if (!result.CancelAfterApprovalBlockedWrite)
            failures.Add("A cancelled request applied an Office write after preview approval.");

        // 4. The token may still be live while the active Office document identity changes. The
        // scope validator must independently block ApplyWrite after confirmation.
        var scopeLossHost = new ToolIsolationFakeHost();
        bool scopeValid = true;
        var scopeLossExecutor = new ToolExecutor
        {
            RequestCancellationTokenProvider = () => CancellationToken.None,
            RequestScopeValidator = () => scopeValid
        };
        scopeLossExecutor.WriteConfirmation = preview =>
        {
            scopeValid = false;
            return Task.FromResult(true);
        };
        bool scopeLossRaised = ExpectCancelled(() => scopeLossExecutor.ExecuteAsync(WriteCall(), scopeLossHost));
        result.ScopeLossAfterApprovalBlockedWrite =
            scopeLossRaised &&
            scopeLossHost.PrepareWriteCount == 1 &&
            scopeLossHost.ApplyWriteCount == 0;
        if (!result.ScopeLossAfterApprovalBlockedWrite)
            failures.Add("A stale document scope applied an Office write after preview approval.");

        result.CancellationPropagated =
            preCancelledRaised && invalidScopeRaised && cancelAfterPreviewRaised && scopeLossRaised;
        if (!result.CancellationPropagated)
            failures.Add("ToolExecutor converted at least one request-scope cancellation into a normal ToolResult.");

        // 5. The hardening must not break a normal, valid, explicitly-approved write.
        var validHost = new ToolIsolationFakeHost();
        var validExecutor = new ToolExecutor
        {
            RequestCancellationTokenProvider = () => CancellationToken.None,
            RequestScopeValidator = () => true,
            WriteConfirmation = preview => Task.FromResult(true)
        };
        ToolResult validResult = validExecutor.ExecuteAsync(WriteCall(), validHost).GetAwaiter().GetResult();
        result.ValidApprovedWritePass =
            validResult != null && validResult.Success &&
            validHost.PrepareWriteCount == 1 && validHost.ApplyWriteCount == 1;
        if (!result.ValidApprovedWritePass)
            failures.Add("A valid explicitly-approved write no longer applies exactly once.");

        cancelledCts.Dispose();
        previewCts.Dispose();

        result.FailureCount = failures.Count;
        result.OverallPass = failures.Count == 0;
        return result;
    }
}
'@

$refs = @($core)
if (Test-Path -LiteralPath $newtonsoft) { $refs += $newtonsoft }
Add-Type -TypeDefinition $source -Language CSharp -ReferencedAssemblies $refs

$result = [ToolIsolationAcceptanceHarness]::Run()
$outDir = Split-Path -Parent $OutputPath
if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$result | ConvertTo-Json -Depth 8

if (-not $result.OverallPass) { exit 1 }
exit 0
