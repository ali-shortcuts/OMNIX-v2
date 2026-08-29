using System;
using System.Windows.Forms;
using System.Windows.Forms.Integration;
using OMNIX.Core.Ui;

namespace OMNIX.Core.Ui
{
    /// <summary>
    /// WinForms control placed inside the Office CustomTaskPane; hosts the WPF WorkspaceView
    /// through an ElementHost (spec Section 3, Layer 2: WinForms⇄WPF bridge).
    /// </summary>
    public sealed class TaskPaneHostControl : UserControl
    {
        private readonly ElementHost _host;
        private readonly WorkspaceView _view;

        public TaskPaneHostControl(WorkspaceView view)
        {
            _view = view;
            _host = new ElementHost
            {
                Dock = DockStyle.Fill,
                Child = view
            };
            Controls.Add(_host);
        }

        public WorkspaceView View { get { return _view; } }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                try
                {
                    if (_view != null) _view.OnPaneClosing();
                }
                catch { }
            }
            base.Dispose(disposing);
        }
    }
}
