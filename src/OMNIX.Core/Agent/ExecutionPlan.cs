using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using OMNIX.Core.Context;
using OMNIX.Core.Tools;

namespace OMNIX.Core.Agent
{
    public interface IPlanVerificationHost
    {
        // Null means passed. Implementations inspect native Office state on its owner thread.
        string CheckPostcondition(JObject check);
    }

    public interface IPlanTargetInspectionHost
    {
        // Read-only preflight on the owner thread; includes worksheet/chart-sheet name collisions.
        bool CreationTargetExists(string sheet);
    }

    public sealed class ExecutionPlan
    {
        private string _host;
        private JObject _plan;
        private readonly HashSet<string> _started = new HashSet<string>(StringComparer.Ordinal);
        private readonly HashSet<string> _applied = new HashSet<string>(StringComparer.Ordinal);
        private readonly HashSet<string> _passed = new HashSet<string>(StringComparer.Ordinal);
        private readonly Dictionary<string,int> _attempts = new Dictionary<string,int>(StringComparer.Ordinal);
        public string OriginalRequest { get; private set; }
        public bool Required { get; private set; }
        public int VerifiedStepCount { get { return _passed.Count; } }
        public bool Complete { get { return _plan != null && Steps.All(s => _passed.Contains((string)s["id"])); } }
        public string PreviousCheckpoint { get; set; }
        public Action<string> SaveCheckpoint { get; set; }
        private IEnumerable<JObject> Steps { get { return _plan == null ? Enumerable.Empty<JObject>() : ((JArray)_plan["steps"]).Cast<JObject>(); } }

        public void Begin(string request, bool required)
        {
            OriginalRequest = request ?? ""; Required = required; _plan = null; _host = null;
            _applied.Clear(); _started.Clear(); _passed.Clear(); _attempts.Clear();
        }

        public string Submit(string json, HostType host) { return Submit(json,host,null); }

        public string Submit(string json, HostType host, Func<string,bool> targetExists)
        {
            if (json == null || json.Length > 60000) throw new ArgumentException("Plan exceeds 60,000 characters.");
            var plan = JObject.Parse(json);
            var steps = plan["steps"] as JArray;
            bool append = (bool?)plan["append"] == true;
            if (append)
            {
                if (_plan == null || steps == null || steps.Count < 1 || steps.Count > 12)
                    throw new ArgumentException("Append requires an existing plan and 1–12 new steps.");
                var merged = new JArray(Steps.Select(s => s.DeepClone()));
                foreach (var step in steps) merged.Add(step.DeepClone());
                plan = new JObject { ["steps"] = merged }; steps = merged;
            }
            if (steps == null || steps.Count < 1 || steps.Count > (append ? 36 : _plan != null ? 36 : 12)) throw new ArgumentException("Initial plan requires 1–12 steps; append at most 12 per segment, 36 total.");
            var ids = new HashSet<string>(StringComparer.Ordinal);
            var destinations = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var token in steps)
            {
                var step = token as JObject;
                if (step == null) throw new ArgumentException("Each step must be an object.");
                string id = (string)step["id"], tool = (string)step["tool"];
                if (string.IsNullOrWhiteSpace(id) || id.Length > 40 || !ids.Add(id)) throw new ArgumentException("Step IDs must be unique, nonempty and at most 40 characters.");
                if (!ToolNames.IsWriteTool(tool) || !(step["args"] is JObject)) throw new ArgumentException("Step requires a real write tool and args object.");
                var checks = step["checks"] as JArray;
                if (checks == null || checks.Count < 1 || checks.Count > 12) throw new ArgumentException("Each step requires 1–12 native postconditions.");
                foreach (var c in checks) ValidateCheck(c as JObject, host);
                if(host==HostType.Word && tool==ToolNames.ExecuteOfficeCapability && (string)step["args"]["capability"]=="paragraph.write")
                    WordParagraphWriter.Validate(step["args"]["args"] as JObject);
                if (tool == ToolNames.CreateDataTable && (bool?)step["args"]["uniqueName"] == true)
                    throw new ArgumentException("Planned creation requires an exact, unused sheet name; automatic suffixes are not allowed.");
                if (tool == ToolNames.CreateDataTable && host == HostType.Excel)
                {
                    var table=ExcelTableBuilder.ValidatePlan(step["args"].ToString(Formatting.None));
                    string destination=(string)table["sheet"];
                    if(!destinations.Add(destination)) throw new ArgumentException("Two creation steps target the same worksheet. Repair one existing sheet rather than recreate it.");
                    if(targetExists!=null && !_applied.Contains(id) && !_started.Contains(id) && targetExists(destination))
                        throw new ArgumentException("Creation destination already exists: "+destination+". No new plan was accepted. Inspect and revise to edit the existing sheet.");
                }
            }
            string coverage = RequestCoverage.Validate(OriginalRequest, steps, host);
            if (coverage != null) throw new ArgumentException(coverage);
            // A model cannot erase already-executed goals or weaken checks to declare success.
            if (_plan != null && (_applied.Count > 0 || _started.Count > 0))
            {
                foreach (var old in Steps)
                {
                    var next = steps.OfType<JObject>().FirstOrDefault(s => (string)s["id"] == (string)old["id"]);
                    if (next == null || !JToken.DeepEquals(old["checks"], next["checks"]))
                        throw new ArgumentException("After execution starts, retain every step ID and its original postconditions. Repair the operation, not the acceptance criteria.");
                    if (_passed.Contains((string)old["id"]) && !JToken.DeepEquals(old, next))
                        throw new ArgumentException("Do not change an already verified step.");
                }
            }
            if (plan.ToString(Formatting.None).Length > 60000) throw new ArgumentException("Combined plan exceeds 60,000 characters.");
            _plan = plan;
            _host = host.ToString();
            Checkpoint();
            return "Plan accepted. Execute the next pending step exactly; a native check follows each write. " + Summary();
        }

