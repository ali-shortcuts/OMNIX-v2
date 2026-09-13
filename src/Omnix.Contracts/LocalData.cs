using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace Omnix.Contracts
{
    public static class LocalData
    {
        public static readonly string Root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"OMNIX","v4");
        public static T Read<T>(string name) where T:new()
        {
            string path=Path.Combine(Root,name);
            if(!File.Exists(path)) return new T();
            if(new FileInfo(path).Length>16*1024*1024) throw new InvalidDataException("Saved data exceeds the supported size.");
            byte[] plain=ProtectedData.Unprotect(File.ReadAllBytes(path),null,DataProtectionScope.CurrentUser);
            try { return Wire.Parse<T>(Encoding.UTF8.GetString(plain)); }
            finally { Array.Clear(plain,0,plain.Length); }
        }
        public static void Write(string name,object value)
        {
            Directory.CreateDirectory(Root);
            string path=Path.Combine(Root,name), temp=path+"."+Guid.NewGuid().ToString("N")+".tmp";
            byte[] plain=Encoding.UTF8.GetBytes(Wire.Json(value));
            try {
                File.WriteAllBytes(temp,ProtectedData.Protect(plain,null,DataProtectionScope.CurrentUser));
                if(File.Exists(path)) File.Replace(temp,path,null); else File.Move(temp,path);
            } finally { Array.Clear(plain,0,plain.Length); if(File.Exists(temp))File.Delete(temp); }
        }
        // Diagnostics record event codes and exception types, never request text, URLs, or keys.
        public static void Log(string code,Exception error=null)
        {
            try {
                Directory.CreateDirectory(Root);
                string path=Path.Combine(Root,"diagnostics.log");
                lock(typeof(LocalData)) {
                    if(File.Exists(path) && new FileInfo(path).Length>1024*1024) File.Delete(path);
                    File.AppendAllText(path,DateTime.UtcNow.ToString("O")+" "+code+" "+(error==null?"":error.GetType().Name)+Environment.NewLine);
                }
            } catch { /* Logging cannot stop Office startup. */ }
        }
    }
}
