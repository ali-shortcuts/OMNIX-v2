using System;
using System.Collections.Generic;
using System.Windows.Forms;
using Ppt = Microsoft.Office.Interop.PowerPoint;
using Microsoft.Office.Tools;
using OMNIX.Core.Context;
using OMNIX.Core.Logging;
using OMNIX.Core.Ui;

namespace OMNIX.PowerPoint
{
    /// <summary>
    /// Per-window task pane management for PowerPoint (spec Section 5). Every presentation
    /// window gets its own pane/chat. Docked right, 360px default, width-clamped.
    /// </summary>
    public sealed class PowerPointTaskPaneService
    {
        private const int DefaultWidth = 360;
        private const int MaxWidth = 640;

        private readonly ThisAddIn _addIn;
        private readonly IHostAdapter _adapter;
        private readonly Dictionary<int, CustomTaskPane> _panes = new Dictionary<int, CustomTaskPane>();
        private readonly Dictionary<int, WorkspaceController> _controllers = new Dictionary<int, WorkspaceController>();
        private bool _clamping;

        public PowerPointTaskPaneService(ThisAddIn addIn, IHostAdapter adapter)
        {
            _addIn = addIn;
            _adapter = adapter;
        }

        public void AttachEvents()
        {
            _addIn.Application.WindowActivate += OnWindowActivate;
            _addIn.Application.WindowSelectionChange += OnWindowSelectionChange;
            Logger.Startup("PowerPointTaskPaneService events attached");
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

        private int KeyOf(Ppt.DocumentWindow window)
        {
            try { return window.HWND; }
            catch { return 0; }
        }

        private void OnWindowActivate(Ppt.Presentation pres, Ppt.DocumentWindow wn)
        {
            try
            {
                int key = KeyOf(wn);
                WorkspaceController controller;
                if (_controllers.TryGetValue(key, out controller) && controller != null)
                    controller.RefreshContextBar();
            }
            catch (Exception ex)
            {
                Logger.Error("ui", "PowerPoint OnWindowActivate failed", ex);
            }
        }

        private void OnWindowSelectionChange(Ppt.Selection sel)
        {
            try
            {
                int key = KeyOf(_addIn.Application.ActiveWindow);
                WorkspaceController controller;
                if (key != 0 && _controllers.TryGetValue(key, out controller))
                    controller.RefreshContextBar();
            }
            catch { }
        }

        private CustomTaskPane EnsurePane(int key)
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
            Logger.Startup("PowerPoint task pane created for window " + key);
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
            int key = KeyOf(_addIn.Application.ActiveWindow);
            CustomTaskPane pane = EnsurePane(key);
            if (pane == null) return;
            pane.Visible = !pane.Visible;
        }

        public void ShowSettings()
        {
            int key = KeyOf(_addIn.Application.ActiveWindow);
            CustomTaskPane pane = EnsurePane(key);
            if (pane == null) return;
            pane.Visible = true;
            WorkspaceController controller;
            if (_controllers.TryGetValue(key, out controller))
                controller.View.ShowSettingsTab();
        }
    }
}
