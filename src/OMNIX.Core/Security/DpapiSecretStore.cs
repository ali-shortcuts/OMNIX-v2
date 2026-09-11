using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using Newtonsoft.Json;

namespace OMNIX.Core.Security
{
    public sealed class DpapiSecretStore
    {
        private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("OMNIX-v4-cleanroom");
        private readonly string _path;

        public DpapiSecretStore(string path)
        {
            if (string.IsNullOrWhiteSpace(path)) throw new ArgumentException("A secret-store path is required.", nameof(path));
            _path = path;
        }

        public void Set(string name, string value)
        {
            if (string.IsNullOrWhiteSpace(name)) throw new ArgumentException("Secret name is required.", nameof(name));
            Dictionary<string, string> map = LoadProtectedMap();
            if (string.IsNullOrEmpty(value))
            {
                map.Remove(name);
            }
            else
            {
                byte[] clear = Encoding.UTF8.GetBytes(value);
                byte[] protectedBytes = ProtectedData.Protect(clear, Entropy, DataProtectionScope.CurrentUser);
                map[name] = Convert.ToBase64String(protectedBytes);
            }
            SaveProtectedMap(map);
        }

        public string Get(string name)
        {
            if (string.IsNullOrWhiteSpace(name)) return null;
            Dictionary<string, string> map = LoadProtectedMap();
            if (!map.TryGetValue(name, out string protectedValue)) return null;
            byte[] protectedBytes = Convert.FromBase64String(protectedValue);
            byte[] clear = ProtectedData.Unprotect(protectedBytes, Entropy, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(clear);
        }

        private Dictionary<string, string> LoadProtectedMap()
        {
            if (!File.Exists(_path)) return new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            string json = File.ReadAllText(_path, Encoding.UTF8);
            return JsonConvert.DeserializeObject<Dictionary<string, string>>(json)
                   ?? new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        }

        private void SaveProtectedMap(Dictionary<string, string> map)
        {
            string directory = Path.GetDirectoryName(_path);
            if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
            string temp = _path + ".tmp";
            File.WriteAllText(temp, JsonConvert.SerializeObject(map, Formatting.Indented), Encoding.UTF8);
            if (File.Exists(_path)) File.Replace(temp, _path, null);
            else File.Move(temp, _path);
        }
    }
}
