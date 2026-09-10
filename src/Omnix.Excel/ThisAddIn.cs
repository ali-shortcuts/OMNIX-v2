using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using System.Windows.Forms.Integration;
using Microsoft.Office.Tools;
using Omnix.Contracts;
using Omnix.Desktop;
using Office=Microsoft.Office.Core;

namespace Omnix.Excel
{
    // Explicit VSTO lifecycle implementation. This is maintained source, not a claimed generated template.
    [Microsoft.VisualStudio.Tools.Applications.Runtime.StartupObject(0)]
    [System.Security.Permissions.PermissionSet(System.Security.Permissions.SecurityAction.Demand, Name="FullTrust")]
    public sealed class ThisAddIn : AddInBase
    {
        private readonly Microsoft.Office.Tools.Excel.ApplicationFactory factory;
        private Microsoft.Office.Interop.Excel.Application application;
        private CustomTaskPaneCollection panes;
        private readonly Dictionary<long,CustomTaskPane> windows=new Dictionary<long,CustomTaskPane>();
        private readonly List<Workspace> views=new List<Workspace>();
        private Automation automation;
        public ThisAddIn(Microsoft.Office.Tools.Excel.ApplicationFactory factory,IServiceProvider services):base(factory,services,"AddIn","ThisAddIn")
        {
            this.factory=factory;
            LocalData.Log("Excel_CONSTRUCTED");
        }
        protected override void Initialize()
        {
            base.Initialize();
            application=GetHostItem<Microsoft.Office.Interop.Excel.Application>(typeof(Microsoft.Office.Interop.Excel.Application),"Application");
            panes=factory.CreateCustomTaskPaneCollection(null,null,"CustomTaskPanes","CustomTaskPanes",this);
            LocalData.Log("Excel_INITIALIZED");
        }
        protected override void InitializeDataBindings()
        {
            BeginInit();panes.BeginInit();panes.EndInit();EndInit();
        }
        protected override void FinishInitialization() { OnStartup();LocalData.Log("Excel_STARTED"); }
        protected override Office.IRibbonExtensibility CreateRibbonExtensibilityObject() => new Ribbon(this);
        protected override object RequestComAddInAutomationService() => automation ?? (automation=new Automation(this));
        internal string RuntimeState => "OMNIX/4.0;host=Excel;started="+(application!=null)+";panes="+windows.Count;
        internal void ShowWorkspace()
        {
            try {
                dynamic current=application.ActiveWindow;
                if(current==null)throw new InvalidOperationException("Open a document before opening OMNIX.");
                long handle=Convert.ToInt64(current.HWND);
                CustomTaskPane pane;
                if(!windows.TryGetValue(handle,out pane)) {
                    string root=Path.GetFullPath(Path.Combine(Path.GetDirectoryName(typeof(ThisAddIn).Assembly.Location),"..",".."));
                    var view=new Workspace(application,"Excel",Path.Combine(root,"gateway","Omnix.Gateway.exe"));
                    var control=new UserControl {Dock=DockStyle.Fill};
                    control.Controls.Add(new ElementHost {Dock=DockStyle.Fill,Child=view});
                    pane=panes.Add(control,"OMNIX",(object)current);pane.Width=430;pane.DockPosition=Office.MsoCTPDockPosition.msoCTPDockPositionRight;
                    windows.Add(handle,pane);views.Add(view);
                }
                pane.Visible=!pane.Visible;
                LocalData.Log("Excel_PANE_SHOWN");
            } catch(Exception e) {
                LocalData.Log("Excel_PANE_FAILED",e);
                MessageBox.Show("OMNIX could not open its workspace.\n\n"+e.Message+"\n\nRun OMNIX Diagnostics from the Start menu.","OMNIX",MessageBoxButtons.OK,MessageBoxIcon.Error);
            }
        }
        protected override void OnShutdown()
        {
            foreach(var view in views)view.Dispose();views.Clear();windows.Clear();panes?.Dispose();base.OnShutdown();LocalData.Log("Excel_STOPPED");
        }
    }
    [ComVisible(true)]
    [ClassInterface(ClassInterfaceType.AutoDispatch)]
    public sealed class Automation
    {
        private readonly ThisAddIn addin;
        internal Automation(ThisAddIn value){addin=value;}
        public string Health => addin.RuntimeState;
        public void OpenWorkspace() => addin.ShowWorkspace();
    }
    [ComVisible(true)]
    [ClassInterface(ClassInterfaceType.AutoDispatch)]
    public sealed class Ribbon : Office.IRibbonExtensibility
    {
        private readonly ThisAddIn addin;
        internal Ribbon(ThisAddIn addin){this.addin=addin;}
        public string GetCustomUI(string ribbonId) => "<customUI xmlns='http://schemas.microsoft.com/office/2009/07/customui'><ribbon><tabs><tab id='OmnixTab' label='OMNIX'><group id='OmnixWorkspaceGroup' label='AI workspace'><button id='OmnixOpen' label='Open Workspace' size='large' imageMso='ViewTaskPane' onAction='OpenWorkspace' screentip='Open OMNIX beside your document'/></group></tab></tabs></ribbon></customUI>";
        public void OpenWorkspace(Office.IRibbonControl control) => addin.ShowWorkspace();
    }
}
