using System;
using System.Collections.Generic;
using System.Windows.Forms;
using Wd = Microsoft.Office.Interop.Word;
using Microsoft.Office.Tools;
using OMNIX.Core.Context;
using OMNIX.Core.Logging;
using OMNIX.Core.Ui;

namespace OMNIX.Word
{
    /// <summary>
    /// Per-window task pane management for Word (spec Section 5): each document window gets
    /// its own pane/chat. Docked right, 360px default, clamped so the document stays usable.
    /// </summary>
    public sealed class WordTaskPaneService
    {
        private const int DefaultWidth = 360;
        private const int MaxWidth = 640;

        private readonly ThisAddIn _addIn;
        private readonly IHostAdapter _adapter;
        private readonly Dictionary<IntPtr, CustomTaskPane> _panes = new Dictionary<IntPtr, CustomTaskPane>();
        private readonly Dictionary<IntPtr, WorkspaceController> _controllers = new Dictionary<IntPtr, WorkspaceController>();
        private bool _clamping;

        public WordTaskPaneService(ThisAddIn addIn, IHostAdapter adapter)
        {
            _addIn = addIn;
            _adapter = adapter;
        }

        public void AttachEvents()
        {
            _addIn.Application.WindowActivate += OnWindowActivate;
            _addIn.Application.WindowSelectionChange += OnWindowSelectionChange;
            Logger.Startup("WordTaskPaneService events attached");
        }

        public void DetachEvents()
        {
            try
            {
                _addIn.Application.WindowActivate -= OnWindowActivate;
                _addIn.Application.WindowSelectionChange -= OnWindowSelectionChange;
            }
            catch { }
        }

        private IntPtr KeyOf(Wd.Window window)
        {
            try { return (IntPtr)window.Hwnd; }
            catch { return IntPtr.Zero; }
        }

        private void OnWindowActivate(Wd.Document doc, Wd.Window wn)
        {
            try
            {
                IntPtr key = KeyOf(wn);
                WorkspaceController controller;
                if (_controllers.TryGetValue(key, out controller) && controller != null)
                    controller.RefreshContextBar();
            }
            catch (Exception ex)
            {
                Logger.Error("ui", "Word OnWindowActivate failed", ex);
            }
        }

        private void OnWindowSelectionChange(Wd.Selection sel)
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

        private CustomTaskPane EnsurePane(IntPtr key)
        {
            CustomTaskPane pane;
            if (_panes.TryGetValue(key, out pane) && pane != null) return pane;

            object window = _addIn.Application.ActiveWindow;
            if (window == null) return null;

            var controller = new WorkspaceController(_adapter, ThisAddIn.SharedGateway, ThisAddIn.SharedHistory);
            _controllers[key] = controller;

            var hostControl = new TaskPaneHostControl(controller.View);
            pane = _addIn.CustomTaskPanes.Add(hostControl, "OMNIX", window);
            pane.DockPosition = Microsoft.Office.Core.MsoCTPDockPosition.msoCTPDockPositionRight;
            try { pane.Width = DefaultWidth; } catch { }
            pane.VisibleChanged += OnPaneVisibleChanged;
            pane.WidthChanged += OnPaneWidthChanged;
            _panes[key] = pane;
            Logger.Startup("Word task pane created for window " + key);
            return pane;
        }

        private void OnPaneWidthChanged(object sender, EventArgs e)
        {
            if (_clamping) return;
            try
            {
                var pane = sender as CustomTaskPane;
                if (pane != null && pane.Width > MaxWidth)
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