        public static void ValidateCheck(JObject c, HostType host)
        {
            if (c == null) throw new ArgumentException("Postcondition must be an object.");
            string kind = (string)c["kind"];
            string[] allowed = host == HostType.Excel ? new[]{"cell_value","formula","heading","table","no_errors","format"} :
                host == HostType.Word ? new[]{"text","paragraph_style","table_count","table_content","paragraph_format"} : new[]{"text","slide_count","shape_bounds","table_content","text_alignment"};
            if (!allowed.Contains(kind)) throw new ArgumentException("Unsupported postcondition for " + host + ": " + kind);
            if (host == HostType.Excel && (string.IsNullOrWhiteSpace((string)c["sheet"]) || string.IsNullOrWhiteSpace((string)c["address"])))
                throw new ArgumentException("Excel checks require exact sheet and address.");
            if ((kind == "cell_value" || kind == "formula") && c["value"] == null)
                throw new ArgumentException("Cell/formula checks require the expected computed value.");
            if ((kind == "heading" || kind == "text") && string.IsNullOrWhiteSpace((string)c["text"]))
                throw new ArgumentException("Text checks require expected nonempty text.");
            if (kind == "heading" && c["aboveTable"] != null &&
                (c["aboveTable"].Type != JTokenType.String || string.IsNullOrWhiteSpace((string)c["aboveTable"])))
                throw new ArgumentException("aboveTable must identify the exact table range on the same sheet.");
            if (kind == "table")
            {
                if (c["rows"] != null && (c["rows"].Type != JTokenType.Integer || (int)c["rows"] < 0 || (int)c["rows"] > 511))
                    throw new ArgumentException("Table rows must be an integer between 0 and 511.");
                if (c["headers"] != null)
                {
                    var headers = c["headers"] as JArray;
                    if (headers == null || headers.Count < 1 || headers.Count > 24 ||
                        headers.Any(h => h.Type != JTokenType.String || string.IsNullOrWhiteSpace((string)h) || ((string)h).Length > 100) ||
                        headers.Select(h => (string)h).Distinct(StringComparer.OrdinalIgnoreCase).Count() != headers.Count)
                        throw new ArgumentException("Table headers require 1–24 unique nonempty names.");
                }
                if (c["keyColumn"] != null || c["keys"] != null)
                {
                    var keys=c["keys"] as JArray;
                    if(c["keyColumn"]==null || c["keyColumn"].Type!=JTokenType.Integer || (int)c["keyColumn"]<1 || (int)c["keyColumn"]>24 ||
                        keys==null || keys.Count>511 || c["rows"]==null || keys.Count!=(int)c["rows"] ||
                        keys.Any(k=>k.Type!=JTokenType.String || string.IsNullOrWhiteSpace((string)k) || ((string)k).Length>500) ||
                        keys.Select(k=>(string)k).Distinct(StringComparer.Ordinal).Count()!=keys.Count)
                        throw new ArgumentException("Table keys require a valid keyColumn, exact rows and unique nonempty text IDs in row order.");
                }
            }
            if (kind == "format" && !new[]{"bold","italic","wrapText","fontSize","numberFormat","horizontalAlignment"}.Any(k => c[k] != null))
                throw new ArgumentException("Format checks require at least one explicit formatting property.");
            if(kind=="paragraph_style")
            {
                if(c["styleId"]!=null)
                {
                    if(c["styleId"].Type!=JTokenType.Integer || !new[]{-63,-2,-67,-1}.Contains((int)c["styleId"]))
                        throw new ArgumentException("styleId supports Title, Heading1, BodyText or Normal.");
                }
                else if(string.IsNullOrWhiteSpace((string)c["style"])) throw new ArgumentException("Style check requires style or styleId.");
            }
            if(kind=="paragraph_format")
            {
                if(c["paragraph"]==null || c["paragraph"].Type!=JTokenType.Integer || (int)c["paragraph"]<1 ||
                    c["fontSize"]==null || c["fontSize"].Type!=JTokenType.Integer || (int)c["fontSize"]<6 || (int)c["fontSize"]>96 ||
                    c["bold"]==null || c["bold"].Type!=JTokenType.Boolean || c["rtl"]==null || c["rtl"].Type!=JTokenType.Boolean ||
                    !new[]{"left","right","center"}.Contains((string)c["alignment"]))
                    throw new ArgumentException("Paragraph formatting requires paragraph, bounded fontSize, bold, rtl and alignment.");
            }
            if (kind == "formula" && string.IsNullOrWhiteSpace((string)c["formula"]))
                throw new ArgumentException("Formula checks require the exact formula and expected result.");
            if (kind == "text")
            {
                if (c["text"].Type != JTokenType.String || ((string)c["text"]).Length > 10000)
                    throw new ArgumentException("Text checks require at most 10000 characters.");
                if (c["exact"] != null && c["exact"].Type != JTokenType.Boolean)
                    throw new ArgumentException("exact must be a boolean.");
            }
            if (kind == "table_content")
            {
                var cells = c["cells"] as JArray;
                var first = cells == null || cells.Count == 0 ? null : cells[0] as JArray;
                if (first == null || first.Count < 1 || cells.Count > 64 || first.Count > 24 || cells.Count * first.Count > 64 ||
                    cells.Any(row => !(row is JArray) || ((JArray)row).Count != first.Count ||
                        ((JArray)row).Any(cell => cell.Type != JTokenType.String || ((string)cell).Length > 500)))
                    throw new ArgumentException("Table content requires an exact rectangular matrix of 1–64 text cells, at most 24 columns and 500 characters per cell.");
                foreach (string field in host == HostType.Word ? new[]{"table"} : new[]{"slide","shape"})
                    if (c[field] == null || c[field].Type != JTokenType.Integer || (int)c[field] < 1)
                        throw new ArgumentException("Table content requires an exact positive " + field + " index.");
            }
            if(kind=="text_alignment" && (c["slide"]==null || c["slide"].Type!=JTokenType.Integer || (int)c["slide"]<1 ||
                c["shape"]==null || c["shape"].Type!=JTokenType.Integer || (int)c["shape"]<1 ||
                !new[]{"left","right","center","justify"}.Contains((string)c["alignment"])))
                throw new ArgumentException("Text alignment requires exact slide/shape indices and alignment.");
            if (kind == "table_count" || kind == "slide_count")
                if (c["count"] == null || c["count"].Type != JTokenType.Integer || (int)c["count"] < 0)
                    throw new ArgumentException("Count checks require an explicit nonnegative integer.");
        }

