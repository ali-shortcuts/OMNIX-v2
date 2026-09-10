using System;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Security.Principal;
using System.Threading;
using System.Threading.Tasks;
using Omnix.Contracts;

namespace Omnix.Desktop
{
    public sealed class GatewayClient
    {
        private readonly string gateway;
        public GatewayClient(string path) { gateway=path; }
        public async Task<Reply> CallAsync(Request request,CancellationToken cancel)
        {
            using(var timeout=CancellationTokenSource.CreateLinkedTokenSource(cancel)) {
                timeout.CancelAfter(TimeSpan.FromSeconds(110));
                using(var pipe=new NamedPipeClientStream(".",Wire.PipeName,PipeDirection.InOut,PipeOptions.Asynchronous,TokenImpersonationLevel.Impersonation)) {
                    try { await pipe.ConnectAsync(250,timeout.Token).ConfigureAwait(false); }
                    catch(TimeoutException) {
                        if(!File.Exists(gateway)) throw new InvalidOperationException("The OMNIX gateway is missing. Run the installer again.");
                        Process.Start(new ProcessStartInfo(gateway) { UseShellExecute=false,CreateNoWindow=true,WorkingDirectory=Path.GetDirectoryName(gateway) })?.Dispose();
                        await pipe.ConnectAsync(12000,timeout.Token).ConfigureAwait(false);
                    }
                    using(timeout.Token.Register(()=>pipe.Dispose())) {
                        await Wire.WriteAsync(pipe,request,timeout.Token).ConfigureAwait(false);
                        var reply=await Wire.ReadAsync<Reply>(pipe,timeout.Token).ConfigureAwait(false);
                        if(reply==null || reply.Id!=request.Id) throw new InvalidDataException("Unexpected gateway response. Restart Office and try again.");
                        if(!reply.Ok) throw new InvalidOperationException(reply.Code+": "+reply.Text);
                        return reply;
                    }
                }
            }
        }
    }
}
