using System;
using System.IO;
using System.Linq;
using System.Windows.Forms;
using Omnix.Contracts;

namespace Omnix.Setup
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            string action=args.Length>0?args[0]:"diagnose";
            string root=args.Length>1?Path.GetFullPath(args[1]):Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,".."));
            try {
                var hosts=Installation.Detect();
                string report=Wire.Json(new {Product="OMNIX",Version="4.0.0-preview.1",TimestampUtc=DateTime.UtcNow,InstalledHosts=hosts,OfficeOpen=Installation.OfficeOpen(),RealOfficeAcceptance="Not yet verified"});
                Directory.CreateDirectory(LocalData.Root);File.WriteAllText(Path.Combine(LocalData.Root,"installation.json"),report);
                if(action=="probe") {
                    if(hosts.Count==0)return 20;if(Installation.OfficeOpen())return 21;if(hosts.Any(h=>!h.RuntimeReady))return 23;return 0;
                }
                if(action=="register") {
                    if(hosts.Count==0)throw new InvalidOperationException("No supported desktop Office installation was found.");
                    Installation.RemoveOldMaintenance();Installation.Register(root,hosts);return 0;
                }
                if(action=="trust" || action=="trust-silent") {Installation.TrustAndInstall(root,hosts,action=="trust-silent");return 0;}
                if(action=="unregister") {Installation.Unregister(root);return 0;}
                if(action=="payload") {Installation.ValidatePayload(root);return 0;}
                Application.EnableVisualStyles();
                var form=new Form {Text="OMNIX Diagnostics",Width=720,Height=540,StartPosition=FormStartPosition.CenterScreen};
                var text=new TextBox {Multiline=true,ReadOnly=true,Dock=DockStyle.Fill,ScrollBars=ScrollBars.Both,Font=new System.Drawing.Font("Consolas",10)};
                text.Text="OMNIX 4.0 preview\r\n\r\n"+string.Join("\r\n",hosts.Select(h=>h.Name+" | "+h.Architecture+" | "+h.Version+" | VSTO "+(h.RuntimeReady?"installed":"missing")))+"\r\n\r\n";
                string log=Path.Combine(LocalData.Root,"diagnostics.log");if(File.Exists(log))text.AppendText(string.Join("\r\n",File.ReadLines(log).Reverse().Take(60).Reverse()));
                if(hosts.Count==0)text.AppendText("No supported desktop Office application was detected.\r\n");
                text.AppendText("\r\nSupport: @Ali_silent0\r\nNo document content or API keys are included in this report.");
                form.Controls.Add(text);Application.Run(form);return 0;
            } catch(Exception e) {
                LocalData.Log("INSTALL_"+action.ToUpperInvariant()+"_FAILED",e);
                File.WriteAllText(Path.Combine(LocalData.Root,"installation-error.txt"),e.GetType().Name+": "+e.Message);
                if(action=="diagnose")MessageBox.Show(e.Message,"OMNIX",MessageBoxButtons.OK,MessageBoxIcon.Error);
                return 10;
            }
        }
    }
}
