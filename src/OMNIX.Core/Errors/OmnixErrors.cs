using System;
using System.Text;
using OMNIX.Core.Localization;

namespace OMNIX.Core.Errors
{
    /// <summary>
    /// Layer 9 error codes — exactly the list mandated by the OMNIX master spec (Section 3, Layer 9).
    /// Never show a generic "check your internet" message unless the code really is NETWORK_ERROR.
    /// </summary>
    public enum ErrorCode
    {
        None = 0,
        INSTALL_ERROR,
        OFFICE_DETECTION_ERROR,
        REGISTRATION_ERROR,
        UI_ERROR,
        CORE_ERROR,
        NETWORK_ERROR,
        PROVIDER_ERROR,
        AUTH_ERROR,
        MODEL_ERROR,
        TIMEOUT,
        PRIVACY_BLOCKED
    }

    /// <summary>
    /// Categorized error: code + friendly message + technical details + suggested fix.
    ///
    /// SECURITY/PRIVACY INVARIANT: the constructor never writes TechnicalDetails to disk. Some
    /// internal callers legitimately include local paths/host state in those details and provider
    /// transports may inspect untrusted response bodies while classifying an error. Automatic log
    /// output therefore records only the stable category/friendly message. Callers that need a
    /// richer diagnostic log must construct a separate, explicitly sanitized summary.
    /// </summary>
    public class OmnixException : Exception
    {
        public ErrorCode Code { get; private set; }
        public string TechnicalDetails { get; private set; }
        public string SuggestedFix { get; private set; }

        public OmnixException(ErrorCode code, string friendlyMessage, string technicalDetails, string suggestedFix)
            : base(friendlyMessage)
        {
            Code = code;
            TechnicalDetails = technicalDetails ?? string.Empty;
            SuggestedFix = suggestedFix ?? string.Empty;
            Logging.Logger.Gateway("OmnixException category=" + code + "; message=" + SafeLogText(friendlyMessage, 240));
        }

        public static OmnixException Network(string details)
        {
            return new OmnixException(ErrorCode.NETWORK_ERROR, Strings.T("Err.Network"),
                details, Strings.T("Err.NetworkFix"));
        }

        public static OmnixException Timeout(string details)
        {
            return new OmnixException(ErrorCode.TIMEOUT, Strings.T("Err.Timeout"),
                details, Strings.T("Err.TimeoutFix"));
        }

        public static OmnixException Auth(string details)
        {
            return new OmnixException(ErrorCode.AUTH_ERROR, Strings.T("Err.Auth"),
                details, Strings.T("Err.AuthFix"));
        }

        public static OmnixException Model(string details)
        {
            return new OmnixException(ErrorCode.MODEL_ERROR, Strings.T("Err.Model"),
                details, Strings.T("Err.ModelFix"));
        }

        public static OmnixException Provider(string details)
        {
            return new OmnixException(ErrorCode.PROVIDER_ERROR, Strings.T("Err.Provider"),
                details, Strings.T("Err.ProviderFix"));
        }

        public static OmnixException PrivacyBlocked(string details)
        {
            return new OmnixException(ErrorCode.PRIVACY_BLOCKED, Strings.T("Err.ProviderPrivacy"),
                details, Strings.T("Err.ProviderPrivacyFix"));
        }

        private static string SafeLogText(string value, int maxChars)
        {
            if (string.IsNullOrEmpty(value)) return string.Empty;
            var sb = new StringBuilder(Math.Min(value.Length, maxChars));
            for (int i = 0; i < value.Length && sb.Length < maxChars; i++)
            {
                char c = value[i];
                if (c == '\r' || c == '\n' || c == '\t') sb.Append(' ');
                else if (!char.IsControl(c)) sb.Append(c);
            }
            return sb.ToString();
        }
    }

    /// <summary>
    /// Formats a categorized error for the local user. TechnicalDetails are intentionally shown
    /// only in the user's own UI; provider HTTP mapping must already redact response bodies before
    /// they reach this layer. Nothing here writes TechnicalDetails to a log.
    /// </summary>
    public static class ErrorPresenter
    {
        public static string Format(Exception ex)
        {
            var om = ex as OmnixException;
            if (om == null)
            {
                om = new OmnixException(ErrorCode.CORE_ERROR, Strings.T("Err.Generic"),
                    ex.GetType().Name + ": " + ex.Message, Strings.T("Err.GenericFix"));
            }

            var sb = new StringBuilder();
            sb.AppendLine("[" + om.Code + "]");
            sb.AppendLine(om.Message);
            if (!string.IsNullOrEmpty(om.TechnicalDetails))
            {
                sb.AppendLine();
                sb.AppendLine(Strings.T("Err.TechnicalDetails") + " " + om.TechnicalDetails);
            }
            if (!string.IsNullOrEmpty(om.SuggestedFix))
            {
                sb.AppendLine();
                sb.AppendLine(Strings.T("Err.SuggestedFix") + " " + om.SuggestedFix);
            }
            return sb.ToString();
        }

        public static void Show(Exception ex, string context)
        {
            Logging.Logger.Error("error", "Error in " + context, ex);
            try
            {
                System.Windows.MessageBox.Show(Format(ex), "OMNIX — " + context,
                    System.Windows.MessageBoxButton.OK, System.Windows.MessageBoxImage.Warning);
            }
            catch
            {
                // If even the message box fails (no UI thread), the log entry is all we can do.
            }
        }
    }
}
