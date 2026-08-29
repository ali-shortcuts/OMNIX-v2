using System;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace OMNIX.Core.Util
{
    /// <summary>Opens URLs/mailto with the OS default handler (spec Section 8 requirement: UseShellExecute=true).</summary>
    public static class ProcessLauncher
    {
        public static void Open(string url)
        {
            if (string.IsNullOrWhiteSpace(url)) return;
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = url,
                    UseShellExecute = true
                };
                Process.Start(psi);
            }
            catch (Exception ex)
            {
                Logging.Logger.Error("ui", "Could not open link: " + url, ex);
            }
        }
    }

    /// <summary>
    /// Vision capture helper (spec Section 6): produces PNG bytes in memory.
    /// Excel Chart.Export / PowerPoint Slide.Export REQUIRE a temporary file path —
    /// we use one temp file and delete it immediately (no unnecessary temp files left on disk).
    /// </summary>
    public static class TempImageCapture
    {
        public static byte[] FromExporter(Action<string> exportToPath)
        {
            string dir = Path.Combine(Path.GetTempPath(), "OMNIX");
            Directory.CreateDirectory(dir);
            string path = Path.Combine(dir, "omnix-capture-" + Guid.NewGuid().ToString("N") + ".png");
            try
            {
                exportToPath(path);
                return File.ReadAllBytes(path);
            }
            finally
            {
                try { if (File.Exists(path)) File.Delete(path); } catch { }
            }
        }
    }

    /// <summary>Small string helpers.</summary>
    public static class TextUtil
    {
        public static string Truncate(string s, int maxChars)
        {
            if (s == null) return string.Empty;
            if (s.Length <= maxChars) return s;
            return s.Substring(0, maxChars) + Environment.NewLine + "…[TRUNCATED]";
        }

        public static string YesNo(bool b) { return b ? "yes" : "no"; }
    }
}
