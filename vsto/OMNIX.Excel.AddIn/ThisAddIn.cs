using System;
using System.Threading;
using Microsoft.Office.Tools;
using OMNIX.Core.Context;
using OMNIX.Core.Ui;
using Office = Microsoft.Office.Core;

namespace OMNIX.Excel.AddIn
{
    public sealed partial class ThisAddIn
    {
        private CustomTaskPane _taskPane;
        private WorkspaceView _workspace;
        private OMNIX.Excel.ExcelHostAdapter _adapter;

        private void ThisAddIn_Startup(object sender, EventArgs e)
        {
            _adapter = new OMNIX.Excel.ExcelHostAdapter(Application);
            _workspace = new WorkspaceView();
            _workspace.PromptSubmitted += OnPromptSubmitted;
            _workspace.SettingsRequested += OnSettingsRequested;

            var host = new TaskPaneHostControl(_workspace);
            _taskPane = CustomTaskPanes.Add(host, "OMNIX");
            _taskPane.DockPosition = Office.MsoCTPDockPosition.msoCTPDockPositionRight;
            _taskPane.Width = 360;
            _taskPane.Visible = false;
        }

        private void ThisAddIn_Shutdown(object sender, EventArgs e)
        {
            if (_workspace != null)
            {
                _workspace.PromptSubmitted -= OnPromptSubmitted;
                _workspace.SettingsRequested -= OnSettingsRequested;
            }

            if (_taskPane != null)
            {
                try { CustomTaskPanes.Remove(_taskPane); } catch { }
                _taskPane = null;
            }

            _workspace = null;
            _adapter = null;
        }

        internal void ToggleWorkspace()
        {
            if (_taskPane == null) return;
            _taskPane.Visible = !_taskPane.Visible;
            if (_taskPane.Visible) RefreshContextSummary();
        }

        internal void ShowSettings()
        {
            if (_taskPane == null) return;
            _taskPane.Visible = true;
            _workspace?.AddMessage("OMNIX", "Settings UI is being rebuilt in the cleanroom branch.");
        }

        private async void OnPromptSubmitted(object sender, string prompt)
        {
            if (_workspace == null || _adapter == null) return;
            _workspace.AddMessage("You", prompt);
            try
            {
                OfficeContext context = await _adapter.CaptureContextAsync(
                    new ContextRequest { MaxCharacters = 6000, MaxItems = 2000 },
                    CancellationToken.None);
                _workspace.SetContextSummary(BuildSummary(context));
                _workspace.AddMessage("OMNIX", "Office context captured. AI provider execution is not enabled in this bootstrap build yet.");
            }
            catch (Exception ex)
            {
                _workspace.AddMessage("OMNIX", "Context capture failed: " + ex.Message);
            }
        }

        private void OnSettingsRequested(object sender, EventArgs e)
        {
            ShowSettings();
        }

        private async void RefreshContextSummary()
        {
            if (_workspace == null || _adapter == null) return;
            try
            {
                OfficeContext context = await _adapter.CaptureContextAsync(new ContextRequest(), CancellationToken.None);
                _workspace.SetContextSummary(BuildSummary(context));
            }
            catch (Exception ex)
            {
                _workspace.SetContextSummary("Excel context unavailable: " + ex.Message);
            }
        }

        private static string BuildSummary(OfficeContext context)
        {
            if (context == null) return "No Excel context";
            string document = string.IsNullOrWhiteSpace(context.DocumentName) ? "No workbook" : context.DocumentName;
            string container = string.IsNullOrWhiteSpace(context.ActiveContainer) ? "No sheet" : context.ActiveContainer;
            string selection = string.IsNullOrWhiteSpace(context.SelectionText) ? "No selection" : context.SelectionText;
            return document + " • " + container + " • " + selection;
        }

        protected override Office.IRibbonExtensibility CreateRibbonExtensibilityObject()
        {
            return new OmnixRibbon(this);
        }

        private void InternalStartup()
        {
            Startup += ThisAddIn_Startup;
            Shutdown += ThisAddIn_Shutdown;
        }
    }
}
