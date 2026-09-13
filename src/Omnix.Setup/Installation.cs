using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Xml.Linq;
using Microsoft.Win32;
using Omnix.Contracts;

namespace Omnix.Setup
{
    public sealed class OfficeHost
    {
        public string Name {get;set;}
        public string Path {get;set;}
        public string Architecture {get;set;}
        public string Version {get;set;}
        public bool RuntimeReady {get;set;}
    }
    public static class Installation
    {
        public static readonly string[] Hosts={"Excel","Word","PowerPoint"};
        public static readonly string[] Executables={"EXCEL.EXE","WINWORD.EXE","POWERPNT.EXE"};
        public static string Architecture(string path)
        {
            using(var file=File.OpenRead(path))using(var reader=new BinaryReader(file)) {
                if(reader.ReadUInt16()!=0x5a4d)throw new InvalidDataException("Not a Windows executable.");
                file.Position=0x3c;int offset=reader.ReadInt32();
                if(offset<64 || offset>file.Length-6)throw new InvalidDataException("Invalid executable header.");
                file.Position=offset;if(reader.ReadUInt32()!=0x4550)throw new InvalidDataException("Invalid PE signature.");
                ushort machine=reader.ReadUInt16();
                if(machine==0x14c)return "x86";if(machine==0x8664)return "x64";
                throw new InvalidDataException("This Office architecture is not supported by this build.");
            }
        }
        public static List<OfficeHost> Detect()
        {
            var found=new List<OfficeHost>();
            for(int i=0;i<Hosts.Length;i++) {
                var paths=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach(var view in new[]{RegistryView.Registry32,RegistryView.Registry64}) {
                    if(view==RegistryView.Registry64&&!Environment.Is64BitOperatingSystem)continue;
                    foreach(var hive in new[]{RegistryHive.CurrentUser,RegistryHive.LocalMachine})
                    using(var root=RegistryKey.OpenBaseKey(hive,view)) {
                        using(var key=root.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\"+Executables[i])) {
                            string path=Convert.ToString(key?.GetValue(null)).Trim('"');if(File.Exists(path))paths.Add(path);
                        }
                        foreach(var version in new[]{"16.0","15.0"})using(var key=root.OpenSubKey(@"SOFTWARE\Microsoft\Office\"+version+"\\"+Hosts[i]+@"\InstallRoot")) {
                            string folder=Convert.ToString(key?.GetValue("Path"));if(folder.Length>0&&File.Exists(System.IO.Path.Combine(folder,Executables[i])))paths.Add(System.IO.Path.Combine(folder,Executables[i]));
                        }
                        using(var key=root.OpenSubKey(@"SOFTWARE\Microsoft\Office\ClickToRun\Configuration")) {
                            string folder=Convert.ToString(key?.GetValue("InstallationPath"));
                            if(folder.Length>0)foreach(string child in new[]{@"root\Office16","Office16",""}) {
                                string path=System.IO.Path.Combine(folder,child,Executables[i]);if(File.Exists(path))paths.Add(path);
                            }
                        }
                    }
                }
                string selected=paths.FirstOrDefault();if(selected==null)continue;
                string arch=Architecture(selected);
                found.Add(new OfficeHost {Name=Hosts[i],Path=selected,Architecture=arch,Version=FileVersionInfo.GetVersionInfo(selected).FileVersion,RuntimeReady=RuntimeReady(arch)});
            }
            return found;
        }
        public static bool RuntimeReady(string architecture)
        {
            using(var root=RegistryKey.OpenBaseKey(RegistryHive.LocalMachine,architecture=="x64"?RegistryView.Registry64:RegistryView.Registry32))
                foreach(string name in new[]{"v4R","v4"})using(var key=root.OpenSubKey(@"SOFTWARE\Microsoft\VSTO Runtime Setup\"+name)) {
                    Version version;
                    if(Version.TryParse(Convert.ToString(key?.GetValue("Version")),out version)&&version.Major>=10)return true;
                }
            return false;
        }
        public static bool OfficeOpen() => Process.GetProcesses().Any(p=>{try{return Executables.Any(n=>n.Equals(p.ProcessName+".exe",StringComparison.OrdinalIgnoreCase));}finally{p.Dispose();}});
        public static string Manifest(string root,string host)=>new Uri(System.IO.Path.GetFullPath(System.IO.Path.Combine(root,"hosts",host,"Omnix."+host+".vsto"))).AbsoluteUri+"|vstolocal";
        public static void ValidatePayload(string root)
        {
            foreach(string host in Hosts) {
                string folder=System.IO.Path.Combine(root,"hosts",host);
                foreach(string file in new[]{"Omnix."+host+".dll","Omnix."+host+".vsto","Omnix."+host+".dll.manifest","Omnix.Desktop.dll","Omnix.Contracts.dll","Microsoft.Office.Tools.Common.v4.0.Utilities.dll"})
                    if(!File.Exists(System.IO.Path.Combine(folder,file)))throw new InvalidDataException("Installer payload is missing "+host+"/"+file);
                var manifest=XDocument.Load(System.IO.Path.Combine(folder,"Omnix."+host+".dll.manifest"));
                if(!manifest.Descendants().Any(e=>e.Name.LocalName=="Signature"))throw new InvalidDataException("VSTO manifest is not signed.");
            }
            foreach(string file in new[]{"Omnix.Gateway.exe","Omnix.Contracts.dll"})if(!File.Exists(System.IO.Path.Combine(root,"gateway",file)))throw new InvalidDataException("Gateway payload is incomplete.");
        }
        public static void Register(string root,IEnumerable<OfficeHost> hosts)
        {
            ValidatePayload(root);
            if(OfficeOpen())throw new InvalidOperationException("Close Excel, Word and PowerPoint before installing.");
            foreach(var host in hosts) {
                if(!host.RuntimeReady)throw new InvalidOperationException("VSTO Runtime is missing for "+host.Name+" "+host.Architecture);
                using(var user=RegistryKey.OpenBaseKey(RegistryHive.CurrentUser,host.Architecture=="x64"?RegistryView.Registry64:RegistryView.Registry32))
                {
                using(var addins=user.OpenSubKey(@"Software\Microsoft\Office\"+host.Name+@"\Addins",true)) {
                    if(addins!=null)foreach(string name in addins.GetSubKeyNames()) {
                        if(name=="OMNIX")continue;
                        bool same;using(var previous=addins.OpenSubKey(name)) {
                            string path=Convert.ToString(previous?.GetValue("Manifest")).Split('|')[0];
                            same=path.Equals(Manifest(root,host.Name).Split('|')[0],StringComparison.OrdinalIgnoreCase);
                        }
                        if(same)addins.DeleteSubKeyTree(name,false);
                    }
                }
                using(var key=user.CreateSubKey(@"Software\Microsoft\Office\"+host.Name+@"\Addins\OMNIX")) {
                    key.SetValue("FriendlyName","OMNIX");key.SetValue("Description","OMNIX native AI workspace");
                    key.SetValue("Manifest",Manifest(root,host.Name));key.SetValue("LoadBehavior",3,RegistryValueKind.DWord);
                    if(Convert.ToString(key.GetValue("Manifest"))!=Manifest(root,host.Name)||(int)key.GetValue("LoadBehavior")!=3)throw new InvalidOperationException("Registration verification failed.");
                }
                }
            }
        }
        public static string VstoInstaller(string architecture)
        {
            using(var machine=RegistryKey.OpenBaseKey(RegistryHive.LocalMachine,architecture=="x64"?RegistryView.Registry64:RegistryView.Registry32))
                foreach(string version in new[]{"v4","v4R"})using(var key=machine.OpenSubKey(@"SOFTWARE\Microsoft\VSTO Runtime Setup\"+version)) {
                    string path=Convert.ToString(key?.GetValue("InstallerPath"));if(File.Exists(path))return path;
                }
            string common=Environment.GetFolderPath(architecture=="x64"?Environment.SpecialFolder.CommonProgramFiles:Environment.SpecialFolder.CommonProgramFilesX86);
            string fallback=System.IO.Path.Combine(common,@"Microsoft Shared\VSTO\10.0\VSTOInstaller.exe");
            if(File.Exists(fallback))return fallback;
            throw new InvalidOperationException("Microsoft VSTO Installer was not found for "+architecture+" Office.");
        }
        public static void TrustAndInstall(string root,IEnumerable<OfficeHost> hosts,bool silent)
        {
            ValidatePayload(root);
            foreach(var host in hosts) {
                string manifest=System.IO.Path.Combine(root,"hosts",host.Name,"Omnix."+host.Name+".vsto");
                using(var process=Process.Start(new ProcessStartInfo(VstoInstaller(host.Architecture),"/Install \""+manifest+"\""+(silent?" /Silent":"")) {UseShellExecute=false})) {
                    process.WaitForExit();
                    if(process.ExitCode!=0)throw new InvalidOperationException("Microsoft VSTO Installer could not install "+host.Name+" (exit "+process.ExitCode+"). Review its trust or deployment error. Office security policy is not changed by OMNIX.");
                }
            }
        }
        public static void Unregister(string root)
        {
            foreach(var view in new[]{RegistryView.Registry32,RegistryView.Registry64}) {
                if(view==RegistryView.Registry64&&!Environment.Is64BitOperatingSystem)continue;
                using(var user=RegistryKey.OpenBaseKey(RegistryHive.CurrentUser,view))foreach(string host in Hosts) {
                    string path=@"Software\Microsoft\Office\"+host+@"\Addins\OMNIX";
                    bool owned;using(var key=user.OpenSubKey(path))owned=Convert.ToString(key?.GetValue("Manifest"))==Manifest(root,host);
                    if(owned)user.DeleteSubKeyTree(path,false);
                }
            }
        }
        public static void RemoveOldMaintenance()
        {
            // Match both task name and its OMNIX script before removing the previous generation's task.
            Type type=Type.GetTypeFromProgID("Schedule.Service");if(type==null)return;
            dynamic service=Activator.CreateInstance(type);service.Connect();dynamic folder=service.GetFolder("\\");
            dynamic task;
            try{task=folder.GetTask("OMNIX Office Registration Maintenance");}catch(System.Runtime.InteropServices.COMException){return;}
            string xml=task.Xml;
            if(xml.IndexOf("office-registration-maintenance.ps1",StringComparison.OrdinalIgnoreCase)<0 || xml.IndexOf("OMNIX",StringComparison.OrdinalIgnoreCase)<0)
                throw new InvalidOperationException("The previous maintenance task could not be identified safely.");
            folder.DeleteTask("OMNIX Office Registration Maintenance",0);
        }
    }
}
