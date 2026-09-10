using System;
using System.IO;
using System.IO.Pipes;
using System.Net.Http;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Threading;
using System.Threading.Tasks;
using Omnix.Contracts;

namespace Omnix.Gateway
{
    internal static class Program
    {
        private static DateTime activity=DateTime.UtcNow;
        [STAThread]
        private static int Main()
        {
            try {
                bool owner;
                using(var mutex=new Mutex(true,"Local\\"+Wire.PipeName,out owner)) {
                    if(!owner) return 0;
                    using(var gateway=new ProviderGateway(LocalData.Read<SavedSettings>("providers.dat"),s=>LocalData.Write("providers.dat",s)))
                        Run(gateway).GetAwaiter().GetResult();
                }
                return 0;
            } catch(Exception e) { LocalData.Log("GATEWAY_START_FAILED",e); return 1; }
        }
        private static async Task Run(ProviderGateway gateway)
        {
            var user=WindowsIdentity.GetCurrent().User;
            var security=new PipeSecurity();
            security.SetAccessRuleProtection(true,false);
            security.AddAccessRule(new PipeAccessRule(user,PipeAccessRights.FullControl,AccessControlType.Allow));
            security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.NetworkSid,null),PipeAccessRights.FullControl,AccessControlType.Deny));
            LocalData.Log("GATEWAY_READY");
            // One request at a time keeps settings and model requests bounded across Office processes.
            while(true) {
                using(var pipe=new NamedPipeServerStream(Wire.PipeName,PipeDirection.InOut,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous,16384,16384,security))
                using(var timeout=new CancellationTokenSource(TimeSpan.FromMinutes(5))) {
                    try { await pipe.WaitForConnectionAsync(timeout.Token).ConfigureAwait(false); }
                    catch(OperationCanceledException) { return; }
                    string identity=null;
                    pipe.RunAsClient(()=>identity=WindowsIdentity.GetCurrent().User.Value);
                    if(identity!=user.Value) { LocalData.Log("IPC_WRONG_USER"); continue; }
                    using(var requestTimeout=new CancellationTokenSource(TimeSpan.FromSeconds(105))) {
                        Request request=null; Reply reply;
                        try {
                            request=await Wire.ReadAsync<Request>(pipe,requestTimeout.Token).ConfigureAwait(false);
                            reply=await gateway.HandleAsync(request,requestTimeout.Token).ConfigureAwait(false);
                        } catch(UserError e) { reply=new Reply {Ok=false,Code=e.Code,Text=e.Message}; }
                        catch(OperationCanceledException) { reply=new Reply {Ok=false,Code="TIMEOUT",Text="The provider did not finish in time. Try a shorter request or another model."}; }
                        catch(HttpRequestException e) { LocalData.Log("NETWORK",e); reply=new Reply {Ok=false,Code="NETWORK",Text="The configured provider could not be reached. Check its address and connection."}; }
                        catch(Exception e) { LocalData.Log("GATEWAY_REQUEST_FAILED",e); reply=new Reply {Ok=false,Code="GATEWAY",Text="The request failed. Open Diagnostics for the recorded error category."}; }
                        reply.Id=request?.Id;
                        try { await Wire.WriteAsync(pipe,reply,requestTimeout.Token).ConfigureAwait(false); }
                        catch(IOException) { /* Caller cancelled or Office closed. */ }
                        catch(OperationCanceledException) { }
                    }
                    activity=DateTime.UtcNow;
                }
            }
        }
    }
}
