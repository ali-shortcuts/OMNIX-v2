using System;
using System.Windows.Forms;
using System.Windows.Forms.Integration;

namespace OMNIX.Core.Ui
{
    /// <summary>
    /// Native Office CustomTaskPane host. VSTO exposes a WinForms control surface;
    /// ElementHost keeps the primary OMNIX UI in WPF without a browser or web runtime.
    /// </summary>
    public sealed class TaskPaneHostControl : UserControl
    {
        private readonly ElementHost _elementHost;

        public TaskPaneHostControl(WorkspaceView workspace)
        {
            if (workspace == null) throw new ArgumentNullException(nameof(workspace));

            Dock = DockStyle.Fill;
            AutoScaleMode = AutoScaleMode.Dpi;

            _elementHost = new ElementHost
            {
                Dock = DockStyle.Fill,
                Child = workspace
            };
            Controls.Add(_elementHost);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                _elementHost.Child = null;
                _elementHost.Dispose();
            }
            base.Dispose(disposing);
        }
    }
}
