using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using System.Windows.Forms.Integration;
using Microsoft.Office.Tools;
using Omnix.Contracts;
using Omnix.Desktop;
using Office=Microsoft.Office.Core;

namespace Omnix.Word
{
    // Explicit VSTO lifecycle implementation. This is maintained source, not a claimed generated template.
    [Microsoft.VisualStudio.Tools.Applications.Runtime.StartupObject(0)]
    [System.Security.Permissions.PermissionSet(System.Security.Permissions.SecurityAction.Demand, Name="FullTrust")]
    public sealed class ThisAddIn : AddInBase
    {
        private readonly Microsoft.Office.Tools.Word.ApplicationFactory factory;
        private Microsoft.Office.Interop.Word.Application application;
        private CustomTaskPaneCollection panes;
        private WindowWorkspaces<PaneEntry> windows;
        private Timer windowTimer;
        private bool synchronizing, stopping;
        private DateTime nextAttempt;
        private sealed class PaneEntry
        {
            public CustomTaskPane Pane;
            public Workspace View;
            public UserControl Control;
        }
        private Automation automation;
        public ThisAddIn(Microsoft.Office.Tools.Word.ApplicationFactory factory,IServiceProvider services):base(factory,services,"AddIn","ThisAddIn")
        {
            this.factory=factory;
            LocalData.Log("Word_CONSTRUCTED");
        }
        protected override void Initialize()
        {
            base.Initialize();
            application=GetHostItem<Microsoft.Office.Interop.Word.Application>(typeof(Microsoft.Office.Interop.Word.Application),"Application");
            panes=factory.CreateCustomTaskPaneCollection(null,null,"CustomTaskPanes","CustomTaskPanes",this);
            LocalData.Log("Word_INITIALIZED");
        }
        protected override void InitializeDataBindings()
        {
            BeginInit();panes.BeginInit();panes.EndInit();EndInit();
        }
        protected override void FinishInitialization()
        {
            windows=new WindowWorkspaces<PaneEntry>(ReleasePane);
            OnStartup();
            // Defer COM/UI creation until Office has returned from add-in startup.
            windowTimer=new Timer {Interval=1500};
            windowTimer.Tick+=SynchronizeWindows;
            windowTimer.Start();
            LocalData.Log("Word_STARTED");
        }
        protected override Office.IRibbonExtensibility CreateRibbonExtensibilityObject() => new Ribbon(this);
        protected override object RequestComAddInAutomationService() => automation ?? (automation=new Automation(this));
        internal string RuntimeState => "OMNIX/4.0;host=Word;started="+(application!=null)+";panes="+(windows?.Count??0);
        private static string WindowIdentity(dynamic window)
        {
            object document=window.Document;
            IntPtr identity=Marshal.GetIUnknownForObject(document);
            try {return Convert.ToInt64(window.HWND)+":"+identity.ToInt64();}
            finally {Marshal.Release(identity);}
        }
        private PaneEntry CreatePane(object current)
        {
            string root=Path.GetFullPath(Path.Combine(Path.GetDirectoryName(typeof(ThisAddIn).Assembly.Location),"..",".."));
            var entry=new PaneEntry();
            try {
                entry.View=new Workspace(application,"Word",Path.Combine(root,"gateway","Omnix.Gateway.exe"));
                entry.Control=new UserControl {Dock=DockStyle.Fill};
                entry.Control.Controls.Add(new ElementHost {Dock=DockStyle.Fill,Child=entry.View});
                entry.Pane=panes.Add(entry.Control,"OMNIX",current);
                entry.Pane.Width=430;entry.Pane.DockPosition=Office.MsoCTPDockPosition.msoCTPDockPositionRight;
                entry.Pane.Visible=true;
                LocalData.Log("Word_PANE_CREATED");return entry;
            } catch {ReleasePane(entry);throw;}
        }
        private void ReleasePane(PaneEntry entry)
        {
            try {entry.View?.Dispose();}catch(Exception e){LocalData.Log("Word_VIEW_DISPOSE_FAILED",e);}
            // VSTO owns collection cleanup during shutdown; Remove is only valid while running.
            if(!stopping && entry.Pane!=null)try {panes.Remove(entry.Pane);}catch(Exception e){LocalData.Log("Word_PANE_REMOVE_FAILED",e);}
            try {entry.Control?.Dispose();}catch(Exception e){LocalData.Log("Word_CONTROL_DISPOSE_FAILED",e);}
        }
        private void SynchronizeWindows(object sender,EventArgs args)
        {
            if(stopping || synchronizing || DateTime.UtcNow<nextAttempt)return;
            synchronizing=true;
            try {
                dynamic collection=application.Windows;
                var live=new Dictionary<string,object>();
                for(int i=1;i<=collection.Count;i++) {
                    dynamic window=collection[i];
                    live[WindowIdentity((object)window)]=(object)window;
                }
                windows.Prune(live.Keys);
                foreach(var item in live)windows.GetOrCreate(item.Key,()=>CreatePane(item.Value));
                // Existing panes are left alone: closing the pane is respected.
            }catch(Exception e) {
                nextAttempt=DateTime.UtcNow.AddSeconds(15);
                LocalData.Log("Word_WINDOW_SYNC_DEFERRED",e);
            }finally{synchronizing=false;}
        }
        internal void ShowWorkspace()
        {
            if(stopping || synchronizing)return;
            synchronizing=true;
            try {
                dynamic current=application.ActiveWindow;
                if(current==null)throw new InvalidOperationException("Open a document before opening OMNIX.");
                var entry=windows.GetOrCreate(WindowIdentity((object)current),()=>CreatePane((object)current));
                // Open is idempotent; repeated ribbon/automation calls cannot hide the pane.
                entry.Pane.Visible=true;
            } catch(Exception e) {
                LocalData.Log("Word_PANE_FAILED",e);
                MessageBox.Show("OMNIX could not open its workspace.\n\n"+e.Message+"\n\nRun OMNIX Diagnostics from the Start menu.","OMNIX",MessageBoxButtons.OK,MessageBoxIcon.Error);
            }finally{synchronizing=false;}
        }
        protected override void OnShutdown()
        {
            stopping=true;
            if(windowTimer!=null){windowTimer.Stop();windowTimer.Tick-=SynchronizeWindows;windowTimer.Dispose();}
            windows?.Clear();base.OnShutdown();LocalData.Log("Word_STOPPED");
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
