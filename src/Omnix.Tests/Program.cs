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
            try {
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
                Test("Framed IPC rejects negative and truncated messages",()=>{foreach(var bytes in new[]{BitConverter.GetBytes(-1),new byte[]{10,0,0,0,1}}){bool rejected=false;try{using(var input=new MemoryStream(bytes))Wire.ReadAsync<Request>(input,CancellationToken.None).GetAwaiter().GetResult();}catch(Exception e) when(e is InvalidDataException || e is EndOfStreamException){rejected=true;}Assert(rejected,"Invalid message accepted.");}});
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
        }
    }
}
