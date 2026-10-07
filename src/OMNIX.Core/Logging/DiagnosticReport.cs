using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Globalization;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using Newtonsoft.Json.Linq;
using OMNIX.Core.Errors;
using OMNIX.Core.Tools;

namespace OMNIX.Core.Logging
{
    // Export only known structural metadata. Never copy raw logs or arbitrary detail strings.
    public static class DiagnosticReport
    {
        private static readonly HashSet<string> Events = new HashSet<string>(new[] { "access_claim_repair","executor_dispatch","executor_reject","executor_result","host_context","mutation_repair","office_reveal","postcondition_error","postcondition_failed","preflight_complete","preflight_error","preflight_start","privacy_check","provider_call_end","provider_call_start","provider_guard","provider_response","provider_round","provider_selected","request_abort","request_complete","request_start","runtime_failure","task_resume","task_segment","tool_execute_end","tool_execute_start","tool_parsed","tool_protocol_reject","ui_dispatcher_gap","verification_repair","write_apply_end","write_apply_start","write_confirmation","write_policy","write_preview_end","write_preview_start","write_verification" }, StringComparer.Ordinal);
        private static readonly HashSet<string> Statuses = new HashSet<string>(new[] {
            "start","end","success","error","exception","omnix_error","failed","cancelled","selected",
            "verified","incomplete","blocked","allowed","shown","accepted","declined","write","read",
            "safe_stop","null","revalidated","resolved","no_verified_progress","request_failure",
            "final_text","native_tool_call","multiple_native_calls","malformed_arguments","not_whitelisted",
            "text_without_write","final_before_readback","unverified_access_claim","vision_not_supported",
            "circuit_open","handler_unavailable","cancelled_provider","provider_error","provider_exception",
            "empty_response","completed","text_only","budget_exhausted"
        }, StringComparer.Ordinal);
        public static JObject Analyze(IEnumerable<JObject> input)
        {
            var retained=new Queue<JObject>(); int ignored=0, evicted=0;
            foreach(var raw in input ?? Enumerable.Empty<JObject>())
            {
                var clean=Clean(raw); if(clean==null) {ignored++; continue;}
                retained.Enqueue(clean); if(retained.Count>5000) {retained.Dequeue(); evicted++;}
            }
            var requests=new JArray();
            var groups=retained.GroupBy(e => (string)e["traceId"]).ToList();
            int omitted=Math.Max(0,groups.Count-200);
            foreach(var group in groups.Skip(omitted))
            {
                var timeline=new JArray(group.Select(e=>e.DeepClone()));
                var findings=new JArray(); var pending=new Dictionary<string,JObject>();
                bool started=false, terminal=false;
                foreach(var e in group)
                {
                    string name=(string)e["event"], tool=(string)e["tool"]??"", status=(string)e["status"];
                    if(name=="request_start") started=true;
                    if(name=="request_complete" || name=="request_abort") terminal=true;
                    if(name!="request_start" && name.EndsWith("_start",StringComparison.Ordinal)) pending[name+"|"+tool]=e;
                    if(name.EndsWith("_end",StringComparison.Ordinal)) pending.Remove(name.Substring(0,name.Length-4)+"_start|"+tool);
                    if(name=="executor_dispatch") pending["executor|"+tool]=e;
                    if(name=="executor_result") pending.Remove("executor|"+tool);
                    string code=null;
                    if(e["errorCode"]!=null || new[]{"error","exception","omnix_error","failed","blocked"}.Contains(status)) code="recorded_failure";
                    else if(name=="ui_dispatcher_gap") code="ui_delay_observed";
                    else if(name=="write_verification" && status=="incomplete") code="result_not_verified";
                    else if(name=="tool_protocol_reject") code="tool_protocol_rejected";
                    else if((long?)e["elapsedMs"]>=15000 && name!="request_complete" && name!="request_abort") code="long_stage_observed";
                    if(code!=null && findings.Count<64) findings.Add(Finding(code,e,"observed"));
                }
                if(started && !terminal)
                {
                    if(findings.Count<64) findings.Add(Finding("request_without_terminal_event",group.Last(),"incomplete_evidence"));
                    foreach(var e in pending.Values.Take(Math.Max(0,64-findings.Count))) findings.Add(Finding("stage_without_end_event",e,"incomplete_evidence"));
                }
                var request=new JObject(); request["traceId"]=group.Key;
                request["state"]=!started?"partial_trace":terminal?"terminal_event_recorded":"no_terminal_event";
                request["findings"]=findings; request["timeline"]=timeline; requests.Add(request);
            }
            var report=new JObject(); report["schema"]=1; report["generatedUtc"]=DateTime.UtcNow.ToString("o");
            report["coreVersion"]=typeof(DiagnosticReport).Assembly.GetName().Version.ToString();
            report["retainedEvents"]=retained.Count; report["ignoredEvents"]=ignored; report["evictedEvents"]=evicted; report["omittedTraces"]=omitted;
            report["limitations"]="A missing end event may mean an active request, log rotation, interruption or crash; it does not prove a root cause. Timing thresholds are diagnostic heuristics. No document, prompt, endpoint, model ID, raw exception or credential content is exported.";
            report["requests"]=requests; return report;
        }
        private static JObject Finding(string code,JObject e,string evidence)
        {
            var o=new JObject();o["code"]=code;o["evidence"]=evidence;o["event"]=e["event"];
            foreach(string key in new[]{"tool","tsUtc","elapsedMs","errorCode","processId","hresult"}) if(e[key]!=null) o[key]=e[key].DeepClone();
            return o;
        }
        private static JObject Clean(JObject raw)
        {
            if(raw==null || raw["event"]==null || raw["event"].Type!=JTokenType.String || !Events.Contains((string)raw["event"])) return null;
            string trace=raw["traceId"]!=null && raw["traceId"].Type==JTokenType.String?(string)raw["traceId"]:null;
            if(trace!="no-trace" && (trace==null || !Regex.IsMatch(trace,"\\A[0-9a-f]{16}\\z"))) return null;
            var e=new JObject();e["traceId"]=trace;e["event"]=raw["event"].DeepClone();
            DateTime stamp;
            if(raw["tsUtc"]!=null && raw["tsUtc"].Type==JTokenType.String && DateTime.TryParse((string)raw["tsUtc"],CultureInfo.InvariantCulture,DateTimeStyles.RoundtripKind,out stamp)) e["tsUtc"]=stamp.ToUniversalTime().ToString("o");
            foreach(string key in new[]{"elapsedMs","thread","processId"})
            {
                long n;
                if(raw[key]!=null && raw[key].Type==JTokenType.Integer && long.TryParse(raw[key].ToString(),out n) && n>=0) e[key]=n;
            }
            if(raw["host"]!=null && raw["host"].Type==JTokenType.String && new[]{"Excel","Word","PowerPoint"}.Contains((string)raw["host"])) e["host"]=raw["host"].DeepClone();
            if(raw["tool"]!=null && raw["tool"].Type==JTokenType.String && (ToolNames.IsWhitelisted((string)raw["tool"]) || new[]{"cell_value","formula","heading","table","no_errors","format","text","paragraph_style","table_count","table_content","paragraph_format","slide_count","shape_bounds","text_alignment"}.Contains((string)raw["tool"]))) e["tool"]=raw["tool"].DeepClone();
            if(raw["status"]!=null && raw["status"].Type==JTokenType.String && Statuses.Contains((string)raw["status"])) e["status"]=raw["status"].DeepClone();
            int hr;
            if(raw["hresult"]!=null && raw["hresult"].Type==JTokenType.Integer && int.TryParse(raw["hresult"].ToString(),out hr)) e["hresult"]=hr;
            ErrorCode error;
            if(raw["errorCode"]!=null && raw["errorCode"].Type==JTokenType.String && Enum.TryParse((string)raw["errorCode"],out error) && Enum.IsDefined(typeof(ErrorCode),error)) e["errorCode"]=error.ToString();
            return e;
        }
        public static JObject Collect()
        {
            int malformed=0, skippedFiles=0, dropped=0; var rows=new List<JObject>();
            foreach(string name in new[]{"runtime-events.jsonl.1","runtime-events.jsonl"})
            {
                string path=Path.Combine(Logger.LogsDir,name); if(!File.Exists(path)) continue;
                try
                {
                    using(var file=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))
                    {
                        if(file.Length>6L*1024*1024) {skippedFiles++;continue;}
                        using(var reader=new StreamReader(file))
                        {
                            int lines=0; string line;
                            while((line=reader.ReadLine())!=null && lines++<20000)
                            {
                                if(line.Length>8192) {malformed++;continue;}
                                try { var row=Clean(JObject.Parse(line));if(row!=null) rows.Add(row);else malformed++; }
                                catch {malformed++;}
                                if(rows.Count>5000) {rows.RemoveRange(0,1000);dropped+=1000;}
                            }
                            if(lines>20000) skippedFiles++;
                        }
                    }
                }
                catch(IOException) {skippedFiles++;}
                catch(UnauthorizedAccessException) {skippedFiles++;}
            }
            var report=Analyze(rows); report["unreadableOrTruncatedFiles"]=skippedFiles;report["malformedOrUnknownLines"]=malformed;report["discardedOlderEvents"]=dropped;
            try {
                using(var binary=File.OpenRead(typeof(DiagnosticReport).Assembly.Location))
                using(var sha=SHA256.Create()) report["currentCoreSha256"]=BitConverter.ToString(sha.ComputeHash(binary)).Replace("-","").ToLowerInvariant();
            } catch { report["currentCoreFingerprintUnavailable"]=true; }
            return report;
        }
    }
}