        public string BeforeWrite(ToolCall call)
        {
            if (!Required) return null;
            if (_plan == null) return "PLAN REQUIRED: submit_execution_plan before any write. Include exact tool arguments and native postconditions.";
            var step = Steps.FirstOrDefault(s => !_passed.Contains((string)s["id"]));
            if (step == null) return "Plan already completed. Do not repeat writes.";
            JObject args;
            try { args = JObject.Parse(call.ArgumentsJson ?? "{}"); } catch { return "Invalid write arguments."; }
            if ((string)step["tool"] != call.Name || !JToken.DeepEquals(step["args"],args))
                return "Write differs from the next pending plan step. Inspect the current state, then revise the pending operation if needed. " + Summary();
            string id = (string)step["id"];
            int attempts; _attempts.TryGetValue(id,out attempts);
            if (attempts >= 3) return "Step exhausted its three execution attempts. Stop and report incomplete; do not create a duplicate deliverable.";
            // Replaying an additive write after successful apply but failed verification duplicates content.
            if ((_applied.Contains(id) || _started.Contains(id)) && IsAdditive(call))
                return "This additive operation may already have applied. Inspect the existing target; revise the pending step to an idempotent repair while retaining its checks. Do not replay creation.";
            _attempts[id] = attempts + 1;
            return null;
        }

