using System;
using Excel = Microsoft.Office.Interop.Excel;
using Office = Microsoft.Office.Core;
using OMNIX.Core.AiGateway;
using OMNIX.Core.Context;
using OMNIX.Core.Logging;
using OMNIX.Core.Settings;
using OMNIX.Core.Storage;

namespace OMNIX.Excel
{
    /// <summary>
    /// Thin Excel host (spec Section 3, Layer 1): only wires the Application object into the
    /// shared OMNIX.Core services and registers the ribbon + per-window task panes.
    /// The static ctor writes the very first Startup log line (spec 4.3) BEFORE any other code.
    /// </summary>
    public partial class ThisAddIn
    {
        static ThisAddIn()
        {
            Logger.Startup("=== OMNIX.Excel ThisAddIn: static ctor reached (pid " + System.Diagnostics.Process.GetCurrentProcess().Id + ") ===");
        }

        internal ExcelHostAdapter Adapter { get; private set; }
        internal ExcelTaskPaneService Panes { get; private set; }

        internal static AiGateway SharedGateway;
        internal static ChatHistoryStore SharedHistory;

        private void ThisAddIn_Startup(object sender, System.EventArgs e)
        {
            Logger.Startup("ThisAddIn_Startup begin — Excel version: " + SafeVersion());

            // Global exception capture (spec Phase 1.4)
            AppDomain.CurrentDomain.UnhandledException += OnUnhandledException;
            System.Threading.Tasks.TaskScheduler.UnobservedTaskException += OnUnobservedTaskException;

            // ThisAddIn.Application was resolved by the generated Initialize() (GetHostItem).
            if (Application == null)
            {
                Logger.Startup("FATAL: Excel Application object is null — add-in stays passive. See startup-debug.log.");
                return;
            }

            Adapter = new ExcelHostAdapter(Application,
                () => SettingsManager.Instance.Settings.ContextMaxCells,
                () => SettingsManager.Instance.Settings.ContextMaxChars);

            EnsureSharedServices();

            Panes = new ExcelTaskPaneService(this, Adapter);
            Panes.AttachEvents();
            Logger.Startup("ThisAddIn_Startup complete — ribbon + task pane service ready");
        }

        internal static void EnsureSharedServices()
        {
            if (SharedGateway == null)
            {
                SharedHistory = new ChatHistoryStore();
                var registry = new ProviderRegistry();
                SharedGateway = new AiGateway(registry);
                SharedGateway.ProbeLocalAsync(); // background local-AI probe (spec Phase 9.1)
            }
        }

        private static void OnUnhandledException(object sender, UnhandledExceptionEventArgs e)
        {
            Logger.Error("startup-debug", "AppDomain.UnhandledException", e.ExceptionObject as Exception);
        }

        private static void OnUnobservedTaskException(object sender, System.Threading.Tasks.UnobservedTaskExceptionEventArgs e)
        {
            Logger.Error("startup-debug", "TaskScheduler.UnobservedTaskException", e.Exception);
            e.SetObserved();
        }

        private string SafeVersion()
        {
            try { return Application.Version; } catch { return "?"; }
        }

        private void ThisAddIn_Shutdown(object sender, System.EventArgs e)
        {
            Logger.Startup("ThisAddIn_Shutdown");
            if (Panes != null) Panes.DetachEvents();
        }

        protected override Office.IRibbonExtensibility CreateRibbonExtensibilityObject()
        {
            Logger.Startup("CreateRibbonExtensibilityObject -> OmnixRibbon");
            return new OmnixRibbon(this);
        }

        #region VSTO generated code

        /// <summary>
        /// Required method for Designer support - do not modify
        /// the contents of this method with the code editor.
        /// </summary>
        private void InternalStartup()
        {
            this.Startup += new System.EventHandler(ThisAddIn_Startup);
            this.Shutdown += new System.EventHandler(ThisAddIn_Shutdown);
        }

        #endregion
    }
}
