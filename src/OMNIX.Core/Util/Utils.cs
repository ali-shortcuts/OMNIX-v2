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
                byte[] bytes = File.ReadAllBytes(path);
                ImageNormalizer.ValidatePngBytes(bytes, "Office capture");
                return bytes;
            }
            finally
            {
                try { if (File.Exists(path)) File.Delete(path); } catch { }
            }
        }
    }

    /// <summary>
    /// Normalizes disk image uploads to actual PNG bytes before they enter ChatRequest.ImageAttachment.
    /// The old UI accepted JPG/JPEG/BMP but provider adapters label PngBytes as image/png; sending
    /// arbitrary source bytes with that MIME type is incorrect and can produce provider-specific
    /// failures. Decode + re-encode also verifies that the selected file is a real supported image.
    /// Pixel/dimension/output caps prevent ordinary compressed-image bombs from allocating without
    /// a clear upper bound inside Excel/Word/PowerPoint.
    /// </summary>
    public static class ImageNormalizer
    {
        public const long MaxInputBytes = 20L * 1024L * 1024L;
        public const long MaxOutputBytes = 20L * 1024L * 1024L;
        public const long MaxPixels = 24L * 1024L * 1024L;
        public const int MaxDimension = 10000;

        public static byte[] LoadFileAsPng(string path)
        {
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
                throw new InvalidDataException("Selected image file does not exist.");

            var info = new FileInfo(path);
            if (info.Length <= 0 || info.Length > MaxInputBytes)
                throw new InvalidDataException("Image must be between 1 byte and 20 MB.");

            try
            {
                System.Windows.Media.Imaging.BitmapFrame frame;
                using (var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
                {
                    var decoder = System.Windows.Media.Imaging.BitmapDecoder.Create(
                        input,
                        System.Windows.Media.Imaging.BitmapCreateOptions.PreservePixelFormat,
                        System.Windows.Media.Imaging.BitmapCacheOption.OnLoad);
                    if (decoder.Frames == null || decoder.Frames.Count == 0)
                        throw new InvalidDataException("The selected file contains no decodable image frame.");
                    frame = decoder.Frames[0];
                }

                ValidateDimensions(frame.PixelWidth, frame.PixelHeight);

                var encoder = new System.Windows.Media.Imaging.PngBitmapEncoder();
                encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(frame));
                using (var output = new MemoryStream())
                {
                    encoder.Save(output);
                    if (output.Length <= 0 || output.Length > MaxOutputBytes)
                        throw new InvalidDataException("Normalized PNG exceeds the 20 MB OMNIX safety limit.");
                    byte[] bytes = output.ToArray();
                    ValidatePngBytes(bytes, "normalized image");
                    return bytes;
                }
            }
            catch (InvalidDataException)
            {
                throw;
            }
            catch (NotSupportedException)
            {
                throw new InvalidDataException("Unsupported or invalid image format. Use PNG, JPEG or BMP.");
            }
            catch (Exception ex)
            {
                throw new InvalidDataException("The selected image could not be decoded safely: " + ex.GetType().Name + ".");
            }
        }

        public static void ValidatePngBytes(byte[] bytes, string source)
        {
            if (bytes == null || bytes.Length < 8)
                throw new InvalidDataException((source ?? "Image") + " did not produce valid PNG data.");
            byte[] sig = { 137, 80, 78, 71, 13, 10, 26, 10 };
            for (int i = 0; i < sig.Length; i++)
                if (bytes[i] != sig[i])
                    throw new InvalidDataException((source ?? "Image") + " did not produce valid PNG data.");
            if (bytes.LongLength > MaxOutputBytes)
                throw new InvalidDataException((source ?? "Image") + " exceeds the 20 MB OMNIX safety limit.");
        }

        private static void ValidateDimensions(int width, int height)
        {
            if (width <= 0 || height <= 0)
                throw new InvalidDataException("Image dimensions are invalid.");
            if (width > MaxDimension || height > MaxDimension)
                throw new InvalidDataException("Image dimensions exceed the 10,000-pixel OMNIX safety limit.");
            long pixels = (long)width * (long)height;
            if (pixels > MaxPixels)
                throw new InvalidDataException("Image exceeds the 24-megapixel OMNIX safety limit.");
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
