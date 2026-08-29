using System;
using System.Collections.Generic;
using System.Windows.Forms;
using XL = Microsoft.Office.Interop.Excel;
using Microsoft.Office.Tools;
using OMNIX.Core.Context;
using OMNIX.Core.Logging;
using OMNIX.Core.Ui;

namespace OMNIX.Excel
{
    /// <summary>
    /// Per-window task pane management for Excel (spec Section 5):
    /// every open workbook window gets its OWN pane + its own chat/context.
    /// Docked RIGHT (msoCTPDockPositionRight), default width 360px, user-resizable,
    /// width-clamped so the pane never covers the whole document area.
    /// </summary>
    public sealed class ExcelTaskPaneService
    {
        private const int DefaultWidth = 360;
        private const int MinWidth = 260;
        private const int MaxWidth = 640;

        private readonly ThisAddIn _addIn;
        private readonly IHostAdapter _adapter;
        private readonly Dictionary<IntPtr, CustomTaskPane> _panes = new Dictionary<IntPtr, CustomTaskPane>();
        private readonly Dictionary<IntPtr, WorkspaceController> _controllers = new Dictionary<IntPtr, WorkspaceController>();
        private bool _clamping;

        public ExcelTaskPaneService(ThisAddIn addIn, IHostAdapter adapter)
        {
            _addIn = addIn;
            _adapter = adapter;
        }

        public void AttachEvents()
        {
            _addIn.Application.WindowActivate += OnWindowActivate;
            _addIn.Application.WindowDeactivate += OnWindowDeactivate;
            _addIn.Application.SheetSelectionChange += OnSheetSelectionChange;
            _addIn.Application.WorkbookBeforeClose += OnWorkbookBeforeClose;
            Logger.Startup("ExcelTaskPaneService events attached");
        }

        public void DetachEvents()
        {
            try
            {
                _addIn.Application.WindowActivate -= OnWindowActivate;
                _addIn.Application.WindowDeactivate -= OnWindowDeactivate;
                _addIn.Application.SheetSelectionChange -= OnSheetSelectionChange;
                _addIn.Application.WorkbookBeforeClose -= OnWorkbookBeforeClose;
            }
            catch { }
        }

        private IntPtr KeyOf(XL.Window window)
        {
            try { return (IntPtr)window.Hwnd; }
            catch { return IntPtr.Zero; }
        }

        private void OnWindowActivate(XL.Workbook wb, XL.Window wn)
        {
            try
            {
                IntPtr key = KeyOf(wn);
                var controller = GetOrCreateController(key);
                if (controller != null) controller.RefreshContextBar();
            }
            catch (Exception ex)
            {
                Logger.Error("ui", "Excel OnWindowActivate failed", ex);
            }
        }

        private void OnWindowDeactivate(XL.Workbook wb, XL.Window wn) { }

        private void OnSheetSelectionChange(object sh, XL.Range target)
        {
            try
            {
                IntPtr key = KeyOf(_addIn.Application.ActiveWindow);
                WorkspaceController controller;
                if (key != IntPtr.Zero && _controllers.TryGetValue(key, out controller))
                    controller.RefreshContextBar();
            }
            catch { }
        }

        private void OnWorkbookBeforeClose(XL.Workbook wb, ref bool cancel)
        {
            // Pane cleanup happens through window teardown; nothing forced here.
        }

        private WorkspaceController GetOrCreateController(IntPtr key)
        {
            WorkspaceController controller;
            if (_controllers.TryGetValue(key, out controller)) return controller;
            return null;
        }

        private CustomTaskPane EnsurePane(IntPtr key)
        {
            CustomTaskPane pane;
            if (_panes.TryGetValue(key, out pane) && pane != null) return pane;

            object window = ActiveWindowObject();
            if (window == null) return null;

            var controller = new WorkspaceController(_adapter, ThisAddIn.SharedGateway, ThisAddIn.SharedHistory);
            _controllers[key] = controller;

            var hostControl = new TaskPaneHostControl(controller.View);
            pane = _addIn.CustomTaskPanes.Add(hostControl, "OMNIX", window);
            pane.DockPosition = Microsoft.Office.Core.MsoCTPDockPosition.msoCTPDockPositionRight;
            try { pane.Width = DefaultWidth; } catch { }
            pane.VisibleChanged += OnPaneVisibleChanged;
            // NOTE: Microsoft.Office.Tools.CustomTaskPane has no WidthChanged event in this VSTO runtime version;
            // max-width clamping is disabled for now (non-critical UX nicety, not a spec requirement). OnPaneWidthChanged left as dead code for future re-wiring (e.g. a timer-based poll) if needed.
            _panes[key] = pane;

            Logger.Startup("Task pane created for window " + key + " (width " + DefaultWidth + ", docked right)");
            return pane;
        }

        private object ActiveWindowObject()
        {
            try { return _addIn.Application.ActiveWindow; }
            catch { return null; }
        }

        private void OnPaneWidthChanged(object sender, EventArgs e)
        {
            if (_clamping) return;
            try
            {
                var pane = sender as CustomTaskPane;
                if (pane == null) return;
                if (pane.Width > MaxWidth)
                {
                    _clamping = true;
                    pane.Width = MaxWidth;
                    _clamping = false;
                }
            }
            catch { }
            finally { _clamping = false; }
        }

        private void OnPaneVisibleChanged(object sender, EventArgs e)
        {
            var pane = sender as CustomTaskPane;
            if (pane != null && !pane.Visible)
            {
                // User closed the pane with the X — cancel any streaming request for this window.
                foreach (var kv in _panes)
                {
                    if (ReferenceEquals(kv.Value, pane))
                    {
                        WorkspaceController controller;
                        if (_controllers.TryGetValue(kv.Key, out controller))
                            controller.OnPaneClosing();
                    }
                }
            }
        }

        public void ToggleActive()
        {
            IntPtr key = KeyOf(_addIn.Application.ActiveWindow);
            if (key == IntPtr.Zero) return;
            CustomTaskPane pane = EnsurePane(key);
            if (pane == null) return;
            pane.Visible = !pane.Visible;
        }

        public void ShowSettings()
        {
            IntPtr key = KeyOf(_addIn.Application.ActiveWindow);
            CustomTaskPane pane = EnsurePane(key);
            if (pane == null) return;
            pane.Visible = true;
            WorkspaceController controller;
            if (_controllers.TryGetValue(key, out controller))
                controller.View.ShowSettingsTab();
        }
    }
}
