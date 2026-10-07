# OMNIX runtime diagnostic journal acceptance
#
# Deterministic, offline test of the two new runtime logs. It proves correlation/timing events are
# emitted and that secret-like metadata is redacted. No provider call and no Office document is used.

[CmdletBinding()]
param(
    [string]$CorePath = ".\src\OMNIX.Core\bin\Release\OMNIX.Core.dll",
    [string]$OutputPath = ".\build\artifact\runtime-diagnostic-journal-acceptance.json"
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
using System.Linq;
using System.Reflection;
using Newtonsoft.Json.Linq;
using OMNIX.Core.Logging;

public sealed class RuntimeDiagnosticJournalResult
{
    public string TestId { get; set; }
    public int EvidenceSchema { get; set; }
    public string GeneratedUtc { get; set; }
    public bool HumanLogCreatedPass { get; set; }
    public bool StructuredLogCreatedPass { get; set; }
    public bool CorrelationPass { get; set; }
    public bool ToolTimingPass { get; set; }
    public bool SecretRedactionPass { get; set; }
    public bool NoPayloadContentPass { get; set; }
    public int FailureCount { get; set; }
    public List<string> Failures { get; set; }
    public bool OverallPass { get; set; }
    public string Privacy { get; set; }
}

public static class RuntimeDiagnosticJournalHarness
{
    public static RuntimeDiagnosticJournalResult Run()
    {
        var failures = new List<string>();
        var result = new RuntimeDiagnosticJournalResult
        {
            TestId = "RUNTIME-DIAGNOSTIC-JOURNAL-001",
            EvidenceSchema = 1,
            GeneratedUtc = DateTime.UtcNow.ToString("o"),
            Failures = failures,
            Privacy = "Evidence contains booleans/counts only. Injected secret markers, prompts, Office content and tool arguments are not emitted."
        };

        string temp = Path.Combine(Path.GetTempPath(), "omnix-journal-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temp);

        var field = typeof(Logger).GetField("_baseDir", BindingFlags.Static | BindingFlags.NonPublic);
        if (field == null) throw new InvalidOperationException("Logger._baseDir field not found.");
        field.SetValue(null, temp);

        string marker = "OMNIX_SECRET_" + Guid.NewGuid().ToString("N");
        string fakePrompt = "PROMPT_CONTENT_" + Guid.NewGuid().ToString("N");
        string fakeDocument = "DOCUMENT_CONTENT_" + Guid.NewGuid().ToString("N");

        RuntimeDiagnosticJournal.BeginRequest("Excel", true, fakePrompt.Length, 3, false);
        RuntimeDiagnosticJournal.SetProvider("custom", "test-model");
        RuntimeDiagnosticJournal.Event("tool_execute_start", "write_to_cell", "write", null, null,
            "api_key=" + marker + "; baseUrl=https://private.invalid/v1; safe=metadata");
        RuntimeDiagnosticJournal.Event("tool_execute_end", "write_to_cell", "success", 123, null,
            "successfulWrites=1; failedWrites=0");
        RuntimeDiagnosticJournal.CompleteRequest("success", 1, 0, true);

        string journeyPath = Path.Combine(temp, "logs", "runtime-journey.log");
        string jsonlPath = Path.Combine(temp, "logs", "runtime-events.jsonl");
        result.HumanLogCreatedPass = File.Exists(journeyPath) && new FileInfo(journeyPath).Length > 0;
        result.StructuredLogCreatedPass = File.Exists(jsonlPath) && new FileInfo(jsonlPath).Length > 0;
        if (!result.HumanLogCreatedPass) failures.Add("Human runtime journey log was not created.");
        if (!result.StructuredLogCreatedPass) failures.Add("Structured runtime JSONL log was not created.");

        string human = File.Exists(journeyPath) ? File.ReadAllText(journeyPath) : "";
        string raw = File.Exists(jsonlPath) ? File.ReadAllText(jsonlPath) : "";
        var events = new List<JObject>();
        if (File.Exists(jsonlPath))
        {
            foreach (string line in File.ReadAllLines(jsonlPath))
            {
                if (string.IsNullOrWhiteSpace(line)) continue;
                events.Add(JObject.Parse(line));
            }
        }

        var traceIds = events.Select(e => (string)e["traceId"]).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct().ToList();
        result.CorrelationPass = events.Count >= 5 && traceIds.Count == 1 &&
            events.Any(e => (string)e["event"] == "request_start") &&
            events.Any(e => (string)e["event"] == "request_complete");
        if (!result.CorrelationPass) failures.Add("Structured events did not preserve one request correlation id.");

        result.ToolTimingPass = events.Any(e =>
            (string)e["event"] == "tool_execute_end" &&
            (string)e["tool"] == "write_to_cell" &&
            (long?)e["elapsedMs"] == 123 &&
            (string)e["status"] == "success");
        if (!result.ToolTimingPass) failures.Add("Tool timing/status event was not emitted.");

        result.SecretRedactionPass =
            human.IndexOf(marker, StringComparison.Ordinal) < 0 &&
            raw.IndexOf(marker, StringComparison.Ordinal) < 0 &&
            human.IndexOf("private.invalid", StringComparison.OrdinalIgnoreCase) < 0 &&
            raw.IndexOf("private.invalid", StringComparison.OrdinalIgnoreCase) < 0;
        if (!result.SecretRedactionPass) failures.Add("Secret-like detail or private Base URL leaked into runtime diagnostics.");

        result.NoPayloadContentPass =
            human.IndexOf(fakePrompt, StringComparison.Ordinal) < 0 &&
            raw.IndexOf(fakePrompt, StringComparison.Ordinal) < 0 &&
            human.IndexOf(fakeDocument, StringComparison.Ordinal) < 0 &&
            raw.IndexOf(fakeDocument, StringComparison.Ordinal) < 0 &&
            raw.IndexOf("ArgumentsJson", StringComparison.OrdinalIgnoreCase) < 0;
        if (!result.NoPayloadContentPass) failures.Add("Prompt/document/tool-argument content leaked into runtime diagnostics.");

        // Production export: omit payload fields even when an input log is malicious/corrupt.
        var reportRows = new List<JObject>();
        foreach (string trace in new[]{"aaaaaaaaaaaaaaaa","bbbbbbbbbbbbbbbb","cccccccccccccccc"}) {
            var start=new JObject(); start["event"]="request_start";start["traceId"]=trace;
            start["detail"]=marker;start["provider"]=marker;start["model"]=marker;start["prompt"]=fakePrompt;
            reportRows.Add(start);
        }
        var errorEvent=new JObject();errorEvent["event"]="provider_call_end";errorEvent["traceId"]="aaaaaaaaaaaaaaaa";
        errorEvent["status"]="exception";errorEvent["hresult"]=-2147467259;errorEvent["elapsedMs"]=17000;
        reportRows.Add(errorEvent);
        var abort=new JObject();abort["event"]="request_abort";abort["traceId"]="aaaaaaaaaaaaaaaa";reportRows.Add(abort);
        var pending=new JObject();pending["event"]="write_apply_start";pending["traceId"]="bbbbbbbbbbbbbbbb";
        pending["tool"]="insert_formula";reportRows.Add(pending);
        var delay=new JObject();delay["event"]="ui_dispatcher_gap";delay["traceId"]="bbbbbbbbbbbbbbbb";
        delay["elapsedMs"]=2500;reportRows.Add(delay);
        var done=new JObject();done["event"]="request_complete";done["traceId"]="cccccccccccccccc";reportRows.Add(done);
        var unknown=new JObject();unknown["event"]=marker;unknown["traceId"]=marker;reportRows.Add(unknown);
        var diagnostic=DiagnosticReport.Analyze(reportRows);string export=diagnostic.ToString();
        var requests=(JArray)diagnostic["requests"];
        var findings=requests.SelectMany(r=>((JArray)r["findings"]).OfType<JObject>()).ToList();
        if(export.Contains(marker) || export.Contains(fakePrompt) || export.Contains("prompt") && export.Contains(fakePrompt)) failures.Add("Report exported secret or payload input.");
        if(!findings.Any(f=>(string)f["code"]=="recorded_failure" && (int?)f["hresult"]==-2147467259)) failures.Add("Report lost numeric native failure evidence.");
        if(!findings.Any(f=>(string)f["code"]=="ui_delay_observed")) failures.Add("Report lost dispatcher delay evidence.");
        if(!findings.Any(f=>(string)f["code"]=="stage_without_end_event" && (string)f["evidence"]=="incomplete_evidence")) failures.Add("Report lost incomplete-stage qualification.");
        var completed=requests.OfType<JObject>().Single(r=>(string)r["traceId"]=="cccccccccccccccc");
        if(((JArray)completed["findings"]).Count!=0) failures.Add("Completed request falsely diagnosed as incomplete.");
        var many=Enumerable.Range(0,5002).Select(i=>(JObject)done.DeepClone());
        var bounded=DiagnosticReport.Analyze(many);
        if((int)bounded["retainedEvents"]!=5000 || (int)bounded["evictedEvents"]!=2) failures.Add("Diagnostic report event limit failed.");
        RuntimeDiagnosticJournal.BeginRequest("Excel",true,0,0,false);
        RuntimeDiagnosticJournal.ExceptionEvent("write_apply_end","insert_formula","exception",123,new System.Runtime.InteropServices.COMException(marker,-2147467259));
        RuntimeDiagnosticJournal.AbandonRequest("provider_exception",null);
        File.AppendAllText(jsonlPath,"\nnot-json\n");
        var collected=DiagnosticReport.Collect();
        if(collected.ToString().Contains(marker) || (int)collected["malformedOrUnknownLines"]<1) failures.Add("Diagnostic collection failed closed-input sanitization.");

        result.FailureCount = failures.Count;
        result.OverallPass = failures.Count == 0;
        try { Directory.Delete(temp, true); } catch { }
        return result;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp -ReferencedAssemblies @($core, $newtonsoft) -ErrorAction Stop
$result = [RuntimeDiagnosticJournalHarness]::Run()

$outDir = Split-Path -Parent $OutputPath
if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$result | ConvertTo-Json -Depth 8

if (-not $result.OverallPass) { exit 1 }
exit 0
