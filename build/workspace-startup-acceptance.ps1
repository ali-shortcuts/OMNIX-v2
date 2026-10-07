$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root 'src\OMNIX.Core\bin\Release'
$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$wpf = Join-Path $framework 'WPF'
$source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Windows.Documents;
using OMNIX.Core.AiGateway.Http;
using OMNIX.Core.AiGateway.Adapters;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Controls.Primitives;
using OMNIX.Core.Settings;
using OMNIX.Core.Context;
using OMNIX.Core.Tools;
using OMNIX.Core.Storage;
using System.Threading.Tasks;
using System.Reflection;
using System.IO;
using OMNIX.Core.Ui;
using OMNIX.Core.Localization;
using OMNIX.Core.Theming;
using OMNIX.Core.AiGateway;
class WorkspaceStartupRegression {
    static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    static double Luminance(Color c) {
        Func<byte,double> f = b => { double v=b/255.0; return v<=0.04045 ? v/12.92 : Math.Pow((v+0.055)/1.055,2.4); };
        return 0.2126*f(c.R)+0.7152*f(c.G)+0.0722*f(c.B);
    }
    static void Contrast(Brush foreground, Brush background) {
        var f=foreground as SolidColorBrush; var b=background as SolidColorBrush;
        Check(f!=null && b!=null, "Theme brush missing");
        double a=Luminance(f.Color), z=Luminance(b.Color);
        Check((Math.Max(a,z)+0.05)/(Math.Min(a,z)+0.05)>=4.5, "Settings text contrast below 4.5:1: "+f.Color+" / "+b.Color);
    }
    static void Snapshot(FrameworkElement element, string name) {
        int width=(int)Math.Ceiling(element.ActualWidth), height=(int)Math.Ceiling(element.ActualHeight);
        Check(width>0 && height>0,"Screenshot layout missing");
        var bitmap=new RenderTargetBitmap(width,height,96,96,PixelFormats.Pbgra32); bitmap.Render(element);
        var encoder=new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
        Directory.CreateDirectory("build/artifact");
        using(var stream=File.Create("build/artifact/"+name+".png")) encoder.Save(stream);
    }
    static void SettingsRegression(WorkspaceView view) {
        view.ShowSettingsTab();
        foreach (ThemeMode mode in new[]{ThemeMode.Dark,ThemeMode.Light}) {
            SettingsManager.Instance.Settings.Theme=mode; ThemeManager.Instance.ApplyTo(view);
            var settings=view.Settings;
            ((Expander)settings.FindName("GeneralSettingsExpander")).IsExpanded = true;
            var provider=(ComboBox)settings.FindName("ProviderCombo");
            provider.ItemsSource=new ProviderRegistry().All.Select(p=>p.Info).ToList();
            provider.DisplayMemberPath="DisplayName";
            provider.SelectedIndex=0;
            Check(provider.SelectedItem.ToString()=="Custom Provider","Provider selected label must display its name");
            var model=(ComboBox)settings.FindName("ModelCombo");
            model.ItemsSource=new[]{"model-one", "model-two-with-a-long-name"};
            foreach (string name in new[]{"ProviderCombo","ModelCombo","ThemeCombo","LanguageCombo"}) {
                var combo=(ComboBox)settings.FindName(name); combo.ApplyTemplate();
                combo.IsDropDownOpen=true; combo.UpdateLayout();
                var frame=new DispatcherFrame();
                Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.Background,new Action(()=>frame.Continue=false));
                Dispatcher.PushFrame(frame);
                var border=(Border)combo.Template.FindName("DropDownBorder",combo);
                Contrast(combo.Foreground,combo.Background); Contrast(combo.Foreground,border.Background);
                var item=(ComboBoxItem)combo.ItemContainerGenerator.ContainerFromIndex(0);
                Check(item!=null,"Drop-down item missing"); item.ApplyTemplate(); item.UpdateLayout();
                Contrast(item.Foreground,item.Background);
                if(name=="ProviderCombo") Snapshot(border,"settings-dropdown-"+mode);
                combo.IsDropDownOpen=false;
            }
            model.Text="manually-entered-model"; model.ApplyTemplate();
            var editor=(TextBox)model.Template.FindName("PART_EditableTextBox",model);
            Check(editor!=null && editor.Visibility==Visibility.Visible,"Editable model input missing");
            editor.Text="edited-model-id";
            Check(model.Text=="edited-model-id","Editable model binding failed");
            Contrast(editor.Foreground,editor.Background);
            model.ItemsSource=new[]{"Custom Model"}; model.SelectedIndex=0;
            var manual=(TextBox)settings.FindName("ManualModelBox"); manual.Text="private/ExactModel";
            var effective=settings.GetType().GetProperty("EffectiveModelId",BindingFlags.NonPublic|BindingFlags.Instance);
            Check((string)effective.GetValue(settings,null)=="private/ExactModel","Manual model ID was lost");
            var busy=settings.GetType().GetMethod("SetProviderOperationBusy",BindingFlags.NonPublic|BindingFlags.Instance);
            busy.Invoke(settings,new object[]{true}); Check(!manual.IsEnabled,"Manual model can change during diagnostics");
            busy.Invoke(settings,new object[]{false}); Check(manual.IsEnabled,"Manual model stays disabled after diagnostics");
            var discovered=(List<string>)settings.GetType().GetField("_discoveredModels",BindingFlags.NonPublic|BindingFlags.Instance).GetValue(settings);
            discovered.Clear(); discovered.AddRange(new[]{"CaseModel","casemodel"});
            settings.GetType().GetMethod("RefreshModelOptions",BindingFlags.NonPublic|BindingFlags.Instance).Invoke(settings,new object[]{"private/ExactModel"});
            Check(model.Items.Contains("CaseModel") && model.Items.Contains("casemodel") && model.Text=="private/ExactModel","Catalog refresh changed model identity");

            var verified=(Dictionary<string,ModelVerificationResult>)settings.GetType().GetField("_modelVerification",BindingFlags.NonPublic|BindingFlags.Instance).GetValue(settings);
            verified.Clear();
            verified["working-model"]=new ModelVerificationResult {ModelId="working-model",State=ModelVerificationState.Working,ToolCallingVerified=true};
            verified["text-model"]=new ModelVerificationResult {ModelId="text-model",State=ModelVerificationState.TextOnly};
            verified["denied-model"]=new ModelVerificationResult {ModelId="denied-model",State=ModelVerificationState.AccessDenied};
            settings.GetType().GetMethod("RenderVerificationSummary",BindingFlags.NonPublic|BindingFlags.Instance).Invoke(settings,new object[]{3,3});
            var choices=(StackPanel)settings.FindName("VerifiedModelsPanel");
            Check(choices.Children.Count==3,"Verified model choices missing");
            foreach(StackPanel row in choices.Children) {
                var button=(Button)row.Children[1];
                if((string)button.Content=="working-model") {
                    button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                    Check(model.Text=="working-model","Verified model click did not select model");
                    Check(SettingsManager.Instance.Settings.SavedModels["custom"].Contains("working-model"),"Verified choice not retained");
                }
                if((string)button.Content=="denied-model") Check(!button.IsEnabled,"Denied model is selectable");
            }

            var connectionButton=(Button)settings.FindName("TestButton");
            var modelButton=(Button)settings.FindName("TestModelButton");
            var verifyButton=(Button)settings.FindName("VerifyModelsButton");
            Check(connectionButton!=null && (string)connectionButton.Content=="Test connection","Separate connection-test control missing");
            Check(modelButton!=null && (string)modelButton.Content=="Test model","Separate model-test control missing");
            Check(verifyButton!=null && (string)verifyButton.Content=="Verify models","Catalog verification control missing");
            Check(view.Chat.FindName("ActivityBorder")==null,"Chat live-activity panel must not exist; execution belongs in Office");
            view.UpdateLayout(); Snapshot(view,"settings-"+mode);
        }
    }
    class FakeHost : IHostAdapter, IIndexedHostAdapter, IOfficeAccessHost {
        public bool AllowWrites; public int Writes;
        public int AccessReads;
        public string ReadOfficeAccess() { AccessReads++; return "documentPresent=true; writeToolsExposed=true; readOnly=false; workbookStructureProtected=false"; }
        public int Reads;
        public HostType Host { get { return HostType.Excel; } }
        public string HostDisplayName { get { return "Excel"; } }
        public int ContextReads;
        public OfficeContext ReadContext() { ContextReads++; return new OfficeContext { Host=HostType.Excel,DocumentName="navigation-test.xlsx" }; }
        public string ReadSelection() { return "selection"; }
        public string ReadDocument(int max) { return "document"; }
        public string ReadDocumentMap(int offset) { Reads++; return "offset="+offset; }
        public string ReadDocumentSection(ToolArguments args) { Reads++; return "cell-data"; }
        public byte[] CaptureChartAsImage(string name) { return null; }
        public byte[] CaptureSlideAsImage(int index) { return null; }
        public byte[] CaptureCurrentViewAsImage() { return null; }
        public WritePreview PrepareWrite(string name,string json) { if (!AllowWrites) throw new NotSupportedException(); return new WritePreview { ToolName=name, ArgumentsJson=json, Title="Test", Before="empty", After="sample" }; }
        public void ApplyWrite(string name,string json) { if (!AllowWrites) throw new NotSupportedException(); Writes++; }
    }
    sealed class AccessProvider : IProviderAdapter {
        public int Calls; public bool CancelScenario;
        public ProviderInfo Info { get; private set; }
        public AccessProvider() { Info = new ProviderInfo { Id="custom", DisplayName="Test", Kind=ProviderKind.Cloud, Vision=VisionSupport.No }; }
        public void Configure(ProviderCredentials credentials) {}
        public bool SupportsVisionNow() { return false; }
        public Task<IReadOnlyList<string>> ListModelsAsync(CancellationToken ct) { return Task.FromResult<IReadOnlyList<string>>(new string[0]); }
        public Task<bool> TestConnectionAsync(CancellationToken ct) { return Task.FromResult(true); }
        public Task<ChatResponse> SendAsync(ChatRequest request,Action<string> delta,CancellationToken ct) {
            Calls++;
            string write="```omnix_tool\n{\"tool\":\"create_data_table\",\"args\":{\"sheet\":\"Test\",\"headers\":[\"ID\"],\"rows\":[[1]]}}\n```";
            string verify="```omnix_tool\n{\"tool\":\"read_document_section\",\"args\":{\"sheet\":\"Test\",\"row\":1,\"column\":1,\"rows\":2,\"columns\":1}}\n```";
            string answer = CancelScenario ? (Calls==1 ? write : "Write access is unavailable")
                : Calls==1 ? "Write access is unavailable" : Calls==2 ? write : Calls==3 ? verify : "Verified completed";
            if(delta!=null) delta(answer);
            return Task.FromResult(new ChatResponse { Text=answer });
        }
    }
    sealed class NativeWriteProvider : IProviderAdapter {
        public int Calls;
        public ProviderInfo Info { get; private set; }
        public NativeWriteProvider() { Info=new ProviderInfo{Id="custom",DisplayName="Native Fixture",Kind=ProviderKind.Cloud,Vision=VisionSupport.No}; }
        public void Configure(ProviderCredentials credentials) {}
        public bool SupportsVisionNow() { return false; }
        public Task<IReadOnlyList<string>> ListModelsAsync(CancellationToken ct) { return Task.FromResult<IReadOnlyList<string>>(new string[0]); }
        public Task<bool> TestConnectionAsync(CancellationToken ct) { return Task.FromResult(true); }
        public Task<ChatResponse> SendAsync(ChatRequest request,Action<string> delta,CancellationToken ct) {
            Calls++;
            if(Calls==1) return Task.FromResult(new ChatResponse {
                Text="",
                ToolCalls=new List<ProviderToolCall> {
                    new ProviderToolCall { Id="call-1", Name="omnix.create_data_table",
                        ArgumentsJson="{\"sheet\":\"NativeTest\",\"headers\":[\"ID\"],\"rows\":[[1]]}" }
                }
            });
            if(Calls==2) return Task.FromResult(new ChatResponse {
                Text="",
                ToolCalls=new List<ProviderToolCall> {
                    new ProviderToolCall { Id="call-2", Name="read_document_section",
                        ArgumentsJson="{\"sheet\":\"NativeTest\",\"row\":1,\"column\":1,\"rows\":2,\"columns\":1}" }
                }
            });
            return Task.FromResult(new ChatResponse { Text="Verified completed" });
        }
    }

    sealed class NoReadbackProvider : IProviderAdapter {
        public int Calls;
        public ProviderInfo Info { get; private set; }
        public NoReadbackProvider() { Info=new ProviderInfo{Id="custom",DisplayName="No Readback Fixture",Kind=ProviderKind.Cloud,Vision=VisionSupport.No}; }
        public void Configure(ProviderCredentials credentials) {}
        public bool SupportsVisionNow() { return false; }
        public Task<IReadOnlyList<string>> ListModelsAsync(CancellationToken ct) { return Task.FromResult<IReadOnlyList<string>>(new string[0]); }
        public Task<bool> TestConnectionAsync(CancellationToken ct) { return Task.FromResult(true); }
        public Task<ChatResponse> SendAsync(ChatRequest request,Action<string> delta,CancellationToken ct) {
            Calls++;
            if(Calls==1) return Task.FromResult(new ChatResponse {
                ToolCalls=new List<ProviderToolCall> {
                    new ProviderToolCall { Id="call-1", Name="write_to_cell", ArgumentsJson="{\"address\":\"A1\",\"value\":\"done\"}" }
                }
            });
            return Task.FromResult(new ChatResponse { Text="Everything is complete." });
        }
    }

    sealed class PlanProbe : OMNIX.Core.Agent.IPlanVerificationHost {
        public bool First = true;
        public bool Second = true;
        public string CheckPostcondition(Newtonsoft.Json.Linq.JObject check) {
            return ((string)check["address"] == "A1" ? First : Second) ? null : "Wrong native value";
        }
    }
    static void ExecutionPlanRegression() {
        var plan = new OMNIX.Core.Agent.ExecutionPlan();
        plan.Begin("write two cells", true);
        var first = new ToolCall { Name = ToolNames.WriteToCell, ArgumentsJson = "{\"sheet\":\"Sheet1\",\"address\":\"A1\",\"value\":1}" };
        Check(plan.BeforeWrite(first) != null, "Unplanned write accepted");
        string json = "{\"steps\":[{\"id\":\"one\",\"tool\":\"write_to_cell\",\"args\":{\"sheet\":\"Sheet1\",\"address\":\"A1\",\"value\":1},\"checks\":[{\"kind\":\"cell_value\",\"sheet\":\"Sheet1\",\"address\":\"A1\",\"value\":1}]},{\"id\":\"two\",\"tool\":\"write_to_cell\",\"args\":{\"sheet\":\"Sheet1\",\"address\":\"A2\",\"value\":2},\"checks\":[{\"kind\":\"cell_value\",\"sheet\":\"Sheet1\",\"address\":\"A2\",\"value\":2}]}]}";
        plan.Submit(json, HostType.Excel);
        var probe = new PlanProbe();
        Check(plan.BeforeWrite(new ToolCall { Name=ToolNames.WriteToCell, ArgumentsJson="{}" }) != null, "Mismatched plan arguments accepted");
        Check(plan.BeforeWrite(first) == null, "Exact planned write rejected");
        plan.AfterWrite(probe);
        Check(!plan.Complete, "Partial plan reported complete");
        bool rejected = false;
        try { plan.Submit(json.Replace("\"checks\":[", "\"checks\":[],\"ignored\":["), HostType.Excel); } catch(ArgumentException) { rejected=true; }
        Check(rejected, "Acceptance criteria were weakened after applying a write");
        var second = new ToolCall { Name=ToolNames.WriteToCell, ArgumentsJson="{\"sheet\":\"Sheet1\",\"address\":\"A2\",\"value\":2}" };
        Check(plan.BeforeWrite(second) == null, "Next planned write rejected");
        probe.First=false;
        plan.AfterWrite(probe);
        Check(!plan.Complete, "Later write invalidated an earlier step without detection");
        probe.First=true;
        plan.VerifyAll(probe);
        Check(plan.Complete, "Native postconditions did not complete plan");
        Check(plan.BeforeWrite(first)!=null, "Completed writes replayed");
        Check(!OMNIX.Core.Agent.OfficePostconditions.ValuesEqual("5",new Newtonsoft.Json.Linq.JValue(5)), "Numeric text accepted as a real number");
        Check(OMNIX.Core.Agent.OfficePostconditions.ValuesEqual(5.0,new Newtonsoft.Json.Linq.JValue(5)), "Equivalent numeric value rejected");
        foreach(string name in new[]{"gold","gold_shop","inventory","invoice"}) {
            var template=OMNIX.Core.Agent.OfficePlaybooks.Template(name,"Demo",HostType.Excel);
            var templatePlan=Newtonsoft.Json.Linq.JObject.Parse(template);
            foreach(Newtonsoft.Json.Linq.JObject step in (Newtonsoft.Json.Linq.JArray)templatePlan["steps"]) {
                ExcelTableBuilder.ValidatePlan(step["args"].ToString());
                foreach(Newtonsoft.Json.Linq.JObject check in (Newtonsoft.Json.Linq.JArray)step["checks"])
                    OMNIX.Core.Agent.ExecutionPlan.ValidateCheck(check,HostType.Excel);
            }
            if(name=="gold_shop") {
                Check(((Newtonsoft.Json.Linq.JArray)templatePlan["steps"]).Count==4,"Gold shop dropped a required sheet");
                Check(!template.Contains("@SALES@") && template.Contains("Demo — فروش"),"Gold shop sheet references unresolved");
                var quoted=OMNIX.Core.Agent.OfficePlaybooks.Template(name,"Ali's",HostType.Excel);
                Check(quoted.Contains("Ali''s — فروش"),"Cross-sheet formulas did not escape apostrophes");
                bool invalid=false; try {OMNIX.Core.Agent.OfficePlaybooks.Template(name,new string('x',31),HostType.Excel);} catch(ArgumentException){invalid=true;}
                Check(invalid,"Invalid generated sheet names were returned for later mutation");
            }
            var candidate=new OMNIX.Core.Agent.ExecutionPlan(); candidate.Begin("demo",true); candidate.Submit(template,HostType.Excel);
        }
        foreach(var host in new[]{HostType.Excel,HostType.Word,HostType.PowerPoint})
            Check(OMNIX.Core.Agent.OfficePlaybooks.Load(host,"gold shop").Contains("BUSINESS TASK GUIDE"), "Selective embedded playbook missing");
        Check(OMNIX.Core.Agent.OfficePostconditions.WordText("Title\r") == "Title", "Word paragraph marker retained");
        Check(OMNIX.Core.Agent.OfficePostconditions.WordText("A\r\a") == "A", "Word cell marker retained");
        Check(OMNIX.Core.Agent.OfficePostconditions.WordText(" A \r\a") == " A ", "Meaningful spaces lost");
        Check(OMNIX.Core.Agent.OfficePostconditions.WordText("A\rB\r\a") == "A\rB", "Meaningful paragraph break lost");
        Check(OMNIX.Core.Agent.OfficePostconditions.TextMatches("A\r\nB", "A\nB", true), "CRLF and LF equivalent content rejected");
        Check(OMNIX.Core.Agent.OfficePostconditions.TextMatches("A\rB", "A\nB", true), "Office CR and LF equivalent content rejected");
        Check(!OMNIX.Core.Agent.OfficePostconditions.TextMatches("A\n\nB", "A\nB", true), "Meaningful empty line lost");
        Check(!OMNIX.Core.Agent.OfficePostconditions.TextMatches("A \rB", "A\nB", true), "Meaningful trailing space lost");
        Check(!OMNIX.Core.Agent.OfficePostconditions.TextMatches("Title extra","Title",true), "Extra text passed exact acceptance");
        Check(OMNIX.Core.Agent.OfficePostconditions.TextMatches("Title extra","Title",false), "Legacy contains check changed");
        foreach(var host in new[]{HostType.Word,HostType.PowerPoint}) {
            var content = new Newtonsoft.Json.Linq.JObject();
            content["kind"]="table_content";
            content["table"]=1; content["slide"]=1; content["shape"]=1;
            content["cells"]=Newtonsoft.Json.Linq.JArray.Parse("[[\"ID\",\"Amount\"],[\"001\",\"20\"]]");
            OMNIX.Core.Agent.ExecutionPlan.ValidateCheck(content,host);
            foreach(string bad in new[]{"[]","[[\"ID\"],[]]","[[1]]","[[null]]"}) {
                var invalid=(Newtonsoft.Json.Linq.JObject)content.DeepClone();
                invalid["cells"]=Newtonsoft.Json.Linq.JArray.Parse(bad);
                bool rejectedCheck=false;try{OMNIX.Core.Agent.ExecutionPlan.ValidateCheck(invalid,host);}catch(ArgumentException){rejectedCheck=true;}
                Check(rejectedCheck,"Malformed table matrix accepted: "+bad);
            }
            var oversized=(Newtonsoft.Json.Linq.JObject)content.DeepClone();
            var rows=new Newtonsoft.Json.Linq.JArray();
            for(int row=0;row<9;row++) { var cells=new Newtonsoft.Json.Linq.JArray(); for(int col=0;col<8;col++) cells.Add("x"); rows.Add(cells); }
            oversized["cells"]=rows;
            bool tooLarge=false;try{OMNIX.Core.Agent.ExecutionPlan.ValidateCheck(oversized,host);}catch(ArgumentException){tooLarge=true;}
            Check(tooLarge,"Unbounded native table check accepted");
            var missing=(Newtonsoft.Json.Linq.JObject)content.DeepClone(); missing.Remove(host==HostType.Word?"table":"shape");
            bool unspecified=false;try{OMNIX.Core.Agent.ExecutionPlan.ValidateCheck(missing,host);}catch(ArgumentException){unspecified=true;}
            Check(unspecified,"Unspecified table target accepted");
            var exact=Newtonsoft.Json.Linq.JObject.Parse("{\"kind\":\"text\",\"paragraph\":1,\"slide\":1,\"shape\":1,\"text\":\"Title\",\"exact\":true}");
            OMNIX.Core.Agent.ExecutionPlan.ValidateCheck(exact,host);
            exact["exact"]="true"; bool invalidBool=false;
            try{OMNIX.Core.Agent.ExecutionPlan.ValidateCheck(exact,host);}catch(ArgumentException){invalidBool=true;}
            Check(invalidBool,"String exact flag accepted");
        }
        foreach(var host in new[]{HostType.Word,HostType.PowerPoint}) {
            string tool=host==HostType.Word?"rewrite_selected_text":"insert_slide";
            var step=new Newtonsoft.Json.Linq.JObject();step["id"]="content";step["tool"]=tool;
            step["args"]=Newtonsoft.Json.Linq.JObject.Parse("{\"text\":\"Title\",\"title\":\"Title\",\"index\":\"1\"}");
            var count=new Newtonsoft.Json.Linq.JObject(); count["kind"]=host==HostType.Word?"table_count":"slide_count";count["count"]=1;
            step["checks"]=new Newtonsoft.Json.Linq.JArray(count);
            var steps=new Newtonsoft.Json.Linq.JArray(step);
            Check(OMNIX.Core.Agent.RequestCoverage.Validate("create",steps,host)!=null,"Count-only content plan accepted");
            var exact=Newtonsoft.Json.Linq.JObject.Parse("{\"kind\":\"text\",\"paragraph\":1,\"slide\":1,\"shape\":1,\"text\":\"Title\",\"exact\":true}");
            step["checks"]=new Newtonsoft.Json.Linq.JArray(exact);
            Check(OMNIX.Core.Agent.RequestCoverage.Validate("create",steps,host)==null,"Exact content plan rejected");
            if(host==HostType.Word) {
                exact["text"]="Other";
                Check(OMNIX.Core.Agent.RequestCoverage.Validate("create",steps,host)!=null,"Wrong Word replacement acceptance passed");
            }
            if(host==HostType.PowerPoint) {
                exact["text"]="Other";
                Check(OMNIX.Core.Agent.RequestCoverage.Validate("create",steps,host)!=null,"Wrong slide title accepted");
                exact["text"]="Title";exact["slide"]=2;
                Check(OMNIX.Core.Agent.RequestCoverage.Validate("create",steps,host)!=null,"Different slide accepted as creation evidence");
                exact["slide"]=1;step["args"]["body"]="Body";
                Check(OMNIX.Core.Agent.RequestCoverage.Validate("create",steps,host)!=null,"Missing slide body acceptance passed");
                var body=(Newtonsoft.Json.Linq.JObject)exact.DeepClone();body["text"]="Body";body["shape"]=2;
                ((Newtonsoft.Json.Linq.JArray)step["checks"]).Add(body);
                Check(OMNIX.Core.Agent.RequestCoverage.Validate("create",steps,host)==null,"Complete slide content criteria rejected");
                step["args"]["body"]="Line1\nLine2";body["text"]="Line1\rLine2";
                Check(OMNIX.Core.Agent.RequestCoverage.Validate("create",steps,host)==null,"Equivalent Office line endings failed plan coverage");
                step["args"]["index"]="0";
                Check(OMNIX.Core.Agent.RequestCoverage.Validate("create",steps,host)!=null,"Unresolved append target accepted");
            }
        }
        foreach(var host in new[]{HostType.Word,HostType.PowerPoint}) {
            string[] names=host==HostType.Word?new[]{"report","letter","meeting"}:new[]{"briefing","training","sales"};
            foreach(string name in names) {
                var options=new Newtonsoft.Json.Linq.JObject();options["name"]=name;options["title"]="Exact title";options["startIndex"]=4;options["rtl"]=true;
                var result=Newtonsoft.Json.Linq.JObject.Parse(OMNIX.Core.Agent.OfficePlaybooks.Template(options,host));
                var steps=(Newtonsoft.Json.Linq.JArray)result["steps"];
                Check(steps.Count==(host==HostType.Word?5:9),"Host template lost ordered creation/formatting steps");
                Check(OMNIX.Core.Agent.RequestCoverage.Validate("create",steps,host)==null,"Host template acceptance is incomplete");
                if(host==HostType.Word) {
                    var firstTemplateStep=(Newtonsoft.Json.Linq.JObject)steps[0];
                    Check((bool)firstTemplateStep["args"]["args"]["requireBlankDocument"],"Word template would overwrite an existing document");
                    foreach(Newtonsoft.Json.Linq.JObject step in steps) {
                        WordParagraphWriter.Validate((Newtonsoft.Json.Linq.JObject)step["args"]["args"]);
                        Check(((Newtonsoft.Json.Linq.JArray)step["checks"]).Count==3,"Word template lacks native role/text/format checks");
                    }
                    ((Newtonsoft.Json.Linq.JArray)firstTemplateStep["checks"]).RemoveAt(2);
                    Check(OMNIX.Core.Agent.RequestCoverage.Validate("create",steps,host)!=null,"Weak Word formatting criteria passed");
                } else {
                    Check((string)steps[0]["args"]["index"]=="4" && (int)steps[0]["checks"][0]["slide"]==4,"Slide template lost exact insertion target");
                    options.Remove("startIndex");bool rejectedIndex=false;
                    try{OMNIX.Core.Agent.OfficePlaybooks.Template(options,host);}catch(ArgumentException){rejectedIndex=true;}
                    Check(rejectedIndex,"Uninspected PowerPoint append target accepted");
                }
                options["title"]="Bad\nTitle";bool badTitle=false;
                try{OMNIX.Core.Agent.OfficePlaybooks.Template(options,host);}catch(ArgumentException){badTitle=true;}
                Check(badTitle,"Control characters in template title accepted");
            }
        }
        var paragraphArgs=Newtonsoft.Json.Linq.JObject.Parse("{\"paragraph\":1,\"text\":\"Title\",\"expectedBefore\":\"\",\"role\":\"title\"}");
        WordParagraphWriter.Validate(paragraphArgs);
        foreach(string field in new[]{"paragraph","text","expectedBefore","role"}) {
            var invalid=(Newtonsoft.Json.Linq.JObject)paragraphArgs.DeepClone();invalid.Remove(field);
            bool rejectedParagraph=false;try{WordParagraphWriter.Validate(invalid);}catch(ArgumentException){rejectedParagraph=true;}
            Check(rejectedParagraph,"Missing paragraph field accepted: "+field);
        }
        paragraphArgs["text"]="Two\nParagraphs";bool multiple=false;
        try{WordParagraphWriter.Validate(paragraphArgs);}catch(ArgumentException){multiple=true;}
        Check(multiple,"Multi-paragraph text accepted by a one-paragraph operation");
        plan.SaveCheckpoint = text => { throw new IOException("disk unavailable"); };
        plan.VerifyAll(probe);
        Check(plan.Complete, "Checkpoint failure changed native verification result");
    }

    sealed class ScopeIdentityHost : FakeHost, IRequestScopeIdentityHost {
        public int IdentityReads; public string IdentityName="navigation-test.xlsx";
        public OfficeContext ReadScopeIdentity() {IdentityReads++; return new OfficeContext {Host=HostType.Excel,DocumentName=IdentityName};}
    }
    static void ScopeIdentityRegression() {
        var host=new ScopeIdentityHost();
        using(var controller=new WorkspaceController(host,new ChatHistoryStore())) {
            controller.RefreshContextBar();
            string key=(string)typeof(WorkspaceController).GetField("_docKey",BindingFlags.NonPublic|BindingFlags.Instance).GetValue(controller);
            int version=(int)typeof(WorkspaceController).GetField("_documentScopeVersion",BindingFlags.NonPublic|BindingFlags.Instance).GetValue(controller);
            var validate=typeof(WorkspaceController).GetMethod("ValidateCurrentOfficeDocumentScope",BindingFlags.NonPublic|BindingFlags.Instance);
            int heavyReads=host.ContextReads;
            Check((bool)validate.Invoke(controller,new object[]{key,version}),"Identity-only scope rejected current document");
            Check(host.ContextReads==heavyReads && host.IdentityReads==1,"Scope validation performed a full content scan");
            host.IdentityName="another.xlsx";
            Check(!(bool)validate.Invoke(controller,new object[]{key,version}),"Identity-only validation accepted a changed document");
        }
    }
    sealed class AcceptanceProbe : OMNIX.Core.Agent.IPlanVerificationHost {
        public bool Accept; public int Reads;
        public string CheckPostcondition(Newtonsoft.Json.Linq.JObject check) { Reads++; return Accept ? null : "mismatch"; }
    }
    static Newtonsoft.Json.Linq.JObject PlanStep(string id) {
        return Newtonsoft.Json.Linq.JObject.Parse("{\"id\":\""+id+"\",\"tool\":\"write_to_cell\",\"args\":{\"sheet\":\"Sheet1\",\"address\":\"A1\",\"value\":1},\"checks\":[{\"kind\":\"cell_value\",\"sheet\":\"Sheet1\",\"address\":\"A1\",\"value\":1}]}");
    }
    static Newtonsoft.Json.Linq.JObject PlanEnvelope(Newtonsoft.Json.Linq.JArray steps, bool append=false) {
        var result=new Newtonsoft.Json.Linq.JObject(); result["steps"]=steps; if(append)result["append"]=true; return result;
    }
    static void TaskLifecycleRegression() {
        var steps=new Newtonsoft.Json.Linq.JArray(PlanStep("one"));
        Check(OMNIX.Core.Agent.RequestCoverage.Validate("اسم دکان در بالا باشد",steps,HostType.Excel)!=null,"Missing separate heading accepted");
        Check(OMNIX.Core.Agent.RequestCoverage.Validate("Add formula",steps,HostType.Excel)!=null,"Missing explicit formula accepted");
        Check(OMNIX.Core.Agent.RequestCoverage.Validate("شیت «فروش» بساز",steps,HostType.Excel)!=null,"Missing named sheet accepted");
        Check(OMNIX.Core.Agent.RequestCoverage.Validate("create table with no formula",steps,HostType.Excel)==null,"No-formula request falsely required formula");
        var heading=PlanStep("heading"); ((Newtonsoft.Json.Linq.JArray)heading["checks"]).Add(Newtonsoft.Json.Linq.JObject.Parse("{\"kind\":\"heading\",\"sheet\":\"Sheet1\",\"address\":\"A1:H2\",\"text\":\"Shop\",\"aboveTable\":\"A4:H5\"}"));
        ((Newtonsoft.Json.Linq.JArray)heading["checks"]).Add(Newtonsoft.Json.Linq.JObject.Parse("{\"kind\":\"table\",\"sheet\":\"Sheet1\",\"address\":\"A4:H5\"}"));
        Check(OMNIX.Core.Agent.RequestCoverage.Validate("shop name above table",new Newtonsoft.Json.Linq.JArray(heading),HostType.Excel)==null,"Valid heading coverage rejected");
        Check(OMNIX.Core.Agent.RequestCoverage.Validate("shop name \"Different\" above table",new Newtonsoft.Json.Linq.JArray(heading),HostType.Excel)!=null,"Wrong explicit heading text accepted");
        var described=OMNIX.Core.Agent.RequestCoverage.Describe("shop name \"Shop\" above table, sheet \"Sales\"",HostType.Excel);
        Check(described.Contains("explicitHeadingText") && described.Contains("Sales"),"Original explicit requirements not exposed to the model");
        var wrongTable=(Newtonsoft.Json.Linq.JObject)heading.DeepClone(); wrongTable["checks"][2]["sheet"]="Other";
        Check(OMNIX.Core.Agent.RequestCoverage.Validate("shop name above table",new Newtonsoft.Json.Linq.JArray(wrongTable),HostType.Excel)!=null,"Heading matched a table on a different sheet");
        foreach(string invalidTable in new[]{"{\"kind\":\"table\",\"sheet\":\"S\",\"address\":\"A1:B2\",\"rows\":-1}","{\"kind\":\"table\",\"sheet\":\"S\",\"address\":\"A1:B2\",\"headers\":[\"ID\",\"ID\"]}","{\"kind\":\"table\",\"sheet\":\"S\",\"address\":\"A1:B3\",\"rows\":2,\"keyColumn\":1,\"keys\":[\"X\",\"X\"]}"}) {
            bool rejectedTable=false; try {OMNIX.Core.Agent.ExecutionPlan.ValidateCheck(Newtonsoft.Json.Linq.JObject.Parse(invalidTable),HostType.Excel);} catch(ArgumentException){rejectedTable=true;}
            Check(rejectedTable,"Malformed native table criterion accepted");
        }
        var teachingView=new OMNIX.Core.Ui.ChatView();
        var preferences=SettingsManager.Instance.Settings;bool priorTeaching=preferences.ExecutionTeachingMode;
        try {
            teachingView.SetBusy(true);preferences.ExecutionTeachingMode=false;teachingView.ShowOperation("write_to_cell","inspect");
            var lesson=(TextBlock)teachingView.FindName("ExecutionLesson");Check(lesson.Visibility==Visibility.Collapsed,"Teaching details shown when disabled");
            preferences.ExecutionTeachingMode=true;teachingView.ShowOperation("write_to_cell","inspect");
            Check(lesson.Visibility==Visibility.Visible && lesson.Text.Length>0,"Teaching explanation absent for real stage");
            teachingView.SetBusy(false);Check(lesson.Visibility==Visibility.Collapsed,"Stale teaching stage remained after completion");
            var roundtrip=Newtonsoft.Json.JsonConvert.DeserializeObject<OMNIX.Core.Settings.OmnixSettings>(Newtonsoft.Json.JsonConvert.SerializeObject(preferences));
            Check(roundtrip.ExecutionTeachingMode,"Teaching preference did not persist");
            Check(!Newtonsoft.Json.JsonConvert.DeserializeObject<OMNIX.Core.Settings.OmnixSettings>("{}").ExecutionTeachingMode,"Old settings silently enabled teaching mode");
        } finally {preferences.ExecutionTeachingMode=priorTeaching;}
        var plan=new OMNIX.Core.Agent.ExecutionPlan(); plan.Begin("write cells",true);
        plan.Submit(PlanEnvelope(steps).ToString(),HostType.Excel);
        var probe=new AcceptanceProbe {Accept=true};
        var call=new ToolCall {Name=ToolNames.WriteToCell,ArgumentsJson=steps[0]["args"].ToString()};
        Check(plan.BeforeWrite(call)==null,"Initial step rejected"); plan.MarkApplying(); plan.AfterWrite(probe);
        Check(plan.Complete,"Native accepted step incomplete");
        plan.Submit(PlanEnvelope(new Newtonsoft.Json.Linq.JArray(PlanStep("two")),true).ToString(),HostType.Excel);
        Check(!plan.Complete && plan.VerifiedStepCount==1,"Appending lost acceptance or reported completion too early");
        bool duplicate=false; try {plan.Submit(PlanEnvelope(new Newtonsoft.Json.Linq.JArray(PlanStep("two")),true).ToString(),HostType.Excel);} catch(ArgumentException){duplicate=true;}
        Check(duplicate,"Duplicate appended step ID accepted");
        string saved=plan.Snapshot(); var resumed=new OMNIX.Core.Agent.ExecutionPlan {PreviousCheckpoint=saved}; resumed.Begin("continue",true);
        Check(resumed.TryResume("continue",HostType.Excel,probe) && resumed.VerifiedStepCount==1 && !resumed.Complete,"Partial task not safely resumed");
        Check(resumed.OriginalRequest=="write cells","Resume lost original goal");
        var wrong=new OMNIX.Core.Agent.ExecutionPlan {PreviousCheckpoint=saved}; wrong.Begin("continue",true);
        Check(!wrong.TryResume("continue",HostType.Word,probe),"Cross-host checkpoint accepted");
        var unrelated=new OMNIX.Core.Agent.ExecutionPlan {PreviousCheckpoint=saved}; unrelated.Begin("new task",true);
        Check(!unrelated.TryResume("new task",HostType.Excel,probe),"Unrelated request resumed old task");
        var creation=PlanStep("create"); creation["tool"]="create_data_table";
        creation["args"]=Newtonsoft.Json.Linq.JObject.Parse("{\"sheet\":\"Sheet1\",\"headers\":[\"ID\"],\"rows\":[[1]]}");
        var secondCreation=(Newtonsoft.Json.Linq.JObject)creation.DeepClone();secondCreation["id"]="second";secondCreation["args"]["sheet"]="Later";
        var guarded=new OMNIX.Core.Agent.ExecutionPlan();guarded.Begin("create two sheets",true);int inspections=0;
        bool collision=false;try{guarded.Submit(PlanEnvelope(new Newtonsoft.Json.Linq.JArray(creation,secondCreation)).ToString(),HostType.Excel,name=>{inspections++;return name=="Later";});}catch(ArgumentException){collision=true;}
        Check(collision && inspections==2 && guarded.BeforeWrite(new ToolCall {Name=ToolNames.CreateDataTable,ArgumentsJson=creation["args"].ToString()}).Contains("PLAN REQUIRED"),"Later destination collision accepted a writable partial plan");
        secondCreation["args"]["sheet"]="sheet1";
        bool repeated=false;try{guarded.Submit(PlanEnvelope(new Newtonsoft.Json.Linq.JArray(creation,secondCreation)).ToString(),HostType.Excel);}catch(ArgumentException){repeated=true;}
        Check(repeated,"Case-insensitive duplicate creation destinations accepted");
        var uncertain=new OMNIX.Core.Agent.ExecutionPlan(); uncertain.Begin("create",true);
        uncertain.Submit(PlanEnvelope(new Newtonsoft.Json.Linq.JArray(creation)).ToString(),HostType.Excel);
        var createCall=new ToolCall {Name=ToolNames.CreateDataTable,ArgumentsJson=creation["args"].ToString()};
        Check(uncertain.BeforeWrite(createCall)==null,"Initial creation rejected"); uncertain.MarkApplying();
        var recovered=new OMNIX.Core.Agent.ExecutionPlan {PreviousCheckpoint=uncertain.Snapshot()}; recovered.Begin("ادامه",true); probe.Accept=false;
        Check(recovered.TryResume("ادامه",HostType.Excel,probe),"Uncertain checkpoint not inspected");
        Check(recovered.BeforeWrite(createCall)!=null,"Uncertain additive creation replayed");
        int reads=probe.Reads; var corrupt=new OMNIX.Core.Agent.ExecutionPlan {PreviousCheckpoint="not json"}; corrupt.Begin("continue",true);
        Check(!corrupt.TryResume("continue",HostType.Excel,probe) && probe.Reads==reads,"Invalid checkpoint crossed native boundary");
        var batch=new OMNIX.Core.Agent.ExecutionPlan(); batch.Begin("batch",true);
        for(int segment=0;segment<3;segment++) {
            var chunk=new Newtonsoft.Json.Linq.JArray(); for(int i=0;i<12;i++)chunk.Add(PlanStep("s"+(segment*12+i)));
            var envelope=PlanEnvelope(chunk); if(segment>0)envelope["append"]=true;
            batch.Submit(envelope.ToString(),HostType.Excel);
        }
        bool over=false;try{batch.Submit(PlanEnvelope(new Newtonsoft.Json.Linq.JArray(PlanStep("extra")),true).ToString(),HostType.Excel);}catch(ArgumentException){over=true;}
        Check(over,"Segment bound exceeded");
        var cancellable=new OMNIX.Core.Agent.ExecutionPlan(); cancellable.Begin("write",true);
        cancellable.Submit(PlanEnvelope(new Newtonsoft.Json.Linq.JArray(PlanStep("check"))).ToString(),HostType.Excel);
        probe.Accept=true; int beforeChecks=probe.Reads;
        using(var cts=new CancellationTokenSource()) {
            try { cancellable.AfterWriteAsync(probe,cts.Token,()=>cts.Cancel()).GetAwaiter().GetResult(); throw new Exception("Cancelled native verification continued"); }
            catch(OperationCanceledException) {}
        }
        Check(probe.Reads==beforeChecks,"Cancellation during scope validation crossed native boundary");
        Check(cancellable.AfterWriteAsync(probe,CancellationToken.None,()=>{}).GetAwaiter().GetResult().Contains("PASSED") && cancellable.Complete,"Asynchronous native verification failed");
    }

    sealed class ContractHost : FakeHost, OMNIX.Core.Agent.IPlanVerificationHost {
        public bool Accept;
        public string CheckPostcondition(Newtonsoft.Json.Linq.JObject check) { return Accept && Writes > 0 ? null : "Native value mismatch"; }
    }
    sealed class ContractProvider : IProviderAdapter {
        public int Calls;
        public ProviderInfo Info { get; private set; }
        public ContractProvider() { Info=new ProviderInfo { Id="custom",DisplayName="Contract fixture",Kind=ProviderKind.Cloud,Vision=VisionSupport.No }; }
        public void Configure(ProviderCredentials credentials) {}
        public bool SupportsVisionNow() { return false; }
        public Task<IReadOnlyList<string>> ListModelsAsync(CancellationToken ct) { return Task.FromResult<IReadOnlyList<string>>(new string[0]); }
        public Task<bool> TestConnectionAsync(CancellationToken ct) { return Task.FromResult(true); }
        public Task<ChatResponse> SendAsync(ChatRequest request,Action<string> delta,CancellationToken ct) {
            Calls++;
            string name=null, args=null;
            if(Calls==1) {
                name=ToolNames.SubmitExecutionPlan;
                args="{\"steps\":[{\"id\":\"write\",\"tool\":\"write_to_cell\",\"args\":{\"address\":\"A1\",\"value\":1},\"checks\":[{\"kind\":\"cell_value\",\"sheet\":\"Sheet1\",\"address\":\"A1\",\"value\":1}]}]}";
            } else if(Calls==2) { name=ToolNames.WriteToCell; args="{\"address\":\"A1\",\"value\":1}"; }
            else if(Calls==3) { name=ToolNames.ReadDocumentMap; args="{}"; }
            if(name!=null) return Task.FromResult(new ChatResponse { ToolCalls=new List<ProviderToolCall> { new ProviderToolCall { Id="contract-"+Calls,Name=name,ArgumentsJson=args } } });
            return Task.FromResult(new ChatResponse { Text="Everything is complete." });
        }
    }
    static void NativeContractGatewayRegression() {
        var settings=SettingsManager.Instance.Settings;
        var oldProvider=settings.SelectedProviderId; var oldPrivacy=settings.Privacy; bool oldLocal=settings.PreferLocalWhenAvailable;
        try {
            settings.SelectedProviderId="custom"; settings.Privacy=PrivacyMode.CloudAllowed; settings.PreferLocalWhenAvailable=false;
            foreach(bool accept in new[]{false,true}) {
                var registry=new ProviderRegistry(); var provider=new ContractProvider();
                var providers=(List<IProviderAdapter>)typeof(ProviderRegistry).GetField("_providers",BindingFlags.NonPublic|BindingFlags.Instance).GetValue(registry);
                providers.Clear(); providers.Add(provider);
                var gateway=new OMNIX.Core.AiGateway.AiGateway(registry);
                var host=new ContractHost { AllowWrites=true,Accept=accept };
                var executor=new ToolExecutor { WriteConfirmation=preview=>Task.FromResult(true) };
                var result=gateway.ChatAsync(new ChatRequest { UserTurn=new ChatTurn {Role=ChatRole.User,Text="Write one into A1"}},host,part=>{},executor,CancellationToken.None).GetAwaiter().GetResult();
                Check(host.Writes==1,"Contract path repeated or skipped mutation");
                Check(executor.Execution.Complete==accept,"Gateway ignored native acceptance state");
                Check((result.Text=="Everything is complete.")==accept,"Unrelated document read falsely verified the execution plan");
            }
        } finally { settings.SelectedProviderId=oldProvider;settings.Privacy=oldPrivacy;settings.PreferLocalWhenAvailable=oldLocal; }
    }

    sealed class SegmentProvider : IProviderAdapter {
        public bool Progress; public int Calls;
        public ProviderInfo Info {get {return new ProviderInfo {Id="custom",DisplayName="Segment fixture",Kind=ProviderKind.Cloud,Vision=VisionSupport.No};}}
        public void Configure(ProviderCredentials c) {} public bool SupportsVisionNow(){return false;}
        public Task<IReadOnlyList<string>> ListModelsAsync(CancellationToken ct){return Task.FromResult<IReadOnlyList<string>>(new string[0]);}
        public Task<bool> TestConnectionAsync(CancellationToken ct){return Task.FromResult(true);}
        public Task<ChatResponse> SendAsync(ChatRequest request,Action<string> delta,CancellationToken ct) {
            Calls++; string tool=ToolNames.ReadDocumentMap, args="{}";
            if(Progress && Calls==1) {tool=ToolNames.SubmitExecutionPlan;args=PlanEnvelope(new Newtonsoft.Json.Linq.JArray(PlanStep("one"))).ToString();}
            else if(Progress && Calls==2){tool=ToolNames.WriteToCell;args=PlanStep("one")["args"].ToString();}
            if(Progress && Calls==26)return Task.FromResult(new ChatResponse {Text="Finished after checkpoint."});
            return Task.FromResult(new ChatResponse {ToolCalls=new List<ProviderToolCall>{new ProviderToolCall {Id="segment-"+Calls,Name=tool,ArgumentsJson=args}}});
        }
    }
    static void SegmentGatewayRegression() {
        var settings=SettingsManager.Instance.Settings; var providerId=settings.SelectedProviderId;
        var privacy=settings.Privacy; bool local=settings.PreferLocalWhenAvailable;
        try {
            settings.SelectedProviderId="custom"; settings.Privacy=PrivacyMode.CloudAllowed; settings.PreferLocalWhenAvailable=false;
            foreach(bool progress in new[]{false,true}) {
                var registry=new ProviderRegistry();var provider=new SegmentProvider {Progress=progress};
                var providers=(List<IProviderAdapter>)typeof(ProviderRegistry).GetField("_providers",BindingFlags.NonPublic|BindingFlags.Instance).GetValue(registry);
                providers.Clear();providers.Add(provider);
                var gateway=new OMNIX.Core.AiGateway.AiGateway(registry);
                var host=new ContractHost {AllowWrites=true,Accept=true};
                var executor=new ToolExecutor {WriteConfirmation=preview=>Task.FromResult(true)};
                var result=gateway.ChatAsync(new ChatRequest {UserTurn=new ChatTurn {Role=ChatRole.User,Text="Write one into A1"}},host,part=>{},executor,CancellationToken.None).GetAwaiter().GetResult();
                Check(provider.Calls==(progress?26:24),"Segments must continue only with native verified progress");
                Check(host.Writes==(progress?1:0),"Segment continuation repeated a write");
                Check((result.Text=="Finished after checkpoint.")==progress,"No-progress loop falsely completed");
            }
        } finally {settings.SelectedProviderId=providerId;settings.Privacy=privacy;settings.PreferLocalWhenAvailable=local;}
    }

    sealed class TextProtocolProvider : IProviderAdapter {
        public int Calls;
        public ProviderInfo Info { get { return new ProviderInfo {Id="custom",Kind=ProviderKind.Cloud,Vision=VisionSupport.No}; } }
        public void Configure(ProviderCredentials c) {}
        public bool SupportsVisionNow() { return false; }
        public Task<IReadOnlyList<string>> ListModelsAsync(CancellationToken ct) { return Task.FromResult<IReadOnlyList<string>>(new string[0]); }
        public Task<bool> TestConnectionAsync(CancellationToken ct) { return Task.FromResult(true); }
        public Task<ChatResponse> SendAsync(ChatRequest r,Action<string> delta,CancellationToken ct) {
            Calls++;
            return Task.FromResult(new ChatResponse {Text=r.UseNativeTools ? "I cannot call native tools." : "<tool_call>omnix_tool {\"tool\":\"read_office_access\",\"args\":{}}</tool_call>"});
        }
    }

    static void ModelEvidenceRegression() {
        var probeProvider = new TextProtocolProvider();
        var probeMethod = typeof(ProviderDiagnostics).GetMethod("ProbeOmnixToolCallingAsync",BindingFlags.Static|BindingFlags.NonPublic);
        var probeTask = (Task)probeMethod.Invoke(null,new object[]{probeProvider,CancellationToken.None});
        probeTask.GetAwaiter().GetResult();
        var probe = probeTask.GetType().GetProperty("Result").GetValue(probeTask,null);
        Check(probeProvider.Calls==2 && (bool)probe.GetType().GetField("Verified").GetValue(probe),"Bounded text-protocol fallback was not verified");
        var c=new ProviderCredentials { Model="CaseModel",BaseUrl="https://example.invalid/v1",ApiType="OpenAI",ApiKey="fixture-key" };
        var failed=new ModelVerificationResult { ModelId=c.Model,State=ModelVerificationState.TextOnly };
        ModelCapabilityEvidence.Record("custom",c,failed);
        Check(ModelCapabilityEvidence.BlocksOfficeActions("custom",c),"Known text-only model still allowed to act");
        foreach(var changed in new[]{
            new ProviderCredentials { Model="casemodel",BaseUrl=c.BaseUrl,ApiType=c.ApiType,ApiKey=c.ApiKey },
            new ProviderCredentials { Model=c.Model,BaseUrl=c.BaseUrl+"/other",ApiType=c.ApiType,ApiKey=c.ApiKey },
            new ProviderCredentials { Model=c.Model,BaseUrl=c.BaseUrl,ApiType="Anthropic",ApiKey=c.ApiKey },
            new ProviderCredentials { Model=c.Model,BaseUrl=c.BaseUrl,ApiType=c.ApiType,ApiKey="different-key" }})
            Check(!ModelCapabilityEvidence.BlocksOfficeActions("custom",changed),"Evidence leaked between model/endpoint/protocol/key configurations");
        Check(!ModelCapabilityEvidence.BlocksOfficeActions("other",c),"Evidence leaked between providers");
        ModelCapabilityEvidence.Record("custom",c,new ModelVerificationResult {ModelId=c.Model,State=ModelVerificationState.Working,ToolCallingVerified=true});
        Check(!ModelCapabilityEvidence.BlocksOfficeActions("custom",c),"Successful retest failed to clear negative evidence");
        ModelCapabilityEvidence.Record("custom",c,new ModelVerificationResult {ModelId=c.Model,State=ModelVerificationState.Working,ToolCallingVerified=true,ToolTransport="text-fallback"});
        Check(ModelCapabilityEvidence.PrefersTextProtocol("custom",c),"Verified fallback transport was discarded");
        var settings=SettingsManager.Instance.Settings;
        var oldProvider=settings.SelectedProviderId; var oldPrivacy=settings.Privacy; bool oldLocal=settings.PreferLocalWhenAvailable;
        try {
            settings.SelectedProviderId="custom"; settings.Privacy=PrivacyMode.CloudAllowed;settings.PreferLocalWhenAvailable=false;
            var registry=new ProviderRegistry();var provider=new NoReadbackProvider();
            var providers=(List<IProviderAdapter>)typeof(ProviderRegistry).GetField("_providers",BindingFlags.NonPublic|BindingFlags.Instance).GetValue(registry);
            providers.Clear();providers.Add(provider);
            var gateway=new OMNIX.Core.AiGateway.AiGateway(registry);
            var credentials=gateway.Router.BuildCredentials("custom");
            ModelCapabilityEvidence.Record("custom",credentials,new ModelVerificationResult {ModelId=credentials.Model,State=ModelVerificationState.TextOnly});
            var host=new FakeHost {AllowWrites=true};
            var executor=new ToolExecutor {WriteConfirmation=preview=>Task.FromResult(true)};
            var response=gateway.ChatAsync(new ChatRequest {UserTurn=new ChatTurn {Role=ChatRole.User,Text="Write a table into Excel"}},host,part=>{},executor,CancellationToken.None).GetAwaiter().GetResult();
            Check(provider.Calls==0 && host.Writes==0 && response.Text.Contains("Test model"),"Negative evidence did not block mutation before provider call");
            response=gateway.ChatAsync(new ChatRequest {UserTurn=new ChatTurn {Role=ChatRole.User,Text="Hello"}},host,part=>{},executor,CancellationToken.None).GetAwaiter().GetResult();
            Check(host.Writes==0,"Text chat response bypassed action guard with an unsolicited write");
            ModelCapabilityEvidence.Record("custom",credentials,new ModelVerificationResult {ModelId=credentials.Model,State=ModelVerificationState.Working,ToolCallingVerified=true});
        } finally {settings.SelectedProviderId=oldProvider;settings.Privacy=oldPrivacy;settings.PreferLocalWhenAvailable=oldLocal;}
        Check(OMNIX.Core.Reference.OfficeReference.Search("Word","table").Contains("table.insert"),"Word reference omitted implemented table tools");
        Check(OMNIX.Core.Reference.OfficeReference.Search("PowerPoint","shape").Contains("shape.add"),"PowerPoint reference omitted implemented shapes");
        Check(OMNIX.Core.Reference.OfficeReference.Search("Excel","SUM").Contains("SUM"),"Excel function reference disappeared");
    }

    static void NativeGatewayRegression() {
        var settings=SettingsManager.Instance.Settings;
        var oldProvider=settings.SelectedProviderId; var oldPrivacy=settings.Privacy; bool oldLocal=settings.PreferLocalWhenAvailable;
        try {
            settings.SelectedProviderId="custom"; settings.Privacy=PrivacyMode.CloudAllowed; settings.PreferLocalWhenAvailable=false;
            var registry=new ProviderRegistry(); var provider=new NativeWriteProvider();
            var providers=(System.Collections.Generic.List<IProviderAdapter>)typeof(ProviderRegistry).GetField("_providers",BindingFlags.NonPublic|BindingFlags.Instance).GetValue(registry);
            providers.Clear(); providers.Add(provider);
            var gateway=new OMNIX.Core.AiGateway.AiGateway(registry);
            var host=new FakeHost { AllowWrites=true };
            int confirmations=0;
            var executor=new ToolExecutor { WriteConfirmation=preview=> { confirmations++; return Task.FromResult(true); } };
            var result=gateway.ChatAsync(new ChatRequest { UserTurn=new ChatTurn { Role=ChatRole.User,Text="Create a test table" } },
                host,part=>{},executor,CancellationToken.None).GetAwaiter().GetResult();
            Check(provider.Calls==3,"Native tool response did not require read-back before final provider turn");
            Check(confirmations==1 && host.Writes==1,"Native tool call with empty text was not executed through confirmation");
            Check(host.Reads>=2,"Latest write was not read back after execution");
            Check(result.Text=="Verified completed","Native tool loop did not return final answer after read-back");
        } finally { settings.SelectedProviderId=oldProvider; settings.Privacy=oldPrivacy; settings.PreferLocalWhenAvailable=oldLocal; }
    }

    static void VerificationEnforcementRegression() {
        var settings=SettingsManager.Instance.Settings;
        var oldProvider=settings.SelectedProviderId; var oldPrivacy=settings.Privacy; bool oldLocal=settings.PreferLocalWhenAvailable;
        try {
            settings.SelectedProviderId="custom"; settings.Privacy=PrivacyMode.CloudAllowed; settings.PreferLocalWhenAvailable=false;
            var registry=new ProviderRegistry(); var provider=new NoReadbackProvider();
            var providers=(System.Collections.Generic.List<IProviderAdapter>)typeof(ProviderRegistry).GetField("_providers",BindingFlags.NonPublic|BindingFlags.Instance).GetValue(registry);
            providers.Clear(); providers.Add(provider);
            var gateway=new OMNIX.Core.AiGateway.AiGateway(registry);
            var host=new FakeHost { AllowWrites=true }; int confirmations=0;
            var executor=new ToolExecutor { WriteConfirmation=preview=> { confirmations++; return Task.FromResult(true); } };
            var result=gateway.ChatAsync(new ChatRequest { UserTurn=new ChatTurn { Role=ChatRole.User,Text="Write done into A1 in this Excel file" } },host,part=>{},executor,CancellationToken.None).GetAwaiter().GetResult();
            Check(confirmations==1 && host.Writes==1,"Verification enforcement repeated or skipped the approved write");
            Check(provider.Calls==4,"Verification enforcement did not perform bounded repair attempts");
            Check(result.Text.Contains("could not be verified") || result.Text.Contains("runtime stopped safely"),"Unverified write was incorrectly reported as completed");
        } finally { settings.SelectedProviderId=oldProvider; settings.Privacy=oldPrivacy; settings.PreferLocalWhenAvailable=oldLocal; }
    }

    static void AccessRecoveryRegression() {
        var settings=SettingsManager.Instance.Settings;
        var oldProvider=settings.SelectedProviderId; var oldPrivacy=settings.Privacy; bool oldLocal=settings.PreferLocalWhenAvailable;
        try {
            settings.SelectedProviderId="custom"; settings.Privacy=PrivacyMode.CloudAllowed; settings.PreferLocalWhenAvailable=false;
            foreach(bool cancel in new[]{false,true}) {
                var registry=new ProviderRegistry(); var provider=new AccessProvider { CancelScenario=cancel };
                var providers=(System.Collections.Generic.List<IProviderAdapter>)typeof(ProviderRegistry).GetField("_providers",BindingFlags.NonPublic|BindingFlags.Instance).GetValue(registry);
                providers.Clear(); providers.Add(provider);
                var gateway=new OMNIX.Core.AiGateway.AiGateway(registry);
                var host=new FakeHost { AllowWrites=true }; int confirmations=0;
                var executor=new ToolExecutor { WriteConfirmation=preview=> { confirmations++; return Task.FromResult(!cancel); } };
                var result=gateway.ChatAsync(new ChatRequest { UserTurn=new ChatTurn { Role=ChatRole.User,Text="Create a test table" } },host,part=>{},executor,CancellationToken.None).GetAwaiter().GetResult();
                Check(confirmations==1 && host.Writes==(cancel ? 0 : 1),"Recovery bypassed confirmation or failed to execute approved write");
                Check(provider.Calls==(cancel ? 2 : 4),"Recovery retried cancelled write or skipped required read-back");
                if(!cancel) {
                    Check(host.Reads>=2,"Recovery path did not read back the successful write");
                    Check(result.Text=="Verified completed","Gateway did not return corrected final answer after verification");
                }
            }
        } finally { settings.SelectedProviderId=oldProvider; settings.Privacy=oldPrivacy; settings.PreferLocalWhenAvailable=oldLocal; }
    }
    static void OperationProgressRegression() {
        var phases=new List<string>(); var host=new FakeHost();
        var executor=new ToolExecutor { OperationProgress=(operation,phase)=>phases.Add(phase) };
        var call=new ToolCall {Name=ToolNames.ReadDocumentMap,ArgumentsJson="{}"};
        Check(executor.ExecuteAsync(call,host).GetAwaiter().GetResult().Success,"Read failed with progress observer");
        Check(string.Join(",",phases)=="inspect,complete","Read progress must follow actual execution");
        phases.Clear(); call.ArgumentsJson="{\"offset\":-1}";
        Check(!executor.ExecuteAsync(call,host).GetAwaiter().GetResult().Success,"Invalid read accepted");
        Check(string.Join(",",phases)=="inspect,failed","Failure was displayed as successful");
        int reads=host.Reads;
        using(var cts=new CancellationTokenSource()) {
            executor.OperationProgress=(operation,phase)=>{ if(phase=="inspect") cts.Cancel(); };
            call.ArgumentsJson="{}";
            try { executor.ExecuteAsync(call,host,cts.Token).GetAwaiter().GetResult(); throw new Exception("Cancelled operation ran"); }
            catch(OperationCanceledException) {}
        }
        Check(host.Reads==reads,"Cancellation after progress crossed host boundary");
        executor.OperationProgress=(operation,phase)=>{ throw new InvalidOperationException("UI observer unavailable"); };
        Check(executor.ExecuteAsync(call,host).GetAwaiter().GetResult().Success,"UI observer failure broke real operation");
        string language=SettingsManager.Instance.Settings.UiLanguage;
        SettingsManager.Instance.Settings.UiLanguage="en";
        var view=new OMNIX.Core.Ui.ChatView(); view.SetBusy(true);
        for(int i=0;i<100;i++) view.ShowOperation("read_selection","inspect");
        var history=(System.Windows.Controls.TextBox)view.FindName("ExecutionHistory");
        Check(history.Text.Split(new[]{Environment.NewLine},StringSplitOptions.None).Length==80,"Operation history must be bounded");
        view.ShowOperation("read_selection","failed");
        Check(((System.Windows.Controls.TextBlock)view.FindName("ExecutionText")).Text.Contains("failed"),"Failed tool state not visible");
        view.SetBusy(false); string ended=history.Text; view.ShowOperation("late","apply");
        Check(history.Text==ended,"Late progress changed finished request");
        view.SetBusy(true); Check(history.Text.Length==0,"New request retained old operation history");
        view.ShowOperation("request","waiting"); view.SetBusy(false);
        Check(!((System.Windows.Controls.TextBlock)view.FindName("ExecutionText")).Text.Contains("Waiting"),"Completed request still displayed waiting for model");
        SettingsManager.Instance.Settings.UiLanguage=language;
    }
    static void CapabilityRegression() {
        var host=new FakeHost(); var executor=new ToolExecutor();
        var accessCall = new ToolCall { Name=ToolNames.ReadOfficeAccess, ArgumentsJson="{}" };
        var accessResult = executor.ExecuteAsync(accessCall,host).GetAwaiter().GetResult();
        Check(accessResult.Success && accessResult.ContentForModel.Contains("confirmationHandlerAvailable=False") && host.AccessReads==1,"Access probe must disclose missing confirmation handler");
        executor.WriteConfirmation = preview => Task.FromResult(true);
        Check(executor.ExecuteAsync(accessCall,host).GetAwaiter().GetResult().ContentForModel.Contains("confirmationHandlerAvailable=True"),"Access probe did not reflect available confirmation");
        executor.RequestScopeValidator = () => false;
        try { executor.ExecuteAsync(accessCall,host).GetAwaiter().GetResult(); throw new Exception("Stale access probe allowed"); } catch(OperationCanceledException) {}
        Check(host.AccessReads==2,"Access probe crossed stale document boundary");
        executor.RequestScopeValidator = () => true;
        var claim = typeof(OMNIX.Core.AiGateway.AiGateway).GetMethod("IsUnsupportedAccessClaim",System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Static);
        Check((bool)claim.Invoke(null,new object[]{"\u062f\u0633\u062a\u0631\u0633\u06cc \u0646\u0648\u0634\u062a\u0646 \u0628\u0647 \u0641\u0627\u06cc\u0644 \u0641\u0639\u0627\u0644 \u062f\u0631 \u0627\u06cc\u0646 \u0646\u0634\u0633\u062a \u062f\u0631 \u062f\u0633\u062a\u0631\u0633 \u0646\u06cc\u0633\u062a"}),"Reported Persian access denial not recognized");
        Check((bool)claim.Invoke(null,new object[]{"Write access is unavailable"}),"English access denial not recognized");
        Check(!(bool)claim.Invoke(null,new object[]{"The table was created"}),"Normal answer misclassified as denial");
        var detector=typeof(OMNIX.Core.AiGateway.AiGateway).Assembly.GetType("OMNIX.Core.AiGateway.MutationIntentDetector",true);
        var detect=detector.GetMethod("IsLikelyMutation",BindingFlags.Public|BindingFlags.Static);
        Check((bool)detect.Invoke(null,new object[]{"در فایل اکسل شیت محصولات را بساز ولی اطلاعات قبلی را حذف نکن"}),"Persian build intent was not enforced");
        Check(!(bool)detect.Invoke(null,new object[]{"فقط بررسی کن، هیچ تغییری نده"}),"Read-only Persian request misclassified as mutation");
        Check(ToolNames.Normalize("omnix.write_to_cell")==ToolNames.WriteToCell && ToolNames.Normalize("write-to-cell")==ToolNames.WriteToCell,"Tool namespace normalization failed");
        var map=new ToolCall { Name=ToolNames.ReadDocumentMap,ArgumentsJson="{\"offset\":20}" };
        Check(executor.ExecuteAsync(map,host).GetAwaiter().GetResult().Success && host.Reads==1,"Map navigation failed");
        var section=new ToolCall { Name=ToolNames.ReadDocumentSection,ArgumentsJson="{}" };
        Check(executor.ExecuteAsync(section,host).GetAwaiter().GetResult().Success && host.Reads==2,"Section navigation failed");
        executor.RequestScopeValidator=()=>false;
        try { executor.ExecuteAsync(section,host).GetAwaiter().GetResult(); throw new Exception("Stale navigation was allowed"); }
        catch(OperationCanceledException) {}
        Check(host.Reads==2,"Stale request read another document");
        executor.RequestScopeValidator=()=>true;
        map.ArgumentsJson="{\"offset\":-1}";
        Check(!executor.ExecuteAsync(map,host).GetAwaiter().GetResult().Success && host.Reads==2,"Invalid offset crossed host boundary");
        string valid="{\"sheet\":\"Products\",\"headers\":[\"ID\",\"Price\"],\"rows\":[[\"001\",12.5]]}";
        Check(ExcelTableBuilder.ValidatePlan(valid)!=null,"Valid table rejected");
        string typed="{\"sheet\":\"Report\",\"uniqueName\":true,\"headers\":[\"Formula\",\"Date\"],\"rows\":[[{\"formula\":\"=1+1\",\"numberFormat\":\"0\"},{\"date\":\"2026-09-21\"}]]}";
        Check(ExcelTableBuilder.ValidatePlan(typed)!=null,"Typed formula/date table rejected");
        bool badTypedRejected=false; try { ExcelTableBuilder.ValidatePlan(typed.Replace("=1+1","1+1")); } catch { badTypedRejected=true; }
        Check(badTypedRejected,"Non-formula typed cell accepted");
        foreach(string invalid in new[]{valid.Replace("Products","Bad/Name"),valid.Replace("Price","ID"),valid.Replace("12.5]","12.5,4]"),"{}",new string('x',32001)}) {
            bool rejected=false; try { ExcelTableBuilder.ValidatePlan(invalid); } catch { rejected=true; }
            Check(rejected,"Invalid table plan accepted");
        }
        var mixed=Newtonsoft.Json.Linq.JObject.Parse("{\"sheet\":\"Mixed\",\"headers\":[\"ID\",\"Number\",\"Bool\",\"Date\",\"Formula\",\"Empty\"],\"rows\":[[\"001\",12.5,false,{\"date\":\"2026-10-06\"},{\"formula\":\"=1+1\"},null],[\"002\",0,true,{\"date\":\"2026-10-06\"},{\"formula\":\"=3+2\"},null]]}");
        var batches=ExcelCellBatch.Build(mixed);
        Check(batches.Count==6,"Homogeneous mixed columns were not batched");
        Check(batches[0].NumberFormat=="@" && !batches[0].IsFormula,"Identifiers lost literal text semantics");
        double date=new DateTime(2026,10,6).ToOADate();
        object[,] values={{"001",12.5,false,date,2.0,null},{"002",0.0,true,date,5.0,null}};
        object[,] formulas={{"001",12.5,false,date,"=1+1",null},{"002",0.0,true,date,"=3+2",null}};
        ExcelCellBatch.Verify(mixed,values,formulas,b=>b.IsFormula);
        var comValues=Array.CreateInstance(typeof(object),new[]{2,6},new[]{1,1});
        var comFormulas=Array.CreateInstance(typeof(object),new[]{2,6},new[]{1,1});
        for(int y=0;y<2;y++)for(int x=0;x<6;x++){comValues.SetValue(values[y,x],y+1,x+1);comFormulas.SetValue(formulas[y,x],y+1,x+1);}
        ExcelCellBatch.Verify(mixed,comValues,comFormulas,b=>b.IsFormula);
        values[0,1]="12.5";
        bool numericText=false;try{ExcelCellBatch.Verify(mixed,values,formulas,b=>b.IsFormula);}catch(InvalidOperationException){numericText=true;}
        Check(numericText,"Numeric text was accepted as a real number in batch read-back"); values[0,1]=12.5;
        bool lostFormula=false;try{ExcelCellBatch.Verify(mixed,values,formulas,b=>false);}catch(InvalidOperationException){lostFormula=true;}
        Check(lostFormula,"Literal formula text was accepted as a native formula");
        bool badDimensions=false;try{ExcelCellBatch.Verify(mixed,new object[1,6],formulas,b=>b.IsFormula);}catch(InvalidOperationException){badDimensions=true;}
        Check(badDimensions,"Partial Office read-back was accepted as full data");
        var large=new Newtonsoft.Json.Linq.JObject(); large["sheet"]="Large";
        var largeHeaders=new Newtonsoft.Json.Linq.JArray();for(int i=0;i<10;i++)largeHeaders.Add("C"+i);large["headers"]=largeHeaders;
        var largeRows=new Newtonsoft.Json.Linq.JArray();for(int y=0;y<50;y++){var row=new Newtonsoft.Json.Linq.JArray();for(int x=0;x<10;x++)row.Add(y*10+x);largeRows.Add(row);}large["rows"]=largeRows;
        Check(ExcelCellBatch.Build(large).Count==10,"500 numeric cells require more than ten writes");
        Check(ExcelCellBatch.MatrixCell(42.0,0,0,1,1).Equals(42.0),"Single-cell scalar read-back rejected");
        string prompt=SystemPromptBuilder.Build(host,host.ReadContext());
        Check(prompt.Contains("RUNTIME IDENTITY") && prompt.Contains("ACTIVE OFFICE HOST: Excel") &&
              prompt.Contains("read_document_section") && prompt.Contains("create_data_table") &&
              prompt.Contains("format_range"),"Professional host capabilities/runtime identity missing from prompt");
        Check(ToolNames.IsWhitelisted(ToolNames.FormatRange) && ToolNames.IsWriteTool(ToolNames.FormatRange),"format_range must remain inside confirmed write boundary");
        Check(ToolNames.IsWhitelisted(ToolNames.ListOfficeCapabilities) && !ToolNames.IsWriteTool(ToolNames.ListOfficeCapabilities),"capability discovery must be read-only");
        Check(ToolNames.IsWhitelisted(ToolNames.ExecuteOfficeCapability) && ToolNames.IsWriteTool(ToolNames.ExecuteOfficeCapability),"capability execution must remain inside confirmed write boundary");
        Check(OfficeCapabilityRegistry.ForHost(HostType.Excel).Count >= 85,"Excel capability catalog is unexpectedly narrow");
        Check(OfficeCapabilityRegistry.ForHost(HostType.Word).Count >= 64,"Word capability catalog is unexpectedly narrow");
        Check(OfficeCapabilityRegistry.ForHost(HostType.PowerPoint).Count >= 51,"PowerPoint capability catalog is unexpectedly narrow");
        Check(OfficeCapabilityRegistry.Search(HostType.Excel,"chart",0).Contains("chart.create") &&
              OfficeCapabilityRegistry.Search(HostType.Excel,"chart",0).Contains("chart.source") &&
              OfficeCapabilityRegistry.Search(HostType.Excel,"conditional",0).Contains("conditional.formula"),"Excel advanced capability discovery failed");
        Check(OfficeCapabilityRegistry.Search(HostType.Word,"review",0).Contains("review.track_changes") &&
              OfficeCapabilityRegistry.Search(HostType.Word,"content",0).Contains("content_control.add") &&
              OfficeCapabilityRegistry.Search(HostType.Word,"highlight",0).Contains("selection.highlight"),"Word advanced capability discovery failed");
        Check(OfficeCapabilityRegistry.Search(HostType.PowerPoint,"animation",0).Contains("animation.fade") &&
              OfficeCapabilityRegistry.Search(HostType.PowerPoint,"table",0).Contains("table.cell_format") &&
              OfficeCapabilityRegistry.Search(HostType.PowerPoint,"margins",0).Contains("text.margins"),"PowerPoint advanced capability discovery failed");
        Check(prompt.Contains("list_office_capabilities") && prompt.Contains("execute_office_capability"),"Capability engine missing from model prompt");
        Check(!prompt.Contains("rewrite_selected_text {text}"),"Foreign host write tool advertised");
        using(var controller=new WorkspaceController(host,new ChatHistoryStore())) {
            var method=typeof(WorkspaceController).GetMethod("RunOnUiThread",BindingFlags.Instance|BindingFlags.NonPublic).MakeGenericMethod(typeof(bool));
            int uiThread=Thread.CurrentThread.ManagedThreadId;
            Func<bool> action=()=>Thread.CurrentThread.ManagedThreadId==uiThread;
            var same=(Task<bool>)method.Invoke(controller,new object[]{action});
            Check(same.GetAwaiter().GetResult(),"Office pane UI callback failed without Application.Current");
            var background=Task.Run(async ()=> await (Task<bool>)method.Invoke(controller,new object[]{action}));
            var deadline=Stopwatch.StartNew();
            while(!background.IsCompleted && deadline.ElapsedMilliseconds<5000) {
                var frame=new DispatcherFrame();
                Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.Background,new Action(()=>frame.Continue=false));
                Dispatcher.PushFrame(frame);
            }
            Check(background.IsCompleted && background.GetAwaiter().GetResult(),"Background callback missed pane dispatcher");
        }
    }
    static void TransportRegression() {
        // Actual HTTP transport against a loopback fixture: no provider account or secret.
        foreach(bool anthropic in new[]{false,true}) foreach(int responseMode in new[]{0,1,2}) {
            bool streaming=responseMode != 0;
            bool serverStreams=responseMode == 1;
            var portPicker=new TcpListener(IPAddress.Loopback,0); portPicker.Start();
            int port=((IPEndPoint)portPicker.LocalEndpoint).Port; portPicker.Stop();
            using(var server=new HttpListener()) using(var timeout=new CancellationTokenSource(5000)) {
                string origin="http://127.0.0.1:"+port; server.Prefixes.Add(origin+"/"); server.Start();
                var serving=Task.Run(async ()=> {
                    var context=await server.GetContextAsync();
                    Check(context.Request.Url.AbsolutePath==(anthropic?"/v1/messages":"/v1/chat/completions"),"Wrong chat route");
                    Check(anthropic ? context.Request.Headers["x-api-key"]=="fixture-key" && context.Request.Headers["anthropic-version"]=="2023-06-01" : context.Request.Headers["Authorization"]=="Bearer fixture-key","Wrong provider auth headers");
                    using(var reader=new StreamReader(context.Request.InputStream)) {
                        string body=await reader.ReadToEndAsync(); Check(body.Contains("fixture-model") && body.Contains("Reply with OK."),"Diagnostic lost model or text");
                    }
                    string reply=serverStreams
                        ? (anthropic ? "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"OK\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n" : "data: {\"choices\":[{\"delta\":{\"content\":\"OK\"}}]}\n\ndata: [DONE]\n\n")
                        : (anthropic ? "{\"content\":[{\"type\":\"text\",\"text\":\"OK\"}]}" : "{\"choices\":[{\"message\":{\"content\":\"OK\"}}]}");
                    byte[] bytes=Encoding.UTF8.GetBytes(reply); context.Response.ContentType=serverStreams?"text/event-stream":"application/json";
                    context.Response.ContentLength64=bytes.Length; await context.Response.OutputStream.WriteAsync(bytes,0,bytes.Length); context.Response.Close();
                });
                var client=new CustomOpenAiCompatibleAdapter();
                SettingsManager.Instance.Settings.EndpointConfig("custom").ApiType=anthropic?"OpenAI":"Anthropic";
                client.Configure(new ProviderCredentials {BaseUrl=origin+"/v1",ApiKey="fixture-key",Model="fixture-model",ApiType=anthropic?"Anthropic":"OpenAI"});
                var text=new StringBuilder(); Action<string> delta=streaming ? new Action<string>(x=>text.Append(x)) : null;
                var answer=client.SendAsync(new ChatRequest{UserTurn=new ChatTurn{Role=ChatRole.User,Text="Reply with OK."}},delta,timeout.Token).GetAwaiter().GetResult();
                serving.GetAwaiter().GetResult();
                Check(answer.Text=="OK" && (!streaming || text.ToString()=="OK"),"Protocol response parsing failed");
            }
        }

        // Native tool transport contract: real tools/functionDeclarations must cross the provider
        // boundary and come back as structured ProviderToolCall objects, never only prompt text.
        foreach(bool anthropic in new[]{false,true}) foreach(int responseMode in new[]{0,1,2}) {
            bool streaming=responseMode != 0;
            bool serverStreams=responseMode == 1;
            var portPicker=new TcpListener(IPAddress.Loopback,0); portPicker.Start();
            int port=((IPEndPoint)portPicker.LocalEndpoint).Port; portPicker.Stop();
            using(var server=new HttpListener()) using(var timeout=new CancellationTokenSource(5000)) {
                string origin="http://127.0.0.1:"+port; server.Prefixes.Add(origin+"/"); server.Start();
                var serving=Task.Run(async ()=> {
                    var context=await server.GetContextAsync();
                    using(var reader=new StreamReader(context.Request.InputStream)) {
                        string body=await reader.ReadToEndAsync();
                        Check(body.Contains("\"tools\"") && body.Contains("omnix_tool") && body.Contains("write_to_cell"),"Native tool schema missing from provider request");
                    }

                    string reply;
                    if(!serverStreams && !anthropic)
                        reply="{\"choices\":[{\"message\":{\"content\":null,\"tool_calls\":[{\"id\":\"call1\",\"type\":\"function\",\"function\":{\"name\":\"omnix_tool\",\"arguments\":\"{\\\"tool\\\":\\\"write_to_cell\\\",\\\"args\\\":{\\\"sheet\\\":\\\"Sheet1\\\",\\\"address\\\":\\\"B2\\\",\\\"value\\\":42}}\"}}]}}]}";
                    else if(serverStreams && !anthropic)
                        reply="data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call1\",\"function\":{\"name\":\"omnix_tool\",\"arguments\":\"{\\\"tool\\\":\\\"write_to_cell\\\",\\\"args\\\":{\\\"sheet\\\":\\\"Sheet1\\\",\\\"address\\\":\\\"B2\\\",\\\"value\\\":42}}\"}}]}}]}\n\ndata: [DONE]\n\n";
                    else if(!serverStreams)
                        reply="{\"content\":[{\"type\":\"tool_use\",\"id\":\"tool1\",\"name\":\"omnix_tool\",\"input\":{\"tool\":\"write_to_cell\",\"args\":{\"sheet\":\"Sheet1\",\"address\":\"B2\",\"value\":42}}}]}";
                    else
                        reply="data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool1\",\"name\":\"omnix_tool\",\"input\":{}}}\n\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"tool\\\":\\\"write_to_cell\\\",\\\"args\\\":{\\\"sheet\\\":\\\"Sheet1\\\",\\\"address\\\":\\\"B2\\\",\\\"value\\\":42}}\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n";

                    byte[] bytes=Encoding.UTF8.GetBytes(reply);
                    context.Response.ContentType=serverStreams?"text/event-stream":"application/json";
                    context.Response.ContentLength64=bytes.Length;
                    await context.Response.OutputStream.WriteAsync(bytes,0,bytes.Length);
                    context.Response.Close();
                });

                var client=new OpenAiCompatibleClient(origin+"/v1","Fixture",null,anthropic);
                Action<string> delta=streaming ? new Action<string>(x=>{}) : null;
                var answer=client.SendAsync(
                    new ChatRequest{UseNativeTools=true,UserTurn=new ChatTurn{Role=ChatRole.User,Text="Create it."}},
                    "fixture-key","fixture-model",delta,timeout.Token).GetAwaiter().GetResult();
                serving.GetAwaiter().GetResult();
                Check(answer.HasToolCalls && answer.ToolCalls.Count==1,"Native provider tool call was not materialized");
                Check(answer.ToolCalls[0].Name=="write_to_cell" && answer.ToolCalls[0].ArgumentsJson.Contains("\"value\":42"),"Native tool call decoded incorrectly");
            }
        }
    }
    sealed class SlowProvider : IProviderAdapter {
        public int TransportThread;
        public ProviderInfo Info { get { return new ProviderInfo {Id="custom",Kind=ProviderKind.Cloud,DisplayName="Slow fixture"}; } }
        public void Configure(ProviderCredentials c) {}
        public bool SupportsVisionNow() { return false; }
        public Task<IReadOnlyList<string>> ListModelsAsync(CancellationToken ct) { return Task.FromResult<IReadOnlyList<string>>(new string[0]); }
        public Task<bool> TestConnectionAsync(CancellationToken ct) { return Task.FromResult(true); }
        public Task<ChatResponse> SendAsync(ChatRequest request,Action<string> delta,CancellationToken ct) {
            TransportThread=Thread.CurrentThread.ManagedThreadId;
            Thread.Sleep(250); // Deliberately synchronous provider setup must not freeze Office.
            for(int i=0;i<2000;i++) if(delta!=null) delta("x");
            return Task.FromResult(new ChatResponse {Text="Done"});
        }
    }
    static void ResponsiveGatewayRegression() {
        var settings=SettingsManager.Instance.Settings;
        string old=settings.SelectedProviderId; var privacy=settings.Privacy;
        settings.SelectedProviderId="custom"; settings.Privacy=PrivacyMode.CloudAllowed;
        int owner=Thread.CurrentThread.ManagedThreadId, ticks=0;
        var heartbeat=new DispatcherTimer { Interval=TimeSpan.FromMilliseconds(10) };
        heartbeat.Tick+=(sender,args)=>ticks++; heartbeat.Start();
        try {
            var registry=new ProviderRegistry(); var provider=new SlowProvider();
            var list=(List<IProviderAdapter>)typeof(ProviderRegistry).GetField("_providers",BindingFlags.NonPublic|BindingFlags.Instance).GetValue(registry);
            list.Clear(); list.Add(provider);
            var gateway=new OMNIX.Core.AiGateway.AiGateway(registry);
            var runner=typeof(WorkspaceController).Assembly.GetType("OMNIX.Core.Ui.OfficeUi").GetMethod("RunAsync",BindingFlags.Public|BindingFlags.Static);
            Func<Task> work=async ()=> {
                await gateway.ChatAsync(new ChatRequest {UserTurn=new ChatTurn {Role=ChatRole.User,Text="Hello"}},new FakeHost(),part=>{},new ToolExecutor(),CancellationToken.None);
                Check(Thread.CurrentThread.ManagedThreadId==owner,"Gateway continuation left Office STA");
            };
            var task=(Task)runner.Invoke(null,new object[]{Dispatcher.CurrentDispatcher,work});
            var deadline=Stopwatch.StartNew();
            while(!task.IsCompleted && deadline.ElapsedMilliseconds<5000) {
                var frame=new DispatcherFrame();
                Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.Background,new Action(()=>frame.Continue=false));
                Dispatcher.PushFrame(frame);
            }
            Check(task.IsCompleted,"Responsive gateway timed out"); task.GetAwaiter().GetResult();
            Check(ticks>=2 && provider.TransportThread!=owner,"Provider work blocked Office heartbeat");
        } finally {heartbeat.Stop(); settings.SelectedProviderId=old; settings.Privacy=privacy;}
    }
    static void CatalogRoutesRegression() {
        var portListener=new TcpListener(IPAddress.Loopback,0); portListener.Start();
        int port=((IPEndPoint)portListener.LocalEndpoint).Port; portListener.Stop();
        using(var server=new HttpListener()) using(var timeout=new CancellationTokenSource(5000)) {
            string origin="http://127.0.0.1:"+port; server.Prefixes.Add(origin+"/"); server.Start();
            var serving=Task.Run(async ()=> {
                var context=await server.GetContextAsync();
                Check(context.Request.Url.AbsolutePath=="/accounts/test/ai/models/search","Cloudflare discovery used wrong route");
                Check(context.Request.QueryString["format"]=="openrouter" && context.Request.QueryString["page"]=="1","Cloudflare query missing");
                Check(context.Request.Headers["Authorization"]=="Bearer fixture-key","Catalog auth missing");
                byte[] bytes=Encoding.UTF8.GetBytes("{\"data\":[{\"id\":\"@cf/test\"}]}");
                context.Response.ContentType="application/json"; context.Response.ContentLength64=bytes.Length;
                await context.Response.OutputStream.WriteAsync(bytes,0,bytes.Length); context.Response.Close();
            });
            var client=new OpenAiCompatibleClient(origin+"/accounts/test/ai/v1","Cloudflare fixture",catalogPath:"../models/search?format=openrouter&per_page=100",pagedCatalog:true);
            var models=client.ListModelsAsync("fixture-key",timeout.Token).GetAwaiter().GetResult();
            serving.GetAwaiter().GetResult(); Check(models.Count==1 && models[0]=="@cf/test","Cloudflare catalog decode failed");
        }
    }
    static void AsyncContextRegression() {
        SynchronizationContext.SetSynchronizationContext(null);
        int owner=Thread.CurrentThread.ManagedThreadId;
        var bubble=new ChatBubble(new ChatTurn {Role=ChatRole.Assistant,Text="test"});
        var runner=typeof(WorkspaceController).Assembly.GetType("OMNIX.Core.Ui.OfficeUi").GetMethod("RunAsync",BindingFlags.Public|BindingFlags.Static);
        foreach(bool fail in new[]{false,true}) {
            bool caught=false,finalized=false;
            Func<Task> work=async ()=> {
                try {
                    await Task.Delay(25);
                    Check(Thread.CurrentThread.ManagedThreadId==owner,"Async continuation left Office dispatcher");
                    bubble.ReplaceText("پاسخ **خوانا**");
                    if(fail) throw new InvalidOperationException("synthetic failure");
                } catch(InvalidOperationException) { caught=true; bubble.ReplaceText("Handled"); }
                finally { Check(Thread.CurrentThread.ManagedThreadId==owner,"Finally left Office dispatcher"); finalized=true; }
            };
            var task=(Task)runner.Invoke(null,new object[]{Dispatcher.CurrentDispatcher,work});
            var timer=Stopwatch.StartNew();
            while(!task.IsCompleted && timer.ElapsedMilliseconds<5000) {
                var frame=new DispatcherFrame();
                Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.Background,new Action(()=>frame.Continue=false));
                Dispatcher.PushFrame(frame);
            }
            Check(task.IsCompleted,"Dispatcher async test timed out"); task.GetAwaiter().GetResult();
            Check(finalized && caught==fail,"Async error recovery failed");
        }
        Check(CustomOpenAiCompatibleAdapter.NormalizeBaseUrl("https://example.org")=="https://example.org/v1","Root URL routing failed");
        Check(CustomOpenAiCompatibleAdapter.NormalizeBaseUrl("https://example.org/proxy/v1/messages")=="https://example.org/proxy/v1","Anthropic path normalization failed");
        var anthropic=new OpenAiCompatibleClient("https://example.org/v1","Fixture",null,true);
        anthropic.SetModel("fixture-model");
        string payload=anthropic.BuildPayload(new ChatRequest{SystemPrompt="Office context",UserTurn=new ChatTurn{Role=ChatRole.User,Text="Hello"}},false);
        Check(payload.Contains("\"max_tokens\":4096") && payload.Contains("\"system\":\"Office context\"") && !payload.Contains("\"role\":\"system\""),"Anthropic payload format invalid");
        string nativeAnthropic=anthropic.BuildPayload(new ChatRequest{UseNativeTools=true,SystemPrompt="Office context",UserTurn=new ChatTurn{Role=ChatRole.User,Text="Create"}},false);
        Check(nativeAnthropic.Contains("\"tools\"") && nativeAnthropic.Contains("omnix_tool") && nativeAnthropic.Contains("write_to_cell"),"Anthropic native tool schema missing");
        var gemini=new GeminiAdapter();
        string geminiPayload=gemini.BuildPayload(new ChatRequest{UseNativeTools=true,UserTurn=new ChatTurn{Role=ChatRole.User,Text="Create"}},false);
        Check(geminiPayload.Contains("functionDeclarations") && geminiPayload.Contains("omnix_tool") && geminiPayload.Contains("args_json"),"Gemini function declaration missing");
        var ollama=new OllamaAdapter();
        string ollamaPayload=ollama.BuildPayload(new ChatRequest{UseNativeTools=true,UserTurn=new ChatTurn{Role=ChatRole.User,Text="Create"}});
        Check(ollamaPayload.Contains("\"tools\"") && ollamaPayload.Contains("omnix_tool"),"Ollama native tool schema missing");
    }
    [STAThread] static int Main() {
        try {
            // Cold lookup on a background thread before there is a WPF Application or view.
            Exception backgroundError = null;
            var thread = new Thread(() => {
                try { Check(Strings.T("S.Tab.Chat") == "Chat", "Cold background localization failed"); }
                catch (Exception ex) { backgroundError = ex; }
            });
            thread.SetApartmentState(ApartmentState.MTA); thread.Start();
            Check(thread.Join(10000), "Cold localization timed out");
            if (backgroundError != null) throw backgroundError;
            Check(Application.Current == null, "Test must model Office without a WPF Application");
            var xmlCall = OMNIX.Core.Tools.ToolCallParser.Parse("Checking...<tool_call>omnix_tool\n{\"tool\":\"read_document_section\",\"args\":{\"sheet\":\"test\"}}</tool_call>");
            Check(xmlCall != null && xmlCall.Name == "read_document_section", "XML tool call not parsed");
            Check(OMNIX.Core.Tools.ToolCallParser.Parse("```omnix_tool {\"tool\":\"read_selection\"}```").Name == "read_selection", "Inline fenced call not parsed");
            var nativeCall = OMNIX.Core.Tools.ToolCallParser.Parse("<|tool_call_start|>[write_to_cell(sheet='Sheet1', address='B2', value='کد محصول')]<|tool_call_end|>");
            Check(nativeCall != null && nativeCall.Name == "write_to_cell" && nativeCall.ArgumentsJson.Contains("کد محصول"), "Provider-native tool call not parsed");
            var nativeTable = OMNIX.Core.Tools.ToolCallParser.Parse("<|tool_call_start|>[create_data_table(sheet='محصولات', uniqueName=True, headers=['کد','وزن'], rows=[['T001',3]])]<|tool_call_end|>");
            Check(nativeTable != null && nativeTable.Name == "create_data_table" && nativeTable.ArgumentsJson.Contains("\"uniqueName\":true"), "Nested native table arguments not parsed");
            var namespacedFallback = OMNIX.Core.Tools.ToolCallParser.Parse("[omnix.write_to_cell(sheet='Sheet1', address='A1', value='x')]");
            Check(namespacedFallback != null && namespacedFallback.Name == "write_to_cell", "Namespaced text-fallback tool name was not normalized before whitelist");
            Check(OMNIX.Core.Tools.ToolCallParser.Parse("<tool_call>broken").Name == "", "Incomplete call must fail closed");
            Check(OMNIX.Core.Tools.ToolCallParser.Parse("plain answer") == null, "Plain answer treated as a tool");
            Check(OMNIX.Core.Tools.ToolCallParser.Parse("<tool_call>{\"tool\":\"read_selection\"}</tool_call><tool_call>{}</tool_call>").Name == "", "Ambiguous calls accepted");
            var filterType = typeof(OMNIX.Core.Tools.ToolCallParser).Assembly.GetType("OMNIX.Core.AiGateway.ToolProtocolDeltaFilter", true);
            foreach (string protocol in new[] { "<tool_call>omnix_tool\n{}\n</tool_call>", "```omnix_tool\n{}\n```", "<|tool_call_start|>[read_selection()]<|tool_call_end|>" })
            {
                var visible = new System.Text.StringBuilder();
                var filter = Activator.CreateInstance(filterType, new object[] { new Action<string>(part => visible.Append(part)) });
                foreach (char ch in "Visible prefix " + protocol)
                    filterType.GetMethod("OnDelta").Invoke(filter, new object[] { ch.ToString() });
                filterType.GetMethod("Complete").Invoke(filter, new object[] { false, protocol });
                Check(visible.ToString() == "Visible prefix ", "Split tool protocol leaked into chat");
            }
            Check(OMNIX.Core.Reference.OfficeReference.Search("Excel", "DSUM").Contains("functions/dsum-function"), "Reference catalog missing DSUM");
            string faReference = OMNIX.Core.Reference.OfficeReference.Search("Excel", "SUM", 0, "fa");
            string enReference = OMNIX.Core.Reference.OfficeReference.Search("Excel", "SUM", 0, "en");
            Check(!string.IsNullOrWhiteSpace(faReference) && faReference != enReference && faReference.Contains("Excel") && faReference.Contains("Microsoft"), "Persian reference mode missing");
            Check(OmnixSettings.CreateDefaults().Privacy==PrivacyMode.CloudAllowed,"Fresh install cloud default incorrect");
            var titled=ExcelTableBuilder.ValidatePlan("{\"sheet\":\"Gold\",\"title\":\"Shop\",\"headers\":[\"Weight\",\"Total\"],\"rows\":[[5,{\"formula\":\"=A5*2\"}]]}");
            Check(ExcelTableBuilder.HeaderRow(titled)==4,"Separate heading did not reserve rows above table");
            try { ExcelTableBuilder.ValidatePlan("{\"sheet\":\"Gold\",\"title\":\"Shop\",\"startRow\":1,\"headers\":[\"A\"],\"rows\":[]}"); throw new Exception("Overlapping heading accepted"); } catch(ArgumentException) {}
            try { ExcelTableBuilder.ValidatePlan("{\"sheet\":\"Gold\",\"headers\":[\"A\"],\"rows\":[[\"=A2*2\"]]}"); throw new Exception("Unevaluated formula string accepted"); } catch(ArgumentException) {}
            Check(OfficeCapabilityRegistry.Exists(HostType.Excel,"sheet.heading"),"Native heading capability unavailable");
            TransportRegression();
            AsyncContextRegression();
            ResponsiveGatewayRegression();
            CatalogRoutesRegression();
            ExecutionPlanRegression();
            TaskLifecycleRegression();
            ScopeIdentityRegression();
            NativeContractGatewayRegression();
            SegmentGatewayRegression();
            ModelEvidenceRegression();
            OperationProgressRegression();
            CapabilityRegression();
            AccessRecoveryRegression();
            NativeGatewayRegression();
            VerificationEnforcementRegression();
            var watch = Stopwatch.StartNew();
            var router = new ProviderRouter(new ProviderRegistry());
            router.BuildCredentials("ollama"); router.BuildCredentials("lmstudio");
            Check(watch.ElapsedMilliseconds < 1000, "Credential construction blocks on discovery");
            for (int i = 0; i < 3; i++) {
                var view = new WorkspaceView(null); // Loads actual compiled BAML, including Checked events.
                view.Resources.MergedDictionaries.Add(Strings.Dictionary);
                ThemeManager.Instance.ApplyTo(view);
                using (var host = new TaskPaneHostControl(view)) {
                    host.Width = 360; host.Height = 640; host.CreateControl();
                    view.Measure(new Size(360, 640)); view.Arrange(new Rect(0, 0, 360, 640)); view.UpdateLayout();
                    var chat = (FrameworkElement)view.FindName("ChatPage");
                    var settings = (FrameworkElement)view.FindName("SettingsPage");
                    var about = (FrameworkElement)view.FindName("AboutPage");
                    Check(chat.Visibility == Visibility.Visible && settings.Visibility == Visibility.Collapsed, "Initial chat visibility wrong");
                    view.ShowSettingsTab();
                    Check(settings.Visibility == Visibility.Visible && chat.Visibility == Visibility.Collapsed, "Settings navigation failed");
                    ((RadioButton)view.FindName("TabAbout")).IsChecked = true;
                    Check(about.Visibility == Visibility.Visible && settings.Visibility == Visibility.Collapsed, "About navigation failed");
                    ((RadioButton)view.FindName("TabChat")).IsChecked = true;
                    Check(chat.Visibility == Visibility.Visible && about.Visibility == Visibility.Collapsed, "Chat navigation failed");
                    Check(view.FindResource("S.Tab.Chat") as string == "Chat", "UI localization failed after background lookup");
                    if(i==0) SettingsRegression(view);
                    var frame = new DispatcherFrame();
                    Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() => frame.Continue = false));
                    Dispatcher.PushFrame(frame);
                }
            }
            Console.WriteLine("PASS: cold background localization; nonblocking credentials; three compiled WPF/ElementHost construction, navigation and dispatcher cycles.");
            return 0;
        } catch (Exception ex) { Console.Error.WriteLine(ex); return 1; }
    }
}
'@
$file = Join-Path $bin 'workspace-startup-test.cs'
$exe = Join-Path $bin 'workspace-startup-test.exe'
$source | Set-Content $file -Encoding UTF8
$refs = @('System.dll','System.Core.dll','System.Xaml.dll','System.Windows.Forms.dll','System.Drawing.dll') | ForEach-Object { Join-Path $framework $_ }
$refs += @('WindowsBase.dll','PresentationCore.dll','PresentationFramework.dll','WindowsFormsIntegration.dll') | ForEach-Object { Join-Path $wpf $_ }
$refs += Join-Path $bin 'OMNIX.Core.dll'
$refs += Join-Path $bin 'Newtonsoft.Json.dll'
$args = @('/nologo','/target:exe',('/out:' + $exe)) + @($refs | ForEach-Object { '/reference:' + $_ }) + @($file)
& (Join-Path $framework 'csc.exe') @args
if ($LASTEXITCODE -ne 0) { throw 'WPF regression harness failed to compile.' }
$stdout = Join-Path $bin 'workspace-startup-test.stdout'
$stderr = Join-Path $bin 'workspace-startup-test.stderr'
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $exe
$info.UseShellExecute = $false
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$p = New-Object Diagnostics.Process
$p.StartInfo = $info
[void]$p.Start()
$outRead = $p.StandardOutput.ReadToEndAsync()
$errRead = $p.StandardError.ReadToEndAsync()
if (-not $p.WaitForExit(30000)) { $p.Kill(); throw 'WPF startup/dispatcher exceeded 30 seconds.' }
$p.WaitForExit()
$outRead.Result | Set-Content $stdout
$errRead.Result | Set-Content $stderr
Get-Content $stdout | Write-Host
Get-Content $stderr | Write-Host
if ($p.ExitCode -ne 0) { throw "WPF startup regression failed ($($p.ExitCode))." }
New-Item -ItemType Directory -Force (Join-Path $root 'build\artifact') | Out-Null
@{TestId='WORKSPACE-STARTUP-WPF-001';OverallPass=$true;Cycles=3;ColdBackgroundLocalization=$true;CredentialConstructionBounded=$true;DarkAndLightDropdownContrastPass=$true;EditableModelBindingPass=$true;OfficePaneDispatcherPass=$true;AsyncContinuationWithoutSynchronizationContextPass=$true;AnthropicPayloadPass=$true;OpenAIAndAnthropicHttpAndStreamingPass=$true;NavigationScopeIsolationPass=$true;TablePlanValidationPass=$true;RealOfficeTested=$false} | ConvertTo-Json | Set-Content (Join-Path $root 'build\artifact\workspace-startup-acceptance.json')

Remove-Item -LiteralPath $file,$exe,$stdout,$stderr -Force
