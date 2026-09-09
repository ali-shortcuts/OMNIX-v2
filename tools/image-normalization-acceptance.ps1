# OMNIX image-normalization runtime acceptance
#
# Deterministic/offline test of the compiled ImageNormalizer. It creates temporary synthetic images,
# proves JPEG/BMP inputs become real PNG bytes, and proves invalid/oversized inputs fail closed.
# No user image or Office document is read; all temporary files are deleted by the harness.

[CmdletBinding()]
param(
    [string]$CorePath = ".\src\OMNIX.Core\bin\Release\OMNIX.Core.dll",
    [string]$OutputPath = ".\build\artifact\image-normalization-acceptance.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows PowerShell does not necessarily preload WPF assemblies in a headless CI session.
# Load them explicitly before resolving BitmapFrame/Point types used by the compiled harness.
Add-Type -AssemblyName WindowsBase -ErrorAction Stop
Add-Type -AssemblyName PresentationCore -ErrorAction Stop

$core = (Resolve-Path -LiteralPath $CorePath -ErrorAction Stop).Path
[void][Reflection.Assembly]::LoadFrom($core)
$presentationCore = [System.Windows.Media.Imaging.BitmapFrame].Assembly.Location
$windowsBase = [System.Windows.Point].Assembly.Location

$source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using OMNIX.Core.Util;

public sealed class ImageNormalizationAcceptanceResult
{
    public string TestId { get; set; }
    public int EvidenceSchema { get; set; }
    public string GeneratedUtc { get; set; }
    public bool JpegToPngPass { get; set; }
    public bool BmpToPngPass { get; set; }
    public bool InvalidInputRejectedPass { get; set; }
    public bool OversizedInputRejectedPass { get; set; }
    public bool DimensionLimitRejectedPass { get; set; }
    public int FailureCount { get; set; }
    public List<string> Failures { get; set; }
    public bool OverallPass { get; set; }
    public string Privacy { get; set; }
}

public static class ImageNormalizationAcceptanceHarness
{
    private static BitmapSource SyntheticBitmap(int width, int height)
    {
        int stride = width * 4;
        byte[] pixels = new byte[stride * height];
        for (int i = 0; i < pixels.Length; i += 4)
        {
            pixels[i] = 40;
            pixels[i + 1] = 100;
            pixels[i + 2] = 180;
            pixels[i + 3] = 255;
        }
        var bitmap = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgra32, null, pixels, stride);
        bitmap.Freeze();
        return bitmap;
    }

    private static void Save(BitmapEncoder encoder, BitmapSource source, string path)
    {
        encoder.Frames.Add(BitmapFrame.Create(source));
        using (var fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None))
            encoder.Save(fs);
    }

    private static bool IsPng(byte[] bytes)
    {
        byte[] sig = { 137, 80, 78, 71, 13, 10, 26, 10 };
        if (bytes == null || bytes.Length < sig.Length) return false;
        for (int i = 0; i < sig.Length; i++) if (bytes[i] != sig[i]) return false;
        return true;
    }

    private static bool ExpectInvalidData(Action action)
    {
        try { action(); return false; }
        catch (InvalidDataException) { return true; }
    }

    public static ImageNormalizationAcceptanceResult Run()
    {
        var failures = new List<string>();
        var result = new ImageNormalizationAcceptanceResult
        {
            TestId = "IMAGE-NORMALIZATION-RUNTIME-001",
            EvidenceSchema = 1,
            GeneratedUtc = DateTime.UtcNow.ToString("o"),
            Failures = failures,
            Privacy = "Synthetic test images only; no user files, document images or image bytes are emitted in evidence."
        };

        string dir = Path.Combine(Path.GetTempPath(), "OMNIX-image-normalization-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            string jpg = Path.Combine(dir, "synthetic.jpg");
            Save(new JpegBitmapEncoder { QualityLevel = 85 }, SyntheticBitmap(16, 16), jpg);
            byte[] jpegPng = ImageNormalizer.LoadFileAsPng(jpg);
            result.JpegToPngPass = IsPng(jpegPng) && jpegPng.Length <= ImageNormalizer.MaxOutputBytes;
            if (!result.JpegToPngPass) failures.Add("JPEG input was not normalized to bounded PNG bytes.");

            string bmp = Path.Combine(dir, "synthetic.bmp");
            Save(new BmpBitmapEncoder(), SyntheticBitmap(16, 16), bmp);
            byte[] bmpPng = ImageNormalizer.LoadFileAsPng(bmp);
            result.BmpToPngPass = IsPng(bmpPng) && bmpPng.Length <= ImageNormalizer.MaxOutputBytes;
            if (!result.BmpToPngPass) failures.Add("BMP input was not normalized to bounded PNG bytes.");

            string invalid = Path.Combine(dir, "not-an-image.jpg");
            File.WriteAllText(invalid, "this is not an image");
            result.InvalidInputRejectedPass = ExpectInvalidData(() => ImageNormalizer.LoadFileAsPng(invalid));
            if (!result.InvalidInputRejectedPass) failures.Add("Invalid image content was accepted.");

            string oversized = Path.Combine(dir, "oversized.png");
            using (var fs = new FileStream(oversized, FileMode.Create, FileAccess.Write, FileShare.None))
                fs.SetLength(ImageNormalizer.MaxInputBytes + 1);
            result.OversizedInputRejectedPass = ExpectInvalidData(() => ImageNormalizer.LoadFileAsPng(oversized));
            if (!result.OversizedInputRejectedPass) failures.Add("Input larger than 20 MB was accepted.");

            string tooWide = Path.Combine(dir, "too-wide.png");
            Save(new PngBitmapEncoder(), SyntheticBitmap(ImageNormalizer.MaxDimension + 1, 1), tooWide);
            result.DimensionLimitRejectedPass = ExpectInvalidData(() => ImageNormalizer.LoadFileAsPng(tooWide));
            if (!result.DimensionLimitRejectedPass) failures.Add("Image dimension hard limit was not enforced.");
        }
        finally
        {
            try { Directory.Delete(dir, true); } catch { }
        }

        result.FailureCount = failures.Count;
        result.OverallPass = failures.Count == 0;
        return result;
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp -ReferencedAssemblies @($core,$presentationCore,$windowsBase) -ErrorAction Stop
$result = [ImageNormalizationAcceptanceHarness]::Run()

$outDir = Split-Path -Parent $OutputPath
if ($outDir) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$result | ConvertTo-Json -Depth 8

if (-not $result.OverallPass) { exit 1 }
exit 0
