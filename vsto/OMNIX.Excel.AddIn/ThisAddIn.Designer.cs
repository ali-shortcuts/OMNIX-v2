#pragma warning disable 414
namespace OMNIX.Excel.AddIn
{
    [Microsoft.VisualStudio.Tools.Applications.Runtime.StartupObjectAttribute(0)]
    [global::System.Security.Permissions.PermissionSetAttribute(global::System.Security.Permissions.SecurityAction.Demand, Name = "FullTrust")]
    public sealed partial class ThisAddIn : Microsoft.Office.Tools.AddInBase
    {
        internal Microsoft.Office.Tools.CustomTaskPaneCollection CustomTaskPanes;
        internal Microsoft.Office.Tools.SmartTagCollection VstoSmartTags;
        internal Microsoft.Office.Interop.Excel.Application Application;

        public ThisAddIn(
            global::Microsoft.Office.Tools.Excel.ApplicationFactory factory,
            global::System.IServiceProvider serviceProvider)
            : base(factory, serviceProvider, "AddIn", "ThisAddIn")
        {
            Globals.Factory = factory;
        }

        [global::System.Diagnostics.DebuggerNonUserCodeAttribute()]
        [global::System.ComponentModel.EditorBrowsableAttribute(global::System.ComponentModel.EditorBrowsableState.Never)]
        protected override void Initialize()
        {
            base.Initialize();
            Application = GetHostItem<Microsoft.Office.Interop.Excel.Application>(
                typeof(Microsoft.Office.Interop.Excel.Application), "Application");
            Globals.ThisAddIn = this;
            global::System.Windows.Forms.Application.EnableVisualStyles();
            InitializeCachedData();
            InitializeControls();
            InitializeData();
        }

        [global::System.Diagnostics.DebuggerNonUserCodeAttribute()]
        [global::System.ComponentModel.EditorBrowsableAttribute(global::System.ComponentModel.EditorBrowsableState.Never)]
        protected override void FinishInitialization()
        {
            InternalStartup();
            OnStartup();
        }

        [global::System.Diagnostics.DebuggerNonUserCodeAttribute()]
        [global::System.ComponentModel.EditorBrowsableAttribute(global::System.ComponentModel.EditorBrowsableState.Never)]
        protected override void InitializeDataBindings()
        {
            BeginInitialization();
            EndInitialization();
        }

        private void InitializeCachedData()
        {
            if (DataHost != null && DataHost.IsCacheInitialized)
                DataHost.FillCachedData(this);
        }

        private void InitializeData() { }

        private void BeginInitialization()
        {
            BeginInit();
            CustomTaskPanes.BeginInit();
            VstoSmartTags.BeginInit();
        }

        private void EndInitialization()
        {
            VstoSmartTags.EndInit();
            CustomTaskPanes.EndInit();
            EndInit();
        }

        private void InitializeControls()
        {
            CustomTaskPanes = Globals.Factory.CreateCustomTaskPaneCollection(
                null, null, "CustomTaskPanes", "CustomTaskPanes", this);
            VstoSmartTags = Globals.Factory.CreateSmartTagCollection(
                null, null, "VstoSmartTags", "VstoSmartTags", this);
        }

        [global::System.ComponentModel.EditorBrowsableAttribute(global::System.ComponentModel.EditorBrowsableState.Advanced)]
        private bool NeedsFill(string memberName) => DataHost.NeedsFill(this, memberName);

        [global::System.ComponentModel.EditorBrowsableAttribute(global::System.ComponentModel.EditorBrowsableState.Advanced)]
        private void StartCaching(string memberName) => DataHost.StartCaching(this, memberName);

        [global::System.ComponentModel.EditorBrowsableAttribute(global::System.ComponentModel.EditorBrowsableState.Advanced)]
        private void StopCaching(string memberName) => DataHost.StopCaching(this, memberName);

        [global::System.ComponentModel.EditorBrowsableAttribute(global::System.ComponentModel.EditorBrowsableState.Advanced)]
        private bool IsCached(string memberName) => DataHost.IsCached(this, memberName);

        [global::System.Diagnostics.DebuggerNonUserCodeAttribute()]
        [global::System.ComponentModel.EditorBrowsableAttribute(global::System.ComponentModel.EditorBrowsableState.Never)]
        protected override void OnShutdown()
        {
            VstoSmartTags?.Dispose();
            CustomTaskPanes?.Dispose();
            base.OnShutdown();
        }
    }

    internal static class Globals
    {
        private static ThisAddIn _thisAddIn;
        private static Microsoft.Office.Tools.Excel.ApplicationFactory _factory;

        internal static ThisAddIn ThisAddIn
        {
            get => _thisAddIn;
            set
            {
                if (_thisAddIn != null) throw new System.NotSupportedException();
                _thisAddIn = value;
            }
        }

        internal static Microsoft.Office.Tools.Excel.ApplicationFactory Factory
        {
            get => _factory;
            set
            {
                if (_factory != null) throw new System.NotSupportedException();
                _factory = value;
            }
        }
    }
}
