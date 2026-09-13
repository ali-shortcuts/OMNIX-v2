# OMNIX encrypted chat-history runtime acceptance
#
# Deterministic test of the compiled OMNIX.Core ChatHistoryStore. It validates that persisted
# conversation text is DPAPI-protected for CurrentUser, raw image bytes are not persisted,
# legacy plaintext JSON is migrated only after an encrypted replacement is written, and corrupt
# encrypted history fails closed. The test uses unique temporary history keys and cleans them up.

[CmdletBinding()]
param(
    [string]$CorePath = ".\src\OMNIX.Core\bin\Release\OMNIX.Core.dll",
    [string]$OutputPath = ".\build\artifact\history-storage-acceptance.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$core = (Resolve-Path -LiteralPath $CorePath -ErrorAction Stop).Path
$coreDir = Split-Path -Parent $core
$newtonsoft = Join-Path $coreDir 'Newtonsoft.Json.dll'
if (-not (Test-Path -LiteralPath $newtonsoft)) {
    throw "Newtonsoft.Json.dll was not found beside OMNIX.Core.dll."
}

[void][Reflection.Assembly]::LoadFrom($newtonsoft)
[void][Reflection.Assembly]::LoadFrom($core)

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Newtonsoft.Json;
using OMNIX.Core.Logging;
using OMNIX.Core.Storage;

public sealed class HistoryStorageAcceptanceResult
{
    public string TestId { get; set; }
    public int EvidenceSchema { get; set; }
    public bool EncryptedFileCreated { get; set; }
    public bool EncryptedHeaderPass { get; set; }
    public bool PlaintextAbsentOnDisk { get; set; }
    public bool RoundTripPass { get; set; }
    public bool ImageBytesNotPersisted { get; set; }
    public bool LegacyMigrationPass { get; set; }
    public bool CorruptCiphertextFailsClosed { get; set; }
    public bool DeleteRemovesAllHistoryForms { get; set; }
    public int FailureCount { get; set; }
    public List<string> Failures { get; set; }
    public bool OverallPass { get; set; }
}

public static class HistoryStorageAcceptanceHarness
{
    private static bool ContainsBytes(byte[] haystack, byte[] needle)
    {
        if (haystack == null || needle == null || needle.Length == 0 || haystack.Length < needle.Length)
            return false;
        for (int i = 0; i <= haystack.Length - needle.Length; i++)
        {
            bool match = true;
            for (int j = 0; j < needle.Length; j++)
            {
                if (haystack[i + j] != needle[j]) { match = false; break; }
            }
            if (match) return true;
        }
        return false;
    }

    private static bool StartsWith(byte[] value, byte[] prefix)
    {
        if (value == null || prefix == null || value.Length < prefix.Length) return false;
        for (int i = 0; i < prefix.Length; i++)
            if (value[i] != prefix[i]) return false;
        return true;
    }

    private static string DatPath(string key)
    {
        return Path.Combine(Logger.BaseDir, "history", DocKeySanitizer.Sanitize(key) + ".dat");
    }

    private static string JsonPath(string key)
    {
        return Path.Combine(Logger.BaseDir, "history", DocKeySanitizer.Sanitize(key) + ".json");
    }

    private static void Cleanup(string key)
    {
        foreach (var path in new[] { DatPath(key), JsonPath(key), DatPath(key) + ".tmp" })
        {
            try { if (File.Exists(path)) File.Delete(path); } catch { }
        }
    }

    public static HistoryStorageAcceptanceResult Run()
    {
        var failures = new List<string>();
        var result = new HistoryStorageAcceptanceResult
        {
            TestId = "HISTORY-STORAGE-RUNTIME-001",
            EvidenceSchema = 1,
            Failures = failures
        };

        string key = "history-acceptance-" + Guid.NewGuid().ToString("N");
        string legacyKey = "history-legacy-" + Guid.NewGuid().ToString("N");
        string corruptKey = "history-corrupt-" + Guid.NewGuid().ToString("N");
        string marker = "OMNIX_HISTORY_SECRET_" + Guid.NewGuid().ToString("N");
        string legacyMarker = "OMNIX_LEGACY_SECRET_" + Guid.NewGuid().ToString("N");
        var store = new ChatHistoryStore();

        try
        {
            Cleanup(key);
            Cleanup(legacyKey);
            Cleanup(corruptKey);

            var turns = new List<ChatTurn>
            {
                new ChatTurn
                {
                    Role = ChatRole.User,
                    Text = marker,
                    TimestampUtc = DateTime.UtcNow,
                    Images = new List<ImageAttachment>
                    {
                        new ImageAttachment
                        {
                            FileName = "selection.png",
                            SourceLabel = "Excel selection",
                            PngBytes = Encoding.UTF8.GetBytes("RAW_IMAGE_BYTES_MUST_NOT_PERSIST")
                        }
                    }
                },
                new ChatTurn
                {
                    Role = ChatRole.Assistant,
                    Text = "history acceptance response",
                    TimestampUtc = DateTime.UtcNow
                }
            };

            store.Save(key, turns);
            string dat = DatPath(key);
            string legacy = JsonPath(key);
            result.EncryptedFileCreated = File.Exists(dat) && !File.Exists(legacy);
            if (!result.EncryptedFileCreated)
                failures.Add("Encrypted .dat history was not created or plaintext .json remained.");

            byte[] disk = File.Exists(dat) ? File.ReadAllBytes(dat) : new byte[0];
            byte[] magic = Encoding.ASCII.GetBytes("OMNIXH01");
            result.EncryptedHeaderPass = StartsWith(disk, magic);
            if (!result.EncryptedHeaderPass)
                failures.Add("Encrypted history header is missing or invalid.");

            result.PlaintextAbsentOnDisk =
                !ContainsBytes(disk, Encoding.UTF8.GetBytes(marker)) &&
                !ContainsBytes(disk, Encoding.UTF8.GetBytes("RAW_IMAGE_BYTES_MUST_NOT_PERSIST"));
            if (!result.PlaintextAbsentOnDisk)
                failures.Add("Sensitive history plaintext was observable in the persisted encrypted file.");

            var loaded = store.Load(key);
            result.RoundTripPass = loaded.Count == 2 && loaded[0].Text == marker && loaded[1].Text == "history acceptance response";
            if (!result.RoundTripPass)
                failures.Add("Encrypted history did not round-trip through DPAPI storage.");

            var image = loaded.Count > 0 && loaded[0].Images != null ? loaded[0].Images.FirstOrDefault() : null;
            result.ImageBytesNotPersisted = image != null && image.PngBytes == null && image.FileName == "selection.png";
            if (!result.ImageBytesNotPersisted)
                failures.Add("Raw image bytes were persisted or image metadata was not preserved correctly.");

            // Legacy migration: seed the previous plaintext JSON format, then load through the
            // current store. Migration must preserve data, create encrypted storage and delete the
            // plaintext file only after the encrypted replacement exists.
            var legacyTurns = new List<ChatTurn>
            {
                new ChatTurn
                {
                    Role = ChatRole.User,
                    Text = legacyMarker,
                    TimestampUtc = DateTime.UtcNow
                }
            };
            Directory.CreateDirectory(Path.GetDirectoryName(JsonPath(legacyKey)));
            File.WriteAllText(JsonPath(legacyKey), JsonConvert.SerializeObject(legacyTurns), Encoding.UTF8);
            var migrated = store.Load(legacyKey);
            byte[] migratedDisk = File.Exists(DatPath(legacyKey)) ? File.ReadAllBytes(DatPath(legacyKey)) : new byte[0];
            result.LegacyMigrationPass =
                migrated.Count == 1 && migrated[0].Text == legacyMarker &&
                File.Exists(DatPath(legacyKey)) && !File.Exists(JsonPath(legacyKey)) &&
                StartsWith(migratedDisk, magic) &&
                !ContainsBytes(migratedDisk, Encoding.UTF8.GetBytes(legacyMarker));
            if (!result.LegacyMigrationPass)
                failures.Add("Legacy plaintext history migration did not complete safely.");

            // Corrupt encrypted payload must not be interpreted as plaintext or returned to callers.
            var corrupt = new byte[magic.Length + 32];
            Buffer.BlockCopy(magic, 0, corrupt, 0, magic.Length);
            for (int i = magic.Length; i < corrupt.Length; i++) corrupt[i] = (byte)(i * 17 + 3);
            File.WriteAllBytes(DatPath(corruptKey), corrupt);
            var corruptLoaded = store.Load(corruptKey);
            result.CorruptCiphertextFailsClosed = corruptLoaded != null && corruptLoaded.Count == 0;
            if (!result.CorruptCiphertextFailsClosed)
                failures.Add("Corrupt encrypted history did not fail closed.");

            store.Delete(key);
            store.Delete(legacyKey);
            store.Delete(corruptKey);
            result.DeleteRemovesAllHistoryForms =
                !File.Exists(DatPath(key)) && !File.Exists(JsonPath(key)) &&
                !File.Exists(DatPath(legacyKey)) && !File.Exists(JsonPath(legacyKey)) &&
                !File.Exists(DatPath(corruptKey)) && !File.Exists(JsonPath(corruptKey));
            if (!result.DeleteRemovesAllHistoryForms)
                failures.Add("Delete did not remove all encrypted/legacy history forms.");
        }
        finally
        {
            Cleanup(key);
            Cleanup(legacyKey);
            Cleanup(corruptKey);
        }

        result.FailureCount = failures.Count;
        result.OverallPass = failures.Count == 0;
        return result;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp -ReferencedAssemblies @($core, $newtonsoft)

$result = [HistoryStorageAcceptanceHarness]::Run()
$outDir = Split-Path -Parent $OutputPath
if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$result | ConvertTo-Json -Depth 8

if (-not $result.OverallPass) { exit 1 }
exit 0