        private static bool IsAdditive(ToolCall call)
        {
            // Only these exact overwrites are intrinsically safe to replay. Other operations
            // must be inspected and revised after a persisted apply intent.
            if (call.Name == ToolNames.ExecuteOfficeCapability)
            {
                try
                {
                    string id = (string)JObject.Parse(call.ArgumentsJson ?? "{}")["capability"];
                    if (new[]{"sheet.heading","shape.text","shape.format","table.cell_text","table.cell_shading","table.cell_alignment","paragraph.write"}.Contains(id)) return false;
                }
                catch { }
            }
            return call.Name != ToolNames.WriteToCell && call.Name != ToolNames.InsertFormula &&
                call.Name != ToolNames.FormatRange && call.Name != ToolNames.HighlightRange;
        }

        public void MarkApplying()
        {
            if (!Required || _plan == null) return;
            var step = Steps.FirstOrDefault(s => !_passed.Contains((string)s["id"]));
            if (step != null) { _started.Add((string)step["id"]); Checkpoint(); }
        }

        public bool TryResume(string request, HostType host, IPlanVerificationHost verifier, bool revalidate = true)
        {
            string command = (request ?? "").Trim().TrimEnd('.', '!', '؟', '?');
            if (!(command == "ادامه" || command == "ادامه بده" || command.Equals("continue", StringComparison.OrdinalIgnoreCase))) return false;
            if (string.IsNullOrWhiteSpace(PreviousCheckpoint) || PreviousCheckpoint.Length > 250000 || verifier == null) return false;
            var checkpointWriter = SaveCheckpoint;
            try
            {
                SaveCheckpoint = null;
                var saved = JObject.Parse(PreviousCheckpoint);
                if ((int?)saved["version"] != 2 || (string)saved["host"] != host.ToString()) return false;
                string original = (string)saved["request"];
                var candidate = saved["plan"] as JObject;
                if (string.IsNullOrWhiteSpace(original) || candidate == null) return false;
                OriginalRequest = original;
                // Validate in segments so a checkpoint cannot bypass the 36-step bound.
                var all = candidate["steps"] as JArray;
                if (all == null || all.Count < 1 || all.Count > 36) throw new ArgumentException("Invalid checkpoint steps.");
                // Full request coverage is checked against the complete restored plan.
                foreach (var step in all.OfType<JObject>())
                    foreach (var check in (JArray)step["checks"]) ValidateCheck((JObject)check, host);
                string coverage = RequestCoverage.Validate(original, all, host);
                if (coverage != null) throw new ArgumentException(coverage);
                // Submit's normal validation also guards duplicate IDs/tools/arguments.
                _plan = new JObject { ["steps"] = new JArray() };
                Submit(candidate.ToString(Formatting.None), host);
                var ids = new HashSet<string>(Steps.Select(s => (string)s["id"]));
                foreach (string id in (saved["applied"] as JArray ?? new JArray()).Values<string>())
                    if (ids.Contains(id)) _applied.Add(id);
                foreach (string id in (saved["started"] as JArray ?? new JArray()).Values<string>())
                    if (ids.Contains(id)) _started.Add(id);
                var attempts = saved["attempts"] as JObject;
                if (attempts != null) foreach (var a in attempts.Properties())
                    if (ids.Contains(a.Name)) _attempts[a.Name] = Math.Max(0, Math.Min(3, (int)a.Value));
                // Include uncertain writes in read-back, never assume their old passed status.
                foreach (var id in _started) _applied.Add(id);
                SaveCheckpoint = checkpointWriter;
                if (revalidate) VerifyAll(verifier);
                return true;
            }
            catch
            {
                Begin(request, Required);
                return false;
            }
            finally { SaveCheckpoint = checkpointWriter; }
        }

