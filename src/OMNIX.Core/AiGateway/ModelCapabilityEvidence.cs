using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;
using Newtonsoft.Json;
namespace OMNIX.Core.AiGateway
{
    // Short-lived evidence for an exact provider/key/endpoint/protocol/model tuple.
    // No credentials or fingerprints are persisted or logged. Unknown is not a failed probe.
    public static class ModelCapabilityEvidence
    {
        private sealed class Entry { public ModelVerificationState State; public DateTime Expires; }
        private static readonly object Gate = new object();
        private static readonly Dictionary<string,Entry> Entries = new Dictionary<string,Entry>(StringComparer.Ordinal);
        private static string Key(string provider, ProviderCredentials c)
        {
            if(c==null) return null;
            string payload=JsonConvert.SerializeObject(new[]{provider??"",c.BaseUrl??"",c.ApiType??"",c.Model??"",c.ApiKey??""});
            using(var sha=SHA256.Create()) return Convert.ToBase64String(sha.ComputeHash(Encoding.UTF8.GetBytes(payload)));
        }
        public static void Record(string provider,ProviderCredentials credentials,ModelVerificationResult result)
        {
            if(result==null || credentials==null || !string.Equals(result.ModelId,credentials.Model,StringComparison.Ordinal)) return;
            string key=Key(provider,credentials);
            lock(Gate)
            {
                if(result.State!=ModelVerificationState.TextOnly && result.State!=ModelVerificationState.Incompatible && !result.Working)
                { Entries.Remove(key); return; } // Transient/auth/quota failures do not prove tool incompatibility.
                if(Entries.Count>=1000) Entries.Clear();
                Entries[key]=new Entry { State=result.State,Expires=DateTime.UtcNow.AddHours(2) };
            }
        }
        public static bool BlocksOfficeActions(string provider,ProviderCredentials credentials)
        {
            string key=Key(provider,credentials); if(key==null) return false;
            lock(Gate)
            {
                Entry entry;
                if(!Entries.TryGetValue(key,out entry)) return false;
                if(entry.Expires<=DateTime.UtcNow) { Entries.Remove(key); return false; }
                return entry.State==ModelVerificationState.TextOnly || entry.State==ModelVerificationState.Incompatible;
            }
        }
        public static string Explain(bool persian)
        {
            return persian ? "این مدل در آخرین تست، اجرای ابزارهای Office را تأیید نکرد. تغییری در فایل انجام نشد. در Verify models یک مدل با وضعیت Working انتخاب کن، یا همین مدل را با Test model دوباره بررسی کن. گفت‌وگوی متنی همچنان ممکن است." :
                "This model did not pass the latest Office tool test. No document changes were made. Select a Working model in Verify models, or run Test model again. Text chat remains available.";
        }
    }
}
