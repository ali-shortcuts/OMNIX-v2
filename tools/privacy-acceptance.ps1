# OMNIX AI Gateway privacy runtime acceptance
#
# This is a deterministic runtime test of the REAL OMNIX.Core AiGateway/PrivacyGate with in-memory
# fake provider adapters. It never contacts the Internet, never changes firewall/network settings,
# never saves settings, and never touches Office documents.
#
# It proves at runtime that:
# - LocalOnly blocks every built-in cloud provider route before provider SendAsync;
# - AskBeforeSending denial prevents SendAsync;
# - AskBeforeSending approval occurs before SendAsync;
# - "remember for session" suppresses repeat confirmation only inside that gateway session;
# - CloudAllowed does not invoke the confirmation callback;
# - LocalOnly can still route to an explicitly available local provider.

[CmdletBinding()]
param(
    [string]$CorePath = ".\src\OMNIX.Core\bin\Release\OMNIX.Core.dll",
    [string]$OutputPath = ".\build\artifact\privacy-acceptance.json"
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
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OMNIX.Core.AiGateway;
using OMNIX.Core.Errors;
using OMNIX.Core.Settings;
using OMNIX.Core.Storage;

public sealed class PrivacyFakeAdapter : IProviderAdapter
{
    public ProviderInfo Info { get; private set; }
    public int ConfigureCount { get; private set; }
    public int SendCount { get; private set; }
    public List<string> Events { get; private set; }

    public PrivacyFakeAdapter(string id, ProviderKind kind)
    {
        Info = new ProviderInfo
        {
            Id = id,
            DisplayName = id,
            Kind = kind,
            Vision = VisionSupport.Yes,
            DefaultModel = "privacy-test-model",
            RequiresApiKey = false,
            AccessProfile = kind == ProviderKind.Local ? ProviderAccessProfile.LocalNoCost : ProviderAccessProfile.Unknown
        };
        Events = new List<string>();
    }

    public void Reset()
    {
        ConfigureCount = 0;
        SendCount = 0;
        Events.Clear();
    }

    public void Record(string value) { Events.Add(value); }

    public void Configure(ProviderCredentials credentials)
    {
        ConfigureCount++;
        Events.Add("CONFIGURE");
    }

    public Task<IReadOnlyList<string>> ListModelsAsync(CancellationToken ct)
    {
        IReadOnlyList<string> result = new List<string> { "privacy-test-model" };
        return Task.FromResult(result);
    }

    public Task<bool> TestConnectionAsync(CancellationToken ct)
    {
        return Task.FromResult(true);
    }

    public Task<ChatResponse> SendAsync(ChatRequest request, Action<string> onDelta, CancellationToken ct)
    {
        SendCount++;
        Events.Add("SEND");
        if (onDelta != null) onDelta("READY");
        return Task.FromResult(new ChatResponse { Text = "READY", Model = "privacy-test-model" });
    }

    public bool SupportsVisionNow() { return true; }
}

public sealed class PrivacyAcceptanceResult
{
    public string TestId { get; set; }
    public int EvidenceSchema { get; set; }
    public bool LocalOnlyAllCloudRoutesBlocked { get; set; }
    public int LocalOnlyCloudRoutesTested { get; set; }
    public bool LocalOnlyFakeCloudSendPrevented { get; set; }
    public bool AskDeniedBlockedBeforeSend { get; set; }
    public bool AskApprovedBeforeSend { get; set; }
    public bool AskRememberSessionPass { get; set; }
    public bool CloudAllowedNoPromptPass { get; set; }
    public bool LocalOnlyLocalRoutePass { get; set; }
    public int FailureCount { get; set; }
    public List<string> Failures { get; set; }
    public bool OverallPass { get; set; }
}

public static class PrivacyAcceptanceHarness
{
    private static ChatRequest Request()
    {
        return new ChatRequest
        {
            SystemPrompt = "privacy acceptance",
            History = new List<ChatTurn>(),
            UserTurn = new ChatTurn
            {
                Role = ChatRole.User,
                Text = "privacy acceptance",
                TimestampUtc = DateTime.UtcNow
            }
        };
    }

    private static bool IsPrivacyBlocked(Exception ex)
    {
        var om = ex as OmnixException;
        return om != null && om.Code == ErrorCode.PRIVACY_BLOCKED;
    }

    private static bool CallExpectPrivacyBlock(AiGateway gateway)
    {
        try
        {
            gateway.ChatAsync(Request(), null, null, null, CancellationToken.None).GetAwaiter().GetResult();
            return false;
        }
        catch (Exception ex)
        {
            return IsPrivacyBlocked(ex);
        }
    }

    private static bool CallExpectSuccess(AiGateway gateway)
    {
        try
        {
            var r = gateway.ChatAsync(Request(), null, null, null, CancellationToken.None).GetAwaiter().GetResult();
            return r != null && r.Text == "READY";
        }
        catch
        {
            return false;
        }
    }

    public static PrivacyAcceptanceResult Run()
    {
        var failures = new List<string>();
        var settings = SettingsManager.Instance.Settings;
        var oldPrivacy = settings.Privacy;
        var oldSelected = settings.SelectedProviderId;
        var oldPreferredLocal = settings.PreferredLocalProviderId;
        var oldPreferLocal = settings.PreferLocalWhenAvailable;
        var oldCustomBase = settings.CustomProvider == null ? null : settings.CustomProvider.BaseUrl;

        var result = new PrivacyAcceptanceResult
        {
            TestId = "PRIVACY-GATE-RUNTIME-001",
            EvidenceSchema = 1,
            Failures = failures
        };

        try
        {
            settings.PreferLocalWhenAvailable = false;
            if (settings.CustomProvider != null)
                settings.CustomProvider.BaseUrl = "https://privacy-test.invalid/v1";

            var registry = new ProviderRegistry();
            var mutable = registry.All as IList<IProviderAdapter>;
            if (mutable == null) throw new InvalidOperationException("Provider registry is not mutable for isolated acceptance instrumentation.");

            var fakeCloud = new PrivacyFakeAdapter("privacy-test-cloud", ProviderKind.Cloud);
            var fakeLocal = new PrivacyFakeAdapter("privacy-test-local", ProviderKind.Local);
            mutable.Add(fakeCloud);
            mutable.Add(fakeLocal);

            foreach (var local in registry.All.Where(p => p.Info.Kind == ProviderKind.Local))
                registry.SetLocalAvailability(local.Info.Id, false);

            // 1) LocalOnly: every built-in cloud route must be refused. Custom is tested as a
            // remote URL here, so it must also be refused; loopback Custom is intentionally local.
            settings.Privacy = PrivacyMode.LocalOnly;
            var cloudIds = registry.All
                .Where(p => p.Info.Kind == ProviderKind.Cloud && p.Info.Id != fakeCloud.Info.Id)
                .Select(p => p.Info.Id)
                .ToList();

            int blocked = 0;
            foreach (var id in cloudIds)
            {
                settings.SelectedProviderId = id;
                var gateway = new AiGateway(registry);
                if (CallExpectPrivacyBlock(gateway)) blocked++;
            }
            result.LocalOnlyCloudRoutesTested = cloudIds.Count;
            result.LocalOnlyAllCloudRoutesBlocked = cloudIds.Count >= 7 && blocked == cloudIds.Count;
            if (!result.LocalOnlyAllCloudRoutesBlocked)
                failures.Add("LocalOnly did not block every registered cloud provider route.");

            fakeCloud.Reset();
            settings.SelectedProviderId = fakeCloud.Info.Id;
            var localOnlyFakeGateway = new AiGateway(registry);
            bool fakeBlocked = CallExpectPrivacyBlock(localOnlyFakeGateway);
            result.LocalOnlyFakeCloudSendPrevented = fakeBlocked && fakeCloud.SendCount == 0;
            if (!result.LocalOnlyFakeCloudSendPrevented)
                failures.Add("LocalOnly allowed the instrumented cloud adapter SendAsync path.");

            // 2) AskBeforeSending denied: callback must run and SendAsync must remain untouched.
            fakeCloud.Reset();
            settings.Privacy = PrivacyMode.AskBeforeSending;
            settings.SelectedProviderId = fakeCloud.Info.Id;
            var denyGateway = new AiGateway(registry);
            int denyConfirmCount = 0;
            denyGateway.Privacy.CloudConfirmationCallback = name =>
            {
                denyConfirmCount++;
                fakeCloud.Record("CONFIRM_DENY");
                return Task.FromResult(Tuple.Create(false, false));
            };
            bool denyBlocked = CallExpectPrivacyBlock(denyGateway);
            result.AskDeniedBlockedBeforeSend = denyBlocked && denyConfirmCount == 1 && fakeCloud.SendCount == 0;
            if (!result.AskDeniedBlockedBeforeSend)
                failures.Add("AskBeforeSending denial did not stop SendAsync.");

            // 3) AskBeforeSending approved: confirmation must occur before the provider send.
            fakeCloud.Reset();
            var approveGateway = new AiGateway(registry);
            int approveConfirmCount = 0;
            approveGateway.Privacy.CloudConfirmationCallback = name =>
            {
                approveConfirmCount++;
                fakeCloud.Record("CONFIRM_APPROVE");
                return Task.FromResult(Tuple.Create(true, false));
            };
            bool approveSuccess = CallExpectSuccess(approveGateway);
            int confirmIndex = fakeCloud.Events.IndexOf("CONFIRM_APPROVE");
            int sendIndex = fakeCloud.Events.IndexOf("SEND");
            result.AskApprovedBeforeSend = approveSuccess && approveConfirmCount == 1 && fakeCloud.SendCount == 1 &&
                                           confirmIndex >= 0 && sendIndex > confirmIndex;
            if (!result.AskApprovedBeforeSend)
                failures.Add("AskBeforeSending approval was not observed before SendAsync.");

            // 4) Remember for this gateway session only: first request confirms, second request sends
            // without another callback. This proves the intended scoped session behavior.
            fakeCloud.Reset();
            var rememberGateway = new AiGateway(registry);
            int rememberConfirmCount = 0;
            rememberGateway.Privacy.CloudConfirmationCallback = name =>
            {
                rememberConfirmCount++;
                fakeCloud.Record("CONFIRM_REMEMBER");
                return Task.FromResult(Tuple.Create(true, true));
            };
            bool remember1 = CallExpectSuccess(rememberGateway);
            bool remember2 = CallExpectSuccess(rememberGateway);
            result.AskRememberSessionPass = remember1 && remember2 && rememberConfirmCount == 1 && fakeCloud.SendCount == 2;
            if (!result.AskRememberSessionPass)
                failures.Add("AskBeforeSending session approval behavior is incorrect.");

            // 5) CloudAllowed: no confirmation callback should be consulted.
            fakeCloud.Reset();
            settings.Privacy = PrivacyMode.CloudAllowed;
            var cloudAllowedGateway = new AiGateway(registry);
            int unexpectedPromptCount = 0;
            cloudAllowedGateway.Privacy.CloudConfirmationCallback = name =>
            {
                unexpectedPromptCount++;
                return Task.FromResult(Tuple.Create(false, false));
            };
            bool cloudAllowed = CallExpectSuccess(cloudAllowedGateway);
            result.CloudAllowedNoPromptPass = cloudAllowed && unexpectedPromptCount == 0 && fakeCloud.SendCount == 1;
            if (!result.CloudAllowedNoPromptPass)
                failures.Add("CloudAllowed unexpectedly invoked confirmation or failed to send.");

            // 6) LocalOnly must still permit a provider positively classified/marked as local.
            fakeCloud.Reset();
            fakeLocal.Reset();
            settings.Privacy = PrivacyMode.LocalOnly;
            settings.SelectedProviderId = fakeCloud.Info.Id;
            settings.PreferredLocalProviderId = fakeLocal.Info.Id;
            registry.SetLocalAvailability(fakeLocal.Info.Id, true);
            var localGateway = new AiGateway(registry);
            int localPromptCount = 0;
            localGateway.Privacy.CloudConfirmationCallback = name =>
            {
                localPromptCount++;
                return Task.FromResult(Tuple.Create(false, false));
            };
            bool localSuccess = CallExpectSuccess(localGateway);
            result.LocalOnlyLocalRoutePass = localSuccess && fakeLocal.SendCount == 1 && fakeCloud.SendCount == 0 && localPromptCount == 0;
            if (!result.LocalOnlyLocalRoutePass)
                failures.Add("LocalOnly did not correctly preserve an available local route.");
        }
        finally
        {
            settings.Privacy = oldPrivacy;
            settings.SelectedProviderId = oldSelected;
            settings.PreferredLocalProviderId = oldPreferredLocal;
            settings.PreferLocalWhenAvailable = oldPreferLocal;
            if (settings.CustomProvider != null) settings.CustomProvider.BaseUrl = oldCustomBase;
        }

        result.FailureCount = failures.Count;
        result.OverallPass = failures.Count == 0;
        return result;
    }
}
'@

# Windows PowerShell/Add-Type compiles against the .NET Framework OMNIX.Core assembly used by VSTO.
Add-Type -TypeDefinition $source -Language CSharp -ReferencedAssemblies @($core)

$result = [PrivacyAcceptanceHarness]::Run()
$outDir = Split-Path -Parent $OutputPath
if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$result | ConvertTo-Json -Depth 8

if (-not $result.OverallPass) { exit 1 }
exit 0