        public string AfterWrite(IPlanVerificationHost host)
        {
            if (!Required || _plan == null) return "";
            var step = Steps.FirstOrDefault(s => !_passed.Contains((string)s["id"]));
            if (step == null) return Summary();
            string id = (string)step["id"]; _applied.Add(id);
            var failures = Check(host, step);
            if (failures.Count == 0) _passed.Add(id);
            VerifyAll(host); // A later write can invalidate an earlier accepted result.
            return failures.Count == 0 ? "POSTCONDITIONS PASSED: " + id + ". " + Summary() :
                "CHANGE APPLIED, POSTCONDITIONS FAILED: " + id + ". Repair existing content. " + string.Join("; ", failures);
        }

        public async Task<string> AfterWriteAsync(IPlanVerificationHost host, CancellationToken ct, Action validateScope)
        {
            if (!Required || _plan == null) return "";
            var step = Steps.FirstOrDefault(s => !_passed.Contains((string)s["id"]));
            if (step == null) return Summary();
            string id = (string)step["id"]; _applied.Add(id);
            var failures = await CheckAsync(host, step, ct, validateScope).ConfigureAwait(true);
            if (failures.Count == 0) _passed.Add(id);
            await VerifyAllAsync(host, ct, validateScope).ConfigureAwait(true);
            return failures.Count == 0 ? "POSTCONDITIONS PASSED: " + id + ". " + Summary() :
                "CHANGE APPLIED, POSTCONDITIONS FAILED: " + id + ". Repair existing content. " + string.Join("; ", failures);
        }

        public async Task<string> VerifyAllAsync(IPlanVerificationHost host, CancellationToken ct, Action validateScope)
        {
            if (_plan == null) return "No execution plan exists.";
            var details = new List<string>();
            foreach (var step in Steps)
            {
                string id = (string)step["id"];
                if (!_applied.Contains(id)) continue;
                var failures = await CheckAsync(host, step, ct, validateScope).ConfigureAwait(true);
                if (failures.Count == 0) _passed.Add(id);
                else { _passed.Remove(id); details.Add(id + ": " + string.Join("; ", failures)); }
            }
            Checkpoint(); return Summary() + (details.Count == 0 ? "" : "\n" + string.Join("\n", details));
        }

        private static async Task<List<string>> CheckAsync(IPlanVerificationHost host, JObject step, CancellationToken ct, Action validateScope)
        {
            var failures = new List<string>();
            foreach (var token in (JArray)step["checks"])
            {
                // Only wait between native operations; never move Office COM to worker threads.
                if (host is IVisibleOfficeExecutionHost) await Task.Delay(1, ct).ConfigureAwait(true);
                ct.ThrowIfCancellationRequested();
                validateScope?.Invoke();
                ct.ThrowIfCancellationRequested();
                failures.AddRange(Check(host, new JObject { ["id"]=step["id"], ["checks"]=new JArray(token.DeepClone()) }));
            }
            return failures;
        }

