using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using Newtonsoft.Json;
using OMNIX.Core.Logging;

namespace OMNIX.Core.Settings
{
    /// <summary>
    /// Layer 8 (Storage): settings + DPAPI-encrypted API keys at %LOCALAPPDATA%\OMNIX\settings.dat.
    /// Ironclad Rule 6: API keys are never stored in plain text and never logged.
    /// DPAPI (CurrentUser scope) ties the ciphertext to the Windows user; no password to remember.
    /// </summary>
    public sealed class SettingsManager
    {
        private static readonly object Gate = new object();
        private static SettingsManager _instance;
        public static SettingsManager Instance
        {
            get
            {
                if (_instance == null)
                {
                    lock (Gate)
                    {
                        if (_instance == null) _instance = new SettingsManager();
                    }
                }
                return _instance;
            }
        }

        private static readonly byte[] Magic = Encoding.ASCII.GetBytes("OMNIXS01");
        private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("OMNIX::v1::DPAPI");

        private readonly string _path;

        // Volatile only: plain keys live in memory for the current Windows session.
        private readonly Dictionary<string, string> _plainKeys = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        public OmnixSettings Settings { get; private set; }

        public SettingsManager()
        {
            _path = Path.Combine(Logger.BaseDir, "settings.dat");
            Load();
        }

        public string SettingsFilePath { get { return _path; } }

        private void Load()
        {
            try
            {
                if (!File.Exists(_path))
                {
                    Settings = OmnixSettings.CreateDefaults();
                    Logger.Startup("settings.dat not found — defaults created (privacy=AskBeforeSending)");
                    return;
                }

                byte[] blob = File.ReadAllBytes(_path);
                if (blob.Length < Magic.Length + 4 || !StartsWith(blob, Magic))
                {
                    BackupCorrupt("bad magic");
                    Settings = OmnixSettings.CreateDefaults();
                    return;
                }

                string json = Encoding.UTF8.GetString(blob, Magic.Length, blob.Length - Magic.Length);
                var dto = JsonConvert.DeserializeObject<SettingsDto>(json);
                if (dto == null || dto.Settings == null)
                {
                    BackupCorrupt("null payload");
                    Settings = OmnixSettings.CreateDefaults();
                    return;
                }

                Settings = dto.Settings;
                lock (_plainKeys)
                {
                    _plainKeys.Clear();
                    if (dto.ProtectedKeys != null)
                    {
                        foreach (var kv in dto.ProtectedKeys)
                        {
                            try
                            {
                                byte[] prot = Convert.FromBase64String(kv.Value);
                                byte[] plain = ProtectedData.Unprotect(prot, Entropy, DataProtectionScope.CurrentUser);
                                _plainKeys[kv.Key] = Encoding.UTF8.GetString(plain);
                            }
                            catch (Exception ex)
                            {
                                // Possible cause: settings copied from another Windows user profile.
                                Logger.Error("settings", "Could not unprotect API key for provider '" + kv.Key + "' — key reset.", ex);
                            }
                        }
                    }
                }
                Logger.Startup("settings loaded: provider=" + Settings.SelectedProviderId + " privacy=" + Settings.Privacy);
            }
            catch (Exception ex)
            {
                Logger.Error("settings", "Failed to load settings — defaults used.", ex);
                Settings = OmnixSettings.CreateDefaults();
            }
        }

        public void Save()
        {
            try
            {
                var dto = new SettingsDto();
                dto.Settings = Settings;

                lock (_plainKeys)
                {
                    dto.ProtectedKeys = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                    foreach (var kv in _plainKeys)
                    {
                        byte[] plain = Encoding.UTF8.GetBytes(kv.Value ?? "");
                        byte[] prot = ProtectedData.Protect(plain, Entropy, DataProtectionScope.CurrentUser);
                        dto.ProtectedKeys[kv.Key] = Convert.ToBase64String(prot);
                    }
                }

                string json = JsonConvert.SerializeObject(dto, Formatting.Indented);
                Directory.CreateDirectory(Path.GetDirectoryName(_path));
                string tmp = _path + ".tmp";
                File.WriteAllBytes(tmp, Concat(Magic, Encoding.UTF8.GetBytes(json)));
                if (File.Exists(_path)) File.Delete(_path);
                File.Move(tmp, _path);
            }
            catch (Exception ex)
            {
                Logger.Error("settings", "Failed to save settings.", ex);
            }
        }

        /// <summary>Returns the plain API key for a provider (in-memory only; never log it).</summary>
        public string GetApiKey(string providerId)
        {
            if (string.IsNullOrEmpty(providerId)) return null;
            lock (_plainKeys)
            {
                string v;
                return _plainKeys.TryGetValue(providerId, out v) ? v : null;
            }
        }

        public void SetApiKey(string providerId, string plainKey)
        {
            lock (_plainKeys)
            {
                if (string.IsNullOrEmpty(plainKey)) _plainKeys.Remove(providerId);
                else _plainKeys[providerId] = plainKey;
            }
            Save();
        }

        public bool HasApiKey(string providerId)
        {
            return !string.IsNullOrEmpty(GetApiKey(providerId));
        }

        private void BackupCorrupt(string reason)
        {
            try
            {
                if (File.Exists(_path))
                {
                    string bak = _path + ".corrupt-" + DateTime.UtcNow.ToString("yyyyMMddHHmmss");
                    File.Copy(_path, bak, true);
                    Logger.Startup("settings.dat corrupt (" + reason + ") — backed up to " + bak + " and reset to defaults.");
                }
            }
            catch { }
        }

        private static bool StartsWith(byte[] blob, byte[] prefix)
        {
            for (int i = 0; i < prefix.Length; i++)
                if (blob[i] != prefix[i]) return false;
            return true;
        }

        private static byte[] Concat(byte[] a, byte[] b)
        {
            var r = new byte[a.Length + b.Length];
            Buffer.BlockCopy(a, 0, r, 0, a.Length);
            Buffer.BlockCopy(b, 0, r, a.Length, b.Length);
            return r;
        }

        private sealed class SettingsDto
        {
            [JsonProperty("settings")]
            public OmnixSettings Settings { get; set; }

            [JsonProperty("protectedKeys")]
            public Dictionary<string, string> ProtectedKeys { get; set; }
        }
    }
}
