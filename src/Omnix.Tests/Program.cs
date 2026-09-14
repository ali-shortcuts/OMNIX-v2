using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Omnix.Contracts;
using Omnix.Desktop;
using Omnix.Gateway;
using Omnix.Setup;

namespace Omnix.Tests
{
    internal sealed class FakeHttp : HttpMessageHandler
    {
        public int Count;
        public string Body,Address,Authorization;
        public Func<int,HttpResponseMessage> Reply=n=>new HttpResponseMessage(HttpStatusCode.OK) {Content=new StringContent("{\"choices\":[{\"message\":{\"content\":\"OK\"}}]}")};
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken cancel)
        {
            Count++;Address=request.RequestUri.AbsoluteUri;Authorization=request.Headers.Authorization?.ToString();Body=request.Content==null?null:await request.Content.ReadAsStringAsync();return Reply(Count);
        }
    }
    internal static class Program
    {
        private static readonly List<object> results=new List<object>();
        private static void Assert(bool condition,string message){if(!condition)throw new Exception(message);}
        private static void Test(string name,Action test){test();results.Add(new {Name=name,Passed=true});Console.WriteLine("PASS "+name);}
        private static void Reject(string code,Action action){try{action();throw new Exception("Expected rejection "+code);}catch(UserError e){Assert(e.Code==code,"Wrong error category: "+e.Code);}}
        private static Reply Call(ProviderGateway gateway,Request request)=>gateway.HandleAsync(request,CancellationToken.None).GetAwaiter().GetResult();
        private static SavedSettings Settings(string privacy="Ask before sending",string endpoint="https://provider.example/v1")=>new SavedSettings {Preferences=new Preferences {Privacy=privacy,Selected="test",Providers=new List<Provider>{new Provider {Id="test",Name="Test provider",Model="test-model",Endpoint=endpoint}}},Keys=new Dictionary<string,string>{{"test","synthetic-test-secret"}}};
        private static Request Request(SavedSettings s,string operation="chat",bool approved=false)=>new Request {Operation=operation,ProviderId="test",ExpectedEndpoint=s.Preferences.Providers[0].Endpoint,ExpectedModel=s.Preferences.Providers[0].Model,CloudApproved=approved,Messages=new List<Message>{new Message {Role="user",Text="Hello"}}};
        [STAThread]
        private static int Main(string[] args)
        {
            string output=args.Length>0?args[0]:"artifacts/evidence";Directory.CreateDirectory(output);
            LocalData.TestRoot=Path.Combine(Path.GetTempPath(),"omnix-tests-"+Guid.NewGuid().ToString("N"));
            try {
                Test("Rejected formula preserves the previous successful edit undo",()=>{
                    var app=new FakeExcel();using(var office=new OfficeSelection(app,"Excel")) {
                        using(var first=office.Capture()) {
                            office.Apply(first,"first edit",false);
                            using(var next=office.Capture()) {
                                bool rejected=false;try{office.Apply(next,"=WEBSERVICE(1)",true);}catch(InvalidOperationException){rejected=true;}
                                Assert(rejected,"External formula was accepted.");
                            }
                            office.Undo();Assert((string)app.Selection.Value2=="original","Failed edit corrupted previous undo.");
                        }
                    }
                });
                Test("A changed selection cannot overwrite a user edit",()=>{
                    var app=new FakeExcel();using(var office=new OfficeSelection(app,"Excel"))using(var captured=office.Capture()) {
                        app.Selection.Value2="user edit";bool rejected=false;
                        try{office.Apply(captured,"AI edit",false);}catch(InvalidOperationException){rejected=true;}
                        Assert(rejected&&(string)app.Selection.Value2=="user edit","Stale selection overwrote user content.");
                    }
                });
                Test("History write failure leaves caller revision and persisted content intact",()=>{
                    string host="write-failure-test";
                    var session=ChatHistory.Save(new ChatSession {Host=host},new List<Message>{new Message {Role="user",Text="original"}});
                    int revision=session.Revision;bool failed=false;
                    try {
                        using(var locked=File.Open(Path.Combine(LocalData.Root,"chats.dat"),FileMode.Open,FileAccess.Read,FileShare.Read)) {
                            try{ChatHistory.Save(session,new List<Message>{new Message {Role="user",Text="unsaved"}});}catch(IOException){failed=true;}
                        }
                        Assert(failed&&session.Revision==revision&&session.Messages[0].Text=="original","Failed persistence mutated the caller.");
                        Assert(ChatHistory.List(host).Single().Messages[0].Text=="original","Previous archive was lost.");
                    }finally{ChatHistory.Delete(session.Id);}
                });
                Test("Busy workspace protects input and safely handles disposal during a request",()=>{
                    using(var view=new Workspace(null,"Word","unused")) {
                        var pending=new TaskCompletionSource<bool>();
                        var flags=System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic;
                        var operation=(Task)typeof(Workspace).GetMethod("Run",flags).Invoke(view,new object[]{(Func<Task>)(()=>pending.Task)});
                        var input=(TextBox)typeof(Workspace).GetField("prompt",flags).GetValue(view);
                        Assert(!input.IsEnabled,"Input remained editable while a send could clear it.");
                        view.Dispose();pending.SetCanceled();operation.GetAwaiter().GetResult();view.Dispose();
                        Assert(!input.IsEnabled,"A disposed view was reactivated.");
                    }
                });
                Test("Repeated window activation reuses one workspace",()=>{
                    int created=0;var registry=new WindowWorkspaces<object>(x=>{});
                    object first=registry.GetOrCreate("1:doc-a",()=>{created++;return new object();});
                    Assert(ReferenceEquals(first,registry.GetOrCreate("1:doc-a",()=>{created++;return new object();}))&&created==1,"Duplicate workspace created.");
                });
                Test("Closed windows release only their own workspace",()=>{
                    var released=new List<object>();var registry=new WindowWorkspaces<object>(released.Add);
                    object first=registry.GetOrCreate("1:doc-a",()=>new object());
                    object second=registry.GetOrCreate("2:doc-b",()=>new object());
                    registry.Prune(new[]{"2:doc-b"});
                    Assert(registry.Count==1&&released.Count==1&&ReferenceEquals(released[0],first),"Wrong window released.");
                    registry.Clear();registry.Clear();Assert(released.Count==2&&ReferenceEquals(released[1],second),"Shutdown leaked or double-disposed a workspace.");
                });
                Test("Recycled window handles cannot inherit another document workspace",()=>{
                    int released=0;var registry=new WindowWorkspaces<object>(x=>released++);
                    var old=registry.GetOrCreate("1:doc-a",()=>new object());
                    registry.Prune(new[]{"1:doc-b"});var next=registry.GetOrCreate("1:doc-b",()=>new object());
                    Assert(!ReferenceEquals(old,next)&&released==1,"Old document workspace survived handle reuse.");
                });
                Test("Failed workspace creation remains retryable",()=>{
                    var registry=new WindowWorkspaces<object>(x=>{});
                    try{registry.GetOrCreate("1:doc-a",()=>{throw new InvalidOperationException("Office busy");});}catch(InvalidOperationException){}
                    Assert(registry.Count==0,"Failed workspace was cached.");
                    Assert(registry.GetOrCreate("1:doc-a",()=>new object())!=null,"Recovery failed.");
                });
                Test("Remote requests require consent at gateway boundary",()=>{var s=Settings();var h=new FakeHttp();using(var g=new ProviderGateway(s,x=>{},h)){Reject("CONSENT",()=>Call(g,Request(s)));Assert(h.Count==0,"A blocked request reached HTTP.");}});
                Test("Local-only blocks remote chat, model discovery and probes",()=>{var s=Settings("Local only");var h=new FakeHttp();using(var g=new ProviderGateway(s,x=>{},h)){foreach(var op in new[]{"chat","models","probe"})Reject("PRIVACY",()=>Call(g,Request(s,op,true)));Assert(h.Count==0,"Privacy failed.");}});
                Test("Loopback provider works without cloud consent",()=>{var s=Settings("Local only","http://127.0.0.1:11434/v1");var h=new FakeHttp();using(var g=new ProviderGateway(s,x=>{},h)){Assert(Call(g,Request(s)).Text=="OK","Missing response.");Assert(h.Address=="http://127.0.0.1:11434/v1/chat/completions","Wrong route.");}});
                Test("Changed endpoint invalidates an earlier consent decision",()=>{var s=Settings();var h=new FakeHttp();using(var g=new ProviderGateway(s,x=>{},h)){var r=Request(s,approved:true);r.ExpectedEndpoint="https://other.example/v1";Reject("SETTINGS_CHANGED",()=>Call(g,r));Assert(h.Count==0,"Stale approval was used.");}});
                Test("Probe calls selected model without discovering models",()=>{var s=Settings();var h=new FakeHttp();using(var g=new ProviderGateway(s,x=>{},h)){var r=Request(s,"probe",true);r.Context="private document marker";Assert(Call(g,r).Ok,"Probe failed.");Assert(h.Count==1&&h.Address.EndsWith("/chat/completions"),"Probe did not call inference.");Assert(!h.Body.Contains("private document marker"),"Probe leaked context.");}});
                Test("Cloud authentication and prompt roles serialize correctly",()=>{var s=Settings();var h=new FakeHttp();using(var g=new ProviderGateway(s,x=>{},h)){var r=Request(s,approved:true);r.Context="untrusted example";Call(g,r);Assert(h.Authorization=="Bearer synthetic-test-secret","Authentication missing.");Assert(h.Body.Contains("office_selection_untrusted")&&h.Body.Contains("untrusted example"),"Context boundary missing.");Assert(!h.Body.Contains("synthetic-test-secret"),"Key leaked into body.");}});
                Test("HTTP authentication errors do not expose provider bodies",()=>{var s=Settings();var h=new FakeHttp {Reply=n=>new HttpResponseMessage(HttpStatusCode.Unauthorized){Content=new StringContent("synthetic-test-secret private-document")}};using(var g=new ProviderGateway(s,x=>{},h)){try{Call(g,Request(s,approved:true));throw new Exception("Expected authentication failure.");}catch(UserError e){Assert(e.Code=="AUTH"&&!e.Message.Contains("secret")&&!e.Message.Contains("private-document"),"Unsafe provider error.");}}});
                Test("Manual model survives an empty model catalog",()=>{var s=Settings();var h=new FakeHttp {Reply=n=>new HttpResponseMessage(HttpStatusCode.OK){Content=new StringContent("{\"data\":[]}")}};using(var g=new ProviderGateway(s,x=>{},h)){Assert(Call(g,Request(s,"models",true)).Models.Count==0,"Unexpected catalog.");Assert(Call(g,new Request {Operation="settings"}).Settings.Providers[0].Model=="test-model","Manual model lost.");}});
                Test("Settings redact keys and reject stale cross-window saves",()=>{var s=Settings();using(var g=new ProviderGateway(s,x=>{},new FakeHttp())){var publicSettings=Call(g,new Request {Operation="settings"});Assert(!Wire.Json(publicSettings).Contains("synthetic-test-secret")&&publicSettings.Settings.Providers[0].HasKey,"Public settings exposed or lost secret state.");Call(g,new Request {Operation="save",Settings=publicSettings.Settings});Reject("SETTINGS_CHANGED",()=>Call(g,new Request {Operation="save",Settings=publicSettings.Settings}));}});
                Test("Remote plaintext, credential URLs and query URLs are rejected",()=>{foreach(var address in new[]{"http://provider.example/v1","https://user:password@example.com/v1","https://example.com/v1?api_key=secret","https://example.com/v1#x"})Reject("ENDPOINT",()=>ProviderGateway.Endpoint(address));Assert(ProviderGateway.IsLocal(ProviderGateway.Endpoint("http://[::1]:1234/v1")),"IPv6 loopback rejected.");});
                Test("Oversized context stops before transport",()=>{var s=Settings();var h=new FakeHttp();using(var g=new ProviderGateway(s,x=>{},h)){var r=Request(s,approved:true);r.Context=new string('x',16001);Reject("CONTEXT_LIMIT",()=>Call(g,r));Assert(h.Count==0,"Oversized content sent.");}});
                Test("Image capability is enforced before transport",()=>{var s=Settings();var h=new FakeHttp();using(var g=new ProviderGateway(s,x=>{},h)){var r=Request(s,approved:true);r.ImageBase64=Convert.ToBase64String(new byte[]{1,2,3});Reject("VISION",()=>Call(g,r));Assert(h.Count==0,"Unsupported image sent.");}});
                Test("Gemini uses native contents and parses native response",()=>{var s=Settings();s.Preferences.Providers[0].Kind="gemini";var h=new FakeHttp {Reply=n=>new HttpResponseMessage(HttpStatusCode.OK){Content=new StringContent("{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hello from Gemini\"}]}}]}")}};using(var g=new ProviderGateway(s,x=>{},h)){Assert(Call(g,Request(s,approved:true)).Text=="Hello from Gemini","Gemini response missing.");Assert(h.Address.EndsWith("models/test-model:generateContent")&&h.Body.Contains("system_instruction"),"Wrong Gemini protocol.");}});
                Test("DPAPI file is encrypted and survives reload",()=>{string name="test-"+Guid.NewGuid().ToString("N")+".dat";try{LocalData.Write(name,Settings());byte[] bytes=File.ReadAllBytes(Path.Combine(LocalData.Root,name));Assert(!Encoding.UTF8.GetString(bytes).Contains("synthetic-test-secret"),"Plaintext secret on disk.");Assert(LocalData.Read<SavedSettings>(name).Keys["test"]=="synthetic-test-secret","Encrypted reload failed.");}finally{File.Delete(Path.Combine(LocalData.Root,name));}});
                Test("Encrypted chat reload preserves messages and branches concurrent edits",()=>{
                    string host="test-"+Guid.NewGuid().ToString("N");
                    try {
                        var first=ChatHistory.Save(new ChatSession {Host=host},new List<Message>{new Message {Role="user",Text="history roundtrip"}});
                        var stale=Wire.Parse<ChatSession>(Wire.Json(first));
                        Assert(ChatHistory.List(host).Single().Messages[0].Text=="history roundtrip","History reload failed.");
                        ChatHistory.Save(first,new List<Message>{new Message {Role="user",Text="first window update"}});
                        var second=ChatHistory.Save(stale,new List<Message>{new Message {Role="user",Text="second window update"}});
                        Assert(first.Id!=second.Id && ChatHistory.List(host).Count==2,"Concurrent history was overwritten.");
                    } finally {foreach(var item in ChatHistory.List(host))ChatHistory.Delete(item.Id);}
                });
                Test("Framed IPC rejects negative and truncated messages",()=>{foreach(var bytes in new[]{BitConverter.GetBytes(-1),new byte[]{10,0,0,0,1}}){bool rejected=false;try{using(var input=new MemoryStream(bytes))Wire.ReadAsync<Request>(input,CancellationToken.None).GetAwaiter().GetResult();}catch(Exception e) when(e is InvalidDataException || e is EndOfStreamException){rejected=true;}Assert(rejected,"Invalid message accepted.");}});
                Test("Office registration persists startup loading and local manifest after reopening registry",()=>{
                    string path=@"Software\OMNIX\Tests\"+Guid.NewGuid().ToString("N");
                    try {
                        string manifest=Installation.Manifest(Path.Combine(output,"install with spaces"),"Word");
                        using(var key=Microsoft.Win32.Registry.CurrentUser.CreateSubKey(path))Installation.WriteRegistration(key,manifest);
                        using(var key=Microsoft.Win32.Registry.CurrentUser.OpenSubKey(path)) {
                            Assert((string)key.GetValue("Manifest")==manifest&&manifest.EndsWith("|vstolocal"),"Manifest did not persist.");
                            Assert((int)key.GetValue("LoadBehavior")==3&&key.GetValueKind("LoadBehavior")==Microsoft.Win32.RegistryValueKind.DWord,"Startup loading did not persist.");
                        }
                    }finally{Microsoft.Win32.Registry.CurrentUser.DeleteSubKeyTree(path,false);}
                });
                Test("PE architecture is detected from executable bytes",()=>{Assert(new[]{"x86","x64"}.Contains(Installation.Architecture(System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName)),"Architecture probe failed.");});
                Test("Missing payload fails before registration",()=>{bool rejected=false;try{Installation.ValidatePayload(Path.Combine(output,"absent"));}catch(InvalidDataException){rejected=true;}Assert(rejected,"Incomplete install accepted.");});
                Test("Native named-pipe gateway starts and answers a real process call",()=>{string exe=Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"Omnix.Gateway.exe");var response=new GatewayClient(exe).CallAsync(new Request {Operation="ping"},CancellationToken.None).GetAwaiter().GetResult();Assert(response.Ok&&response.Text=="Gateway connected","IPC process response failed.");});
                Test("WPF workspace renders at narrow and standard pane widths",()=>{
                    foreach(int width in new[]{340,430})using(var view=new Workspace(null,"Word",Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"Omnix.Gateway.exe"))) {
                        view.Width=width;view.Height=780;view.Measure(new Size(width,780));view.Arrange(new Rect(0,0,width,780));view.UpdateLayout();
                        var target=new RenderTargetBitmap(width,780,96,96,PixelFormats.Pbgra32);target.Render(view);
                        var png=new PngBitmapEncoder();png.Frames.Add(BitmapFrame.Create(target));using(var file=File.Create(Path.Combine(output,"workspace-"+width+".png")))png.Save(file);
                        Assert(view.ActualWidth==width,"Pane measurement failed.");
                    }
                });
                File.WriteAllText(Path.Combine(output,"windows-runtime-tests.json"),Wire.Json(new {Passed=results.Count,Failed=0,RealOfficeInstalled=false,Results=results}));return 0;
            }catch(Exception e){Console.Error.WriteLine(e);File.WriteAllText(Path.Combine(output,"windows-test-failure.txt"),e.ToString());return 1;}
            finally{if(Directory.Exists(LocalData.TestRoot))Directory.Delete(LocalData.TestRoot,true);}
        }
    }
}