        public string VerifyAll(IPlanVerificationHost host)
        {
            if (_plan == null) return "No execution plan exists.";
            var details = new List<string>();
            foreach (var step in Steps)
            {
                string id = (string)step["id"];
                if (!_applied.Contains(id)) continue;
                var failures = Check(host,step);
                if (failures.Count == 0) _passed.Add(id);
                else { _passed.Remove(id); details.Add(id + ": " + string.Join("; ", failures)); }
            }
            Checkpoint(); return Summary() + (details.Count == 0 ? "" : "\n" + string.Join("\n", details));
        }
        private static List<string> Check(IPlanVerificationHost host,JObject step)
        {
            var failures=new List<string>();
            foreach(var token in (JArray)step["checks"])
            {
                try { string failure=host.CheckPostcondition((JObject)token); if(failure!=null) {
                    OMNIX.Core.Logging.RuntimeDiagnosticJournal.Event("postcondition_failed", (string)token["kind"], "failed", null, null, null);
                    failures.Add(failure);
                } }
                catch(Exception ex) {
                    OMNIX.Core.Logging.RuntimeDiagnosticJournal.ExceptionEvent("postcondition_error", (string)token["kind"], "failed", null, ex);
                    failures.Add("Native check could not complete for " + (string)token["kind"] + "; inspect the target.");
                }
            }
            return failures;
        }
        public string Summary()
        {
            return _plan == null ? "Plan: required before writing." : "Plan status: " + (Complete ? "verified" : _applied.Count>0 ? "partial" : "planned") + "; " +
                string.Join(", ",Steps.Select(s=>(string)s["id"]+":"+(_passed.Contains((string)s["id"])?"verified":_applied.Contains((string)s["id"])?"needs_repair":"pending")));
        }
        public string Snapshot()
        {
            return new JObject { ["version"]=2, ["host"]=_host, ["request"]=OriginalRequest, ["plan"]=_plan, ["applied"]=new JArray(_applied), ["started"]=new JArray(_started), ["attempts"]=JObject.FromObject(_attempts), ["status"]=Summary() }.ToString(Formatting.None);
        }
        private void Checkpoint()
        {
            // Persistence failure must not turn an applied Office operation into a retryable write failure.
            try { if(SaveCheckpoint!=null) SaveCheckpoint(Snapshot()); }
            catch(Exception) { /* Native verification remains authoritative. */ }
        }
        public string Envelope()
        {
            return "EXECUTION CONTRACT: " + Summary() + "\n" + NextAction() + "\nOriginal user request: " + OriginalRequest +
                (_plan==null ? "" : "\nActive immutable acceptance plan: " + _plan.ToString(Formatting.None)) +
                (string.IsNullOrEmpty(PreviousCheckpoint)?"":"\nPrevious task checkpoint (context only; re-inspect before resuming): " + PreviousCheckpoint);
        }
        public string NextAction()
        {
            if (!Required) return "NEXT ACTION: invoke one documented Office tool, then read back any changed state.";
            if (_plan == null)
                return "NEXT ACTION: call submit_execution_plan BEFORE any write. Its args must be {\"steps\":[{\"id\":\"unique-step\",\"tool\":\"exact-write-tool\",\"args\":{...},\"checks\":[{...}]}]}. Replace placeholders with documented arguments and host-specific native checks. You may inspect the target or get_office_template first; retrieving a template does NOT submit its plan. Do not send the write until submission is accepted.";
            var step = Steps.FirstOrDefault(s => !_passed.Contains((string)s["id"]));
            if (step == null) return "NEXT ACTION: all planned steps passed native checks. Report the verified result without repeating writes.";
            string id = (string)step["id"];
            if (_started.Contains(id) || _applied.Contains(id))
                return "NEXT ACTION: inspect the target and verify_execution_plan before repairing step " + id + ". It may already have applied. Retain the original checks; do not replay additive creation.";
            return "NEXT ACTION: execute exactly this next accepted step: " + step.ToString(Formatting.None) + ". Do not skip it or claim completion early.";
        }
    }
}
